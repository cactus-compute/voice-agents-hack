"""
Hybrid retrieval over the disk index.

Combines:
  * SQLite FTS5 BM25 on chunk text + filename (filename column weighted 5x)
  * hnswlib cosine search on chunk embeddings

Results are fused with reciprocal rank fusion (RRF), deduplicated by
`file_id` (so one big file with many mediocre chunks cannot crowd out a
better file with a single strong chunk), and lightly boosted when the
file's basename contains a query term. The caller gets back ranked `Hit`
objects with enough metadata to cite a source file and to embed a short
snippet in a RAG prompt.
"""

from __future__ import annotations

import re
import sqlite3
import threading
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable

from . import embed, store, vectors


@dataclass(frozen=True)
class Hit:
    path: str
    name: str
    snippet: str
    score: float
    mtime: float | None
    source: str  # "fts" | "vector" | "hybrid"


@dataclass(frozen=True)
class FileHit:
    path: str
    name: str
    score: float
    mtime: float | None


_RRF_K = 60
# Bonus added to the RRF score when a file's basename (without extension)
# contains one of the query terms. Picked empirically: large enough to
# always beat a pure-body tangential match with similar RRF score, small
# enough that it doesn't override genuinely stronger semantic hits.
_FILENAME_MATCH_BOOST = 0.05
# FTS5 schema is `fts5(name, text, …)` — weighting the `name` column 5x
# makes filename hits ~5x more important than body hits in BM25 ranking.
_BM25_NAME_WEIGHT = 5.0
_BM25_TEXT_WEIGHT = 1.0


class IndexHandle:
    """Bundled read-only handles for query-time access.

    Kept thread-safe by serialising access to both the SQLite connection and
    the hnswlib index behind a single lock — the queries are fast enough that
    a mutex is cheaper than re-opening connections per request.
    """

    def __init__(
        self,
        *,
        db: sqlite3.Connection,
        vec_index,
        vec_meta,
        index_dir: Path,
    ) -> None:
        self._db = db
        self._vec_index = vec_index
        self._vec_meta = vec_meta
        self._index_dir = index_dir
        self._lock = threading.Lock()

    @property
    def vectors_available(self) -> bool:
        return self._vec_index is not None

    @property
    def embed_model(self) -> str | None:
        if self._vec_meta is None:
            return None
        return self._vec_meta.model or None

    def search_files(self, query: str, *, limit: int = 20) -> list[FileHit]:
        terms = _extract_terms(query)
        if not terms:
            return []
        # bm25() must be called in a query that scans content_fts directly.
        # Rank chunks first, then join to files and pick the best rank per file.
        # Column-weighted BM25 (name=5.0, text=1.0) lets exact filename
        # matches win over incidental body matches of the same word.
        rows = self._run_fts_files_query(terms, limit=limit)
        out: list[FileHit] = []
        for row in rows:
            out.append(
                FileHit(
                    path=str(row["path"]),
                    name=str(row["name"]),
                    score=float(row["rank"] or 0.0),
                    mtime=row["mtime"],
                )
            )
        return out

    def _run_fts_files_query(
        self, terms: list[str], *, limit: int
    ) -> list[sqlite3.Row]:
        """Run the file-level FTS query with an AND-first, OR-fallback strategy."""
        def _exec(expr: str) -> list[sqlite3.Row]:
            with self._lock:
                return self._db.execute(
                    f"""
                    WITH matched AS (
                        SELECT rowid AS chunk_id,
                               bm25(content_fts, {_BM25_NAME_WEIGHT}, {_BM25_TEXT_WEIGHT}) AS rank
                        FROM content_fts
                        WHERE content_fts MATCH ?
                        ORDER BY rank
                        LIMIT ?
                    )
                    SELECT files.path AS path, files.name AS name, files.mtime AS mtime,
                           MIN(matched.rank) AS rank
                    FROM matched
                    JOIN chunks ON chunks.id = matched.chunk_id
                    JOIN files  ON files.id  = chunks.file_id
                    GROUP BY files.id
                    ORDER BY rank
                    LIMIT ?
                    """,
                    (expr, limit * 4, limit),
                ).fetchall()

        # Precision-first: require all terms, fall back to any-term if empty.
        if len(terms) >= 2:
            and_expr = _fts_match_expression(terms, prefix=True, operator="AND")
            rows = _exec(and_expr)
            if rows:
                return rows
        or_expr = _fts_match_expression(terms, prefix=True, operator="OR")
        return _exec(or_expr)

    def search_content(
        self,
        query: str,
        *,
        k: int = 6,
    ) -> list[Hit]:
        """Hybrid top-k retrieval with RRF, deduplicated by file.

        For each retrieval channel (FTS, vector) we collapse chunk-level
        hits to one best chunk per file_id before running RRF. This
        guarantees the top-k is filled with distinct files instead of
        many chunks from the same mid-ranking file.
        """
        raw_fts = self._fts_hits(query, k=k * 8)
        raw_vec = self._vector_hits(query, k=k * 8)

        chunk_to_file = _chunk_to_file_map(self._db, raw_fts, raw_vec)

        fts_file_hits, fts_chunk_for_file = _collapse_to_files(
            raw_fts, chunk_to_file
        )
        vec_file_hits, vec_chunk_for_file = _collapse_to_files(
            raw_vec, chunk_to_file
        )

        fused_files = _reciprocal_rank_fusion_files(
            fts_file_hits, vec_file_hits, limit=k * 2
        )

        terms = set(_extract_terms(query))
        boosted: list[tuple[int, float, str]] = []
        file_sources = _file_source_map(fts_file_hits, vec_file_hits)
        for file_id, score in fused_files:
            src = file_sources.get(file_id, "hybrid")
            chosen_chunk = fts_chunk_for_file.get(file_id) or vec_chunk_for_file.get(file_id)
            boost_score = score + _filename_boost(file_id, terms, chunk_to_file)
            if chosen_chunk is not None:
                boosted.append((chosen_chunk, boost_score, src))

        boosted.sort(key=lambda row: row[1], reverse=True)
        top = boosted[:k]
        ids = [chunk_id for chunk_id, _, _ in top]
        details = store.lookup_chunks_by_id(self._db, ids)

        hits: list[Hit] = []
        for chunk_id, score, source in top:
            if chunk_id not in details:
                continue
            path, text, mtime = details[chunk_id]
            name = Path(path).name
            snippet = _trim_snippet(text, query)
            hits.append(
                Hit(
                    path=path,
                    name=name,
                    snippet=snippet,
                    score=score,
                    mtime=mtime,
                    source=source,
                )
            )
        return hits

    def _fts_hits(self, query: str, *, k: int) -> list[tuple[int, float]]:
        terms = _extract_terms(query)
        if not terms:
            return []

        def _exec(expr: str) -> list[tuple[int, float]]:
            with self._lock:
                rows = self._db.execute(
                    f"""
                    SELECT rowid AS id,
                           bm25(content_fts, {_BM25_NAME_WEIGHT}, {_BM25_TEXT_WEIGHT}) AS rank
                    FROM content_fts
                    WHERE content_fts MATCH ?
                    ORDER BY rank
                    LIMIT ?
                    """,
                    (expr, k),
                ).fetchall()
            return [(int(r["id"]), float(r["rank"] or 0.0)) for r in rows]

        # AND-first: prefer files matching every non-stopword term. If that
        # yields nothing, fall back to OR so recall is preserved.
        if len(terms) >= 2:
            and_hits = _exec(
                _fts_match_expression(terms, prefix=True, operator="AND")
            )
            if and_hits:
                return and_hits
        return _exec(_fts_match_expression(terms, prefix=True, operator="OR"))

    def _vector_hits(self, query: str, *, k: int) -> list[tuple[int, float]]:
        if self._vec_index is None:
            return []
        model = self.embed_model
        if not model:
            return []
        vec = embed.embed_query(query, model_name=model)
        with self._lock:
            raw = vectors.query(self._vec_index, vec, k=k)
        return raw

    def close(self) -> None:
        try:
            with self._lock:
                self._db.close()
        except Exception:
            pass


