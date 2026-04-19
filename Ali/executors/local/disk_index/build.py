"""
Orchestrator for a full / incremental index build.

Pipeline:
  1. Discover candidate files (bounded walk, deny-list).
  2. For each candidate, decide unchanged | new | modified by comparing the
     on-disk mtime to the row already in SQLite.
  3. Extract + chunk modified/new files; keep unchanged files verbatim.
  4. Drop rows for files that no longer exist on disk.
  5. Embed only chunks whose `vector` column is NULL (resumable).
  6. Rebuild the hnswlib HNSW index from every chunk that has a vector.
  7. Rebuild the user profile JSON.

Runs in a subprocess (see `scripts/build_index.py`) so the embedder's big
tensors don't share state with the agent's asyncio loop.

Pass `force_rebuild=True` to wipe the DB + vector artefacts and redo
everything from scratch; the default (False) resumes an interrupted build
and incrementally updates an existing one.
"""

from __future__ import annotations

import os
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable

from . import discovery, embed, extract, profile, store, vectors
from .sources import load_sources as load_data_sources
from .sources.base import SyntheticDoc, is_synthetic_path


ProgressFn = Callable[[str, dict], None]


@dataclass
class BuildConfig:
    index_dir: Path
    scan_roots: list[Path]
    max_file_bytes: int
    embed_model: str
    enable_embeddings: bool
    chunk_tokens: int
    resume_path: str | None
    source_names: list[str] = field(default_factory=list)
    source_history_days: int = 365


@dataclass
class BuildResult:
    files: int
    chunks: int
    embedded: int
    duration_s: float
    files_added: int = 0
    files_updated: int = 0
    files_unchanged: int = 0
    files_removed: int = 0
    chunks_embedded_this_run: int = 0


