"""
SQLite wrapper for the disk index.

Kept intentionally thin: connection pooling, schema migration, and a handful
of typed helpers used by build.py and retrieve.py. Everything else stays at
the call site so the query shapes are visible.
"""

from __future__ import annotations

import sqlite3
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator

_SCHEMA_PATH = Path(__file__).with_name("schema.sql")

# Bump whenever the schema changes in a way older builds can't handle.
# v2 adds `chunks.vector` (nullable BLOB) + the idx_chunks_novec partial index.
SCHEMA_VERSION = "2"


@dataclass(frozen=True)
class FileRow:
    id: int
    path: str
    name: str
    ext: str | None
    size: int | None
    mtime: float | None


@dataclass(frozen=True)
class IndexStats:
    files: int
    chunks: int
    built_at: float | None
    schema_version: str | None

    @property
    def age(self) -> str:
        if not self.built_at:
            return "unknown"
        delta = max(0, int(time.time() - self.built_at))
        if delta < 90:
            return f"{delta}s ago"
        if delta < 5400:
            return f"{delta // 60}m ago"
        if delta < 172800:
            return f"{delta // 3600}h ago"
        return f"{delta // 86400}d ago"


def connect(db_path: Path, *, create: bool = False) -> sqlite3.Connection:
    """Open the index DB, optionally initialising the schema."""
    if create:
        db_path.parent.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(str(db_path), isolation_level=None, check_same_thread=False)
    conn.row_factory = sqlite3.Row
    if create:
        _init_schema(conn)
    return conn


def _init_schema(conn: sqlite3.Connection) -> None:
    sql = _SCHEMA_PATH.read_text(encoding="utf-8")
    conn.executescript(sql)
    _run_migrations(conn)
    conn.execute(
        "INSERT OR REPLACE INTO manifest(key, value) VALUES ('schema_version', ?)",
        (SCHEMA_VERSION,),
    )


def _run_migrations(conn: sqlite3.Connection) -> None:
    """Bring an older on-disk schema up to the current version in-place.

    We prefer idempotent ALTER TABLE migrations over wipe-on-mismatch so users
    who've already paid the full first-build cost don't get knocked back to
    zero when we add a column.
    """
    cols = conn.execute("PRAGMA table_info(chunks)").fetchall()
    col_names = {row["name"] for row in cols}
    if "vector" not in col_names:
        conn.execute("ALTER TABLE chunks ADD COLUMN vector BLOB")
    # Partial index on chunks missing a vector — safe to recreate.
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_chunks_novec "
        "ON chunks(id) WHERE vector IS NULL"
    )

    # One-shot: previously we never inserted a filename-only chunk for non-
    # code files whose body extraction failed (scanned PDFs, exotic formats).
    # Those rows exist in `files` with zero chunks and are invisible to every
    # FTS path. Reset their mtime so the next incremental build re-extracts
    # them; build.py now inserts a filename-only chunk as a fallback.
    already_ran = conn.execute(
        "SELECT value FROM manifest WHERE key = ?",
        ("empty_file_mtime_reset_v1",),
    ).fetchone()
    if already_ran is None:
        reset_mtime_for_empty_files(conn)
        conn.execute(
            "INSERT OR REPLACE INTO manifest(key, value) VALUES (?, ?)",
            ("empty_file_mtime_reset_v1", "1"),
        )


def reset_mtime_for_empty_files(conn: sqlite3.Connection) -> int:
    """Reset the stored mtime of any real file row that has no chunks, so a
    subsequent incremental build treats it as "modified" and re-extracts.

    Returns the number of rows touched. Skips synthetic `ali://…` rows — we
    don't manage their mtime this way.
    """
    cur = conn.execute(
        """
        UPDATE files
        SET mtime = 0
        WHERE path NOT LIKE 'ali://%'
          AND id NOT IN (SELECT DISTINCT file_id FROM chunks)
        """
    )
    return int(cur.rowcount or 0)


def set_manifest(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT OR REPLACE INTO manifest(key, value) VALUES (?, ?)",
        (key, value),
    )


def get_manifest(conn: sqlite3.Connection, key: str) -> str | None:
    row = conn.execute("SELECT value FROM manifest WHERE key = ?", (key,)).fetchone()
    return row["value"] if row else None


def upsert_file(
    conn: sqlite3.Connection,
    *,
    path: str,
    name: str,
    ext: str | None,
    size: int | None,
    mtime: float | None,
    mime: str | None,
    content_ok: bool,
) -> int:
    """Insert or update a file row and return its id."""
    cur = conn.execute(
        """
        INSERT INTO files(path, name, ext, size, mtime, mime, indexed_at, content_ok)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
            name = excluded.name,
            ext = excluded.ext,
            size = excluded.size,
            mtime = excluded.mtime,
            mime = excluded.mime,
            indexed_at = excluded.indexed_at,
            content_ok = excluded.content_ok
        RETURNING id
        """,
        (path, name, ext, size, mtime, mime, time.time(), 1 if content_ok else 0),
    )
    row = cur.fetchone()
    return int(row["id"])