# ─── Module-level handle cache ────────────────────────────────────────────────

_handle_lock = threading.Lock()
_handle: IndexHandle | None = None
_handle_dir: Path | None = None


def get_handle(index_dir: Path) -> IndexHandle | None:
    """Open the index at `index_dir` (once per process)."""
    global _handle, _handle_dir
    with _handle_lock:
        if _handle is not None and _handle_dir == index_dir:
            return _handle
        if _handle is not None:
            _handle.close()
            _handle = None
            _handle_dir = None
        db_path = index_dir / "index.db"
        if not db_path.exists():
            return None
        conn = store.connect(db_path, create=False)
        vec_index, vec_meta = vectors.load_index(
            index_dir / "vectors.bin",
            index_dir / "vectors_meta.json",
        )
        _handle = IndexHandle(
            db=conn, vec_index=vec_index, vec_meta=vec_meta, index_dir=index_dir
        )
        _handle_dir = index_dir
        return _handle


def reset_handle() -> None:
    """Force the next `get_handle` call to reopen the DB (used after rebuild)."""
    global _handle, _handle_dir
    with _handle_lock:
        if _handle is not None:
            _handle.close()
        _handle = None
        _handle_dir = None


# ─── Helpers ──────────────────────────────────────────────────────────────────

_WORD_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_'-]{1,}")
_STOPWORDS = frozenset(
    {
        "the", "a", "an", "of", "to", "and", "or", "is", "are",
        "was", "were", "be", "my", "me", "i", "you", "your",
        "what", "whats", "where", "when", "who", "whom", "how",
        "do", "does", "did", "can", "could", "should", "would",
        "that", "this", "these", "those", "have", "has", "had",
        "on", "in", "for", "with", "about", "from",
    }
)


def _extract_terms(query: str) -> list[str]:
    tokens = [tok.lower() for tok in _WORD_RE.findall(query or "")]
    return [tok for tok in tokens if tok not in _STOPWORDS and len(tok) >= 2]