def run_build(
    cfg: BuildConfig,
    *,
    progress: ProgressFn | None = None,
    force_rebuild: bool = False,
) -> BuildResult:
    started = time.time()
    _emit(
        progress,
        "start",
        {
            "index_dir": str(cfg.index_dir),
            "roots": [str(r) for r in cfg.scan_roots],
            "embeddings": cfg.enable_embeddings,
            "mode": "full" if force_rebuild else "incremental",
        },
    )

    db_path = cfg.index_dir / "index.db"
    vec_bin = cfg.index_dir / "vectors.bin"
    vec_meta = cfg.index_dir / "vectors_meta.json"
    profile_path = cfg.index_dir / "profile.json"

    if force_rebuild:
        # Unlink the DB *and* its WAL/SHM sidecars — leaving the sidecars
        # around orphans the write-ahead log, which confuses SQLite when it
        # recreates index.db and causes the next connect() to crash with a
        # malformed-schema error.
        sidecars = (
            db_path,
            db_path.with_name(db_path.name + "-wal"),
            db_path.with_name(db_path.name + "-shm"),
            db_path.with_name(db_path.name + "-journal"),
            vec_bin,
            vec_meta,
        )
        for p in sidecars:
            try:
                if p.exists():
                    p.unlink()
            except OSError as exc:
                print(f"[disk-index] could not remove {p}: {exc}")

    conn = store.connect(db_path, create=True)
    files_added = files_updated = files_unchanged = files_removed = 0

    # Build the user profile EARLY — it's a few hundred ms on macOS and makes
    # "who am I" / "what's my email" queries work from the first second of the
    # build rather than forcing users to wait until the extract phase
    # completes. We refresh it again at the end to pick up resume snippets that
    # depend on the finished index.
    _emit(progress, "profile_start", {"phase": "early"})
    try:
        profile.build_profile(resume_path=cfg.resume_path, output_path=profile_path)
        _emit(progress, "profile_done", {"phase": "early"})
    except Exception as exc:
        _emit(progress, "profile_error", {"phase": "early", "err": str(exc)[:200]})

    try:
        _emit(progress, "walk_start", {"roots": [str(r) for r in cfg.scan_roots]})

        all_candidates = list(
            discovery.iter_candidates(
                cfg.scan_roots, max_file_bytes=cfg.max_file_bytes
            )
        )
        total_candidates = len(all_candidates)
        _emit(progress, "discovery_done", {"total": total_candidates})

        conn.execute("BEGIN")
        file_count = 0
        chunk_count = 0
        seen_paths: set[str] = set()
        last_heartbeat = time.time()
        for cand in all_candidates:
            file_count += 1
            path_str = str(cand.path)
            seen_paths.add(path_str)

            existing = store.lookup_file(conn, path_str)
            stored_mtime = existing[1] if existing else None
            unchanged = (
                existing is not None
                and stored_mtime is not None
                and stored_mtime >= cand.mtime
            )

            if unchanged:
                files_unchanged += 1
                # Count chunks we already have so the progress bar stays
                # meaningful even during a fast resume.
                existing_rows = conn.execute(
                    "SELECT COUNT(*) AS c FROM chunks WHERE file_id = ?",
                    (existing[0],),
                ).fetchone()
                chunk_count += int(existing_rows["c"])
            else:
                # Code / config files: register a filename-only row so they
                # remain findable via FTS without embedding source bodies.
                if extract.is_code_file(cand.path):
                    chunks = [extract.filename_index_text(cand.path)]
                    content_ok = False  # filename-only, no real content
                else:
                    content = extract.extract_text(cand.path)
                    chunks = (
                        extract.chunk_text(content, chunk_tokens=cfg.chunk_tokens)
                        if content
                        else []
                    )
                    content_ok = bool(chunks)
                    # If extraction produced nothing (scanned PDF, exotic
                    # format, unreadable docx), fall back to a filename-only
                    # chunk so the file stays reachable via FTS by name.
                    # Without this a resume.pdf that pypdf can't parse is
                    # invisible to every search.
                    if not chunks:
                        chunks = [extract.filename_index_text(cand.path)]
                file_id = store.upsert_file(
                    conn,
                    path=path_str,
                    name=cand.path.name,
                    ext=cand.ext or None,
                    size=cand.size,
                    mtime=cand.mtime,
                    mime=extract.guess_mime(cand.path),
                    content_ok=content_ok,
                )
                store.clear_chunks(conn, file_id)
                if chunks:
                    store.insert_chunks(conn, file_id, chunks)
                    chunk_count += len(chunks)
                if existing is None:
                    files_added += 1
                else:
                    files_updated += 1

            now = time.time()
            if file_count % 50 == 0 or (now - last_heartbeat) >= 0.5:
                _emit(
                    progress,
                    "progress",
                    {
                        "files": file_count,
                        "chunks": chunk_count,
                        "total": total_candidates,
                        "stage": "extract",
                        "latest": cand.path.name,
                        "added": files_added,
                        "updated": files_updated,
                        "unchanged": files_unchanged,
                    },
                )
                last_heartbeat = now
                conn.execute("COMMIT")
                conn.execute("BEGIN")
        conn.execute("COMMIT")

        # Deletion sweep: any row whose on-disk file disappeared gets dropped.
        # Synthetic paths (ali://…) are handled during their own source pass,
        # so we skip them here.
        conn.execute("BEGIN")
        for fid, path in store.iter_all_paths(conn):
            if is_synthetic_path(path):
                continue
            if path in seen_paths:
                continue
            if not _path_is_under_any_root(path, cfg.scan_roots):
                # The scan scope may have narrowed since last run; don't
                # delete rows that are simply out-of-scope now.
                continue
            if not os.path.exists(path):
                store.delete_file(conn, fid)
                files_removed += 1
        conn.execute("COMMIT")

        # ── Data sources (Contacts, Calendar, Messages, …) ────────────────────
        source_stats = _ingest_data_sources(
            conn,
            cfg=cfg,
            progress=progress,
        )
        files_added += source_stats["added"]
        files_updated += source_stats["updated"]
        files_unchanged += source_stats["unchanged"]
        files_removed += source_stats["removed"]
        chunk_count += source_stats["chunks"]

        _emit(
            progress,
            "extract_done",
            {
                "files": file_count,
                "chunks": chunk_count,
                "added": files_added,
                "updated": files_updated,
                "unchanged": files_unchanged,
                "removed": files_removed,
            },
        )

        chunks_embedded_this_run = 0
        if cfg.enable_embeddings:
            if (
                files_added == 0
                and files_updated == 0
                and files_removed == 0
                and vec_bin.exists()
                and vec_meta.exists()
                and store.count_chunks_needing_embedding(conn) == 0
            ):
                _emit(progress, "embed_skipped", {"reason": "no_changes"})
            else:
                chunks_embedded_this_run = _embed_missing_and_rebuild_vectors(
                    conn,
                    vec_bin=vec_bin,
                    vec_meta=vec_meta,
                    model_name=cfg.embed_model,
                    progress=progress,
                )
        else:
            _emit(progress, "embed_skipped", {"reason": "disabled"})

        total_embedded = store.count_embedded_chunks(conn)
        store.set_manifest(conn, "built_at", str(time.time()))
        store.set_manifest(conn, "files", str(store.count_files(conn)))
        store.set_manifest(conn, "chunks", str(chunk_count))
        store.set_manifest(conn, "embedded", str(total_embedded))
        store.set_manifest(conn, "embed_model", cfg.embed_model)

    finally:
        conn.close()

    _emit(progress, "profile_start", {"phase": "final"})
    try:
        profile.build_profile(resume_path=cfg.resume_path, output_path=profile_path)
    except Exception as exc:
        _emit(progress, "profile_error", {"phase": "final", "err": str(exc)[:200]})
    _emit(progress, "profile_done", {"phase": "final"})

    duration = time.time() - started
    result = BuildResult(
        files=file_count,
        chunks=chunk_count,
        embedded=total_embedded if cfg.enable_embeddings else 0,
        duration_s=duration,
        files_added=files_added,
        files_updated=files_updated,
        files_unchanged=files_unchanged,
        files_removed=files_removed,
        chunks_embedded_this_run=chunks_embedded_this_run,
    )
    _emit(
        progress,
        "done",
        {
            "files": result.files,
            "chunks": result.chunks,
            "embedded": result.embedded,
            "duration_s": round(duration, 1),
            "added": files_added,
            "updated": files_updated,
            "unchanged": files_unchanged,
            "removed": files_removed,
            "chunks_embedded_this_run": chunks_embedded_this_run,
        },
    )
    return result