def clear_chunks(conn: sqlite3.Connection, file_id: int) -> None:
    conn.execute("DELETE FROM chunks WHERE file_id = ?", (file_id,))


def lookup_file(
    conn: sqlite3.Connection, path: str
) -> tuple[int, float | None] | None:
    """Return (file_id, stored_mtime) for `path`, or None if unknown."""
    row = conn.execute(
        "SELECT id, mtime FROM files WHERE path = ?", (path,)
    ).fetchone()
    if row is None:
        return None
    return int(row["id"]), row["mtime"]


def iter_all_paths(conn: sqlite3.Connection) -> list[tuple[int, str]]:
    rows = conn.execute("SELECT id, path FROM files").fetchall()
    return [(int(r["id"]), str(r["path"])) for r in rows]


def delete_file(conn: sqlite3.Connection, file_id: int) -> None:
    """Drop a file row; ON DELETE CASCADE removes its chunks + FTS entries."""
    conn.execute("DELETE FROM files WHERE id = ?", (file_id,))


def count_files(conn: sqlite3.Connection) -> int:
    return int(conn.execute("SELECT COUNT(*) AS c FROM files").fetchone()["c"])


def count_chunks_needing_embedding(conn: sqlite3.Connection) -> int:
    row = conn.execute(
        "SELECT COUNT(*) AS c FROM chunks WHERE vector IS NULL"
    ).fetchone()
    return int(row["c"])


def iter_unembedded_chunks(
    conn: sqlite3.Connection,
    *,
    batch_size: int = 256,
):
    """Yield (chunk_id, text) pairs for chunks that still need a vector."""
    last_id = 0
    while True:
        rows = conn.execute(
            """
            SELECT id, text FROM chunks
            WHERE vector IS NULL AND id > ?
            ORDER BY id
            LIMIT ?
            """,
            (last_id, batch_size),
        ).fetchall()
        if not rows:
            return
        for row in rows:
            last_id = int(row["id"])
            yield last_id, str(row["text"])


def update_chunk_vectors(
    conn: sqlite3.Connection,
    items: list[tuple[int, bytes]],
) -> None:
    """Bulk UPDATE of chunk vectors. `items` is [(chunk_id, float32_blob), …]."""
    if not items:
        return
    conn.executemany(
        "UPDATE chunks SET vector = ? WHERE id = ?",
        [(blob, cid) for cid, blob in items],
    )


def iter_embedded_chunks(conn: sqlite3.Connection):
    """Yield (chunk_id, vector_blob) for every chunk that has an embedding."""
    cur = conn.execute(
        "SELECT id, vector FROM chunks WHERE vector IS NOT NULL ORDER BY id"
    )
    for row in cur:
        yield int(row["id"]), bytes(row["vector"])


def count_embedded_chunks(conn: sqlite3.Connection) -> int:
    row = conn.execute(
        "SELECT COUNT(*) AS c FROM chunks WHERE vector IS NOT NULL"
    ).fetchone()
    return int(row["c"])


def insert_chunks(
    conn: sqlite3.Connection,
    file_id: int,
    chunks: Iterable[str],
) -> list[int]:
    """Insert chunks for a file and return the assigned rowids."""
    ids: list[int] = []
    for idx, text in enumerate(chunks):
        cur = conn.execute(
            "INSERT INTO chunks(file_id, chunk_idx, text) VALUES (?, ?, ?)",
            (file_id, idx, text),
        )
        ids.append(int(cur.lastrowid))
    return ids


def stats(conn: sqlite3.Connection) -> IndexStats:
    files = int(conn.execute("SELECT COUNT(*) AS c FROM files").fetchone()["c"])
    chunks = int(conn.execute("SELECT COUNT(*) AS c FROM chunks").fetchone()["c"])
    built_at_raw = get_manifest(conn, "built_at")
    try:
        built_at = float(built_at_raw) if built_at_raw else None
    except (TypeError, ValueError):
        built_at = None
    return IndexStats(
        files=files,
        chunks=chunks,
        built_at=built_at,
        schema_version=get_manifest(conn, "schema_version"),
    )


def iter_chunks_for_vector_build(
    conn: sqlite3.Connection,
) -> Iterator[tuple[int, str]]:
    """Yield (chunk_id, text) pairs in stable order for embedding."""
    cur = conn.execute("SELECT id, text FROM chunks ORDER BY id")
    for row in cur:
        yield int(row["id"]), str(row["text"])


def lookup_chunks_by_id(
    conn: sqlite3.Connection,
    ids: list[int],
) -> dict[int, tuple[str, str, float | None]]:
    """Return {chunk_id: (path, snippet, mtime)} for the given chunk ids."""
    if not ids:
        return {}
    qmarks = ",".join("?" for _ in ids)
    cur = conn.execute(
        f"""
        SELECT chunks.id AS cid, chunks.text AS text,
               files.path AS path, files.mtime AS mtime
        FROM chunks
        JOIN files ON files.id = chunks.file_id
        WHERE chunks.id IN ({qmarks})
        """,
        ids,
    )
    out: dict[int, tuple[str, str, float | None]] = {}
    for row in cur:
        out[int(row["cid"])] = (str(row["path"]), str(row["text"]), row["mtime"])
    return out