def _fts_match_expression(
    terms: list[str],
    *,
    prefix: bool,
    operator: str = "OR",
) -> str:
    if not terms:
        return ""
    op = operator.upper() if operator.upper() in ("AND", "OR") else "OR"
    # Escape double quotes for FTS5 string literals, then wrap each term.
    parts: list[str] = []
    for term in terms:
        safe = term.replace('"', '""')
        quoted = f'"{safe}"'
        if prefix:
            quoted += "*"
        parts.append(quoted)
    return f" {op} ".join(parts)


# ─── File-level fusion helpers ────────────────────────────────────────────────


def _chunk_to_file_map(
    conn: sqlite3.Connection,
    fts: list[tuple[int, float]],
    vec: list[tuple[int, float]],
) -> dict[int, tuple[int, str, str]]:
    """Return `{chunk_id: (file_id, path, name)}` for every chunk that
    appears in either retrieval channel."""
    ids: set[int] = set()
    for cid, _ in fts:
        ids.add(cid)
    for cid, _ in vec:
        ids.add(cid)
    if not ids:
        return {}
    qmarks = ",".join("?" for _ in ids)
    rows = conn.execute(
        f"""
        SELECT chunks.id AS cid, files.id AS fid,
               files.path AS path, files.name AS name
        FROM chunks JOIN files ON files.id = chunks.file_id
        WHERE chunks.id IN ({qmarks})
        """,
        list(ids),
    ).fetchall()
    return {int(r["cid"]): (int(r["fid"]), str(r["path"]), str(r["name"])) for r in rows}


def _collapse_to_files(
    hits: list[tuple[int, float]],
    chunk_to_file: dict[int, tuple[int, str, str]],
) -> tuple[list[tuple[int, float]], dict[int, int]]:
    """Reduce chunk-level hits to file-level hits.

    Returns ``(file_hits, best_chunk_per_file)`` where ``file_hits`` is the
    deduplicated ordered list and ``best_chunk_per_file`` maps each file_id
    to the chunk id that produced its best rank (used to pull the snippet
    back out for the final Hit).
    """
    file_hits: list[tuple[int, float]] = []
    seen_files: set[int] = set()
    best_chunk: dict[int, int] = {}
    for chunk_id, score in hits:
        entry = chunk_to_file.get(chunk_id)
        if entry is None:
            continue
        file_id = entry[0]
        if file_id in seen_files:
            continue
        seen_files.add(file_id)
        best_chunk[file_id] = chunk_id
        file_hits.append((file_id, score))
    return file_hits, best_chunk


def _reciprocal_rank_fusion_files(
    fts: list[tuple[int, float]],
    vec: list[tuple[int, float]],
    *,
    limit: int,
) -> list[tuple[int, float]]:
    """RRF over file-level hits. Returns `[(file_id, rrf_score), …]`."""
    scores: dict[int, float] = {}
    for rank, (file_id, _) in enumerate(fts):
        scores[file_id] = scores.get(file_id, 0.0) + 1.0 / (_RRF_K + rank + 1)
    for rank, (file_id, _) in enumerate(vec):
        scores[file_id] = scores.get(file_id, 0.0) + 1.0 / (_RRF_K + rank + 1)
    ranked = sorted(scores.items(), key=lambda kv: kv[1], reverse=True)
    return ranked[:limit]


def _file_source_map(
    fts_files: list[tuple[int, float]],
    vec_files: list[tuple[int, float]],
) -> dict[int, str]:
    in_fts = {fid for fid, _ in fts_files}
    in_vec = {fid for fid, _ in vec_files}
    out: dict[int, str] = {}
    for fid in in_fts | in_vec:
        if fid in in_fts and fid in in_vec:
            out[fid] = "hybrid"
        elif fid in in_fts:
            out[fid] = "fts"
        else:
            out[fid] = "vector"
    return out


def _filename_boost(
    file_id: int,
    terms: set[str],
    chunk_to_file: dict[int, tuple[int, str, str]],
) -> float:
    """Small positive score when the basename contains a query term."""
    if not terms:
        return 0.0
    name = ""
    for entry in chunk_to_file.values():
        if entry[0] == file_id:
            name = entry[2]
            break
    if not name:
        return 0.0
    stem = Path(name).stem.lower()
    name_tokens = {tok for tok in re.split(r"[^A-Za-z0-9]+", stem) if tok}
    if terms & name_tokens:
        return _FILENAME_MATCH_BOOST
    return 0.0


# ─── Snippet formatting ───────────────────────────────────────────────────────


def _trim_snippet(text: str, query: str, *, width: int = 320) -> str:
    text = (text or "").strip()
    if len(text) <= width:
        return text
    terms = _extract_terms(query)
    low = text.lower()
    for term in terms:
        idx = low.find(term)
        if idx >= 0:
            start = max(0, idx - width // 3)
            end = min(len(text), start + width)
            prefix = "…" if start > 0 else ""
            suffix = "…" if end < len(text) else ""
            return prefix + text[start:end].strip() + suffix
    return text[:width].strip() + "…"