def _embed_missing_and_rebuild_vectors(
    conn,
    *,
    vec_bin: Path,
    vec_meta: Path,
    model_name: str,
    progress: ProgressFn | None,
) -> int:
    """Embed chunks that still have `vector IS NULL`, then rebuild HNSW from
    every chunk whose vector is present in the DB."""
    import numpy as np

    missing = store.count_chunks_needing_embedding(conn)
    total_embedded = store.count_embedded_chunks(conn)
    _emit(
        progress,
        "embed_start",
        {"count": missing, "already_embedded": total_embedded},
    )

    if missing > 0:
        _emit(progress, "embed_model_load", {"model": model_name})
        embed.warmup(model_name)
        _emit(progress, "embed_model_ready", {"model": model_name})

    chunks_embedded_this_run = 0
    batch_size = 64
    pending_ids: list[int] = []
    pending_texts: list[str] = []
    last_heartbeat = time.time()

    def _flush_batch() -> None:
        nonlocal chunks_embedded_this_run, last_heartbeat
        if not pending_ids:
            return
        vecs = embed.embed_texts(
            pending_texts,
            model_name=model_name,
            batch_size=batch_size,
            show_progress=False,
        )
        updates = [
            (cid, vec.astype("float32").tobytes())
            for cid, vec in zip(pending_ids, vecs)
        ]
        conn.execute("BEGIN")
        store.update_chunk_vectors(conn, updates)
        conn.execute("COMMIT")
        chunks_embedded_this_run += len(updates)
        pending_ids.clear()
        pending_texts.clear()
        now = time.time()
        if (now - last_heartbeat) >= 0.5 or chunks_embedded_this_run == missing:
            _emit(
                progress,
                "embed_progress",
                {
                    "done": chunks_embedded_this_run,
                    "total": missing,
                },
            )
            last_heartbeat = now

    for chunk_id, text in store.iter_unembedded_chunks(conn):
        pending_ids.append(chunk_id)
        pending_texts.append(text)
        if len(pending_ids) >= batch_size:
            _flush_batch()
    _flush_batch()

    # Rebuild HNSW from the full DB so any re-indexed or newly-added chunks
    # are reflected in top-k results.
    ids: list[int] = []
    blobs: list[bytes] = []
    for chunk_id, blob in store.iter_embedded_chunks(conn):
        ids.append(chunk_id)
        blobs.append(blob)

    if not ids:
        return chunks_embedded_this_run

    vectors_np = np.frombuffer(b"".join(blobs), dtype="float32").reshape(
        len(ids), embed.EMBED_DIM
    )
    _emit(progress, "vector_build_start", {"count": len(ids)})
    vectors.build_index(
        vec_bin,
        vec_meta,
        ids=ids,
        vectors=vectors_np,
        model_name=model_name,
    )
    _emit(progress, "vector_build_done", {"count": len(ids)})
    return chunks_embedded_this_run


def _ingest_data_sources(
    conn,
    *,
    cfg: BuildConfig,
    progress: ProgressFn | None,
) -> dict:
    """Pull synthetic docs from each enabled data source and merge them into
    the index. Returns per-source statistics."""
    stats = {"added": 0, "updated": 0, "unchanged": 0, "removed": 0, "chunks": 0}
    if not cfg.source_names:
        return stats

    sources = load_data_sources(
        cfg.source_names, history_days=cfg.source_history_days
    )
    if not sources:
        return stats

    _emit(
        progress,
        "source_pass_start",
        {"sources": [s.name for s in sources]},
    )

    for source in sources:
        source_added = 0
        source_updated = 0
        source_unchanged = 0
        source_chunks = 0
        seen_paths: set[str] = set()
        _emit(progress, "source_start", {"source": source.name})

        last_tick = time.time()
        conn.execute("BEGIN")
        doc_count = 0
        try:
            for doc in source.iter_docs():
                doc_count += 1
                seen_paths.add(doc.path)
                existing = store.lookup_file(conn, doc.path)
                stored_mtime = existing[1] if existing else None
                unchanged = (
                    existing is not None
                    and stored_mtime is not None
                    and stored_mtime >= doc.mtime
                )
                if unchanged:
                    source_unchanged += 1
                    rows = conn.execute(
                        "SELECT COUNT(*) AS c FROM chunks WHERE file_id = ?",
                        (existing[0],),
                    ).fetchone()
                    source_chunks += int(rows["c"])
                else:
                    chunks = extract.chunk_text(
                        doc.content, chunk_tokens=cfg.chunk_tokens
                    )
                    file_id = store.upsert_file(
                        conn,
                        path=doc.path,
                        name=doc.display_name or f"{source.name}:{doc.id}",
                        ext=f".{source.name}",
                        size=doc.size,
                        mtime=doc.mtime,
                        mime=f"application/x-ali-{source.name}",
                        content_ok=bool(chunks),
                    )
                    store.clear_chunks(conn, file_id)
                    if chunks:
                        store.insert_chunks(conn, file_id, chunks)
                        source_chunks += len(chunks)
                    if existing is None:
                        source_added += 1
                    else:
                        source_updated += 1

                now = time.time()
                if doc_count % 50 == 0 or (now - last_tick) >= 0.5:
                    _emit(
                        progress,
                        "source_progress",
                        {
                            "source": source.name,
                            "docs": doc_count,
                            "added": source_added,
                            "updated": source_updated,
                            "unchanged": source_unchanged,
                        },
                    )
                    last_tick = now
                    conn.execute("COMMIT")
                    conn.execute("BEGIN")
            conn.execute("COMMIT")
        except Exception as exc:
            conn.execute("ROLLBACK")
            _emit(
                progress,
                "source_error",
                {"source": source.name, "err": str(exc)[:200]},
            )
            continue

        # Delete synthetic rows that this source no longer produces
        # (e.g. a contact was deleted).
        source_removed = 0
        prefix = f"ali://{source.name}/"
        conn.execute("BEGIN")
        for fid, path in store.iter_all_paths(conn):
            if not path.startswith(prefix):
                continue
            if path in seen_paths:
                continue
            store.delete_file(conn, fid)
            source_removed += 1
        conn.execute("COMMIT")

        stats["added"] += source_added
        stats["updated"] += source_updated
        stats["unchanged"] += source_unchanged
        stats["removed"] += source_removed
        stats["chunks"] += source_chunks

        _emit(
            progress,
            "source_done",
            {
                "source": source.name,
                "docs": doc_count,
                "added": source_added,
                "updated": source_updated,
                "unchanged": source_unchanged,
                "removed": source_removed,
                "chunks": source_chunks,
            },
        )

    return stats


def _path_is_under_any_root(path: str, roots: list[Path]) -> bool:
    try:
        p = Path(path).resolve()
    except OSError:
        return False
    for root in roots:
        try:
            root_resolved = root.expanduser().resolve()
        except OSError:
            continue
        try:
            p.relative_to(root_resolved)
            return True
        except ValueError:
            continue
    return False


def _emit(progress: ProgressFn | None, event: str, data: dict) -> None:
    if progress is not None:
        try:
            progress(event, data)
        except Exception:
            pass
    else:
        print(f"[disk-index] {event} {data}")
