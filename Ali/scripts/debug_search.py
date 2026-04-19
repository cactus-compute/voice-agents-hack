#!/usr/bin/env python3
"""
Inspect the disk-index retrieval stack for a given query.

Prints (in order):
  * FTS-only top-k chunks, with the file they come from.
  * Vector-only top-k chunks (if embeddings are available).
  * The fused, file-deduplicated, filename-boosted top-k that
    `search_content` would return to the RAG answerer.
  * A separate run of `search_files` (pure filename-weighted BM25) for
    comparison.

Useful when a RAG answer cites the wrong file — run it against the same
query, see which channel brought in the wrong hit, and tune from there.

Usage:
    python scripts/debug_search.py "my resume in downloads"
    python scripts/debug_search.py --k 8 "what did Alice say about launch"
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

_HERE = Path(__file__).resolve()
_ROOT = _HERE.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Debug disk-index retrieval for a query."
    )
    parser.add_argument("query", help="Natural-language query to run.")
    parser.add_argument(
        "--k",
        type=int,
        default=5,
        help="Top-k for each channel (default: 5).",
    )
    parser.add_argument(
        "--index-dir",
        type=Path,
        default=None,
        help="Override the index directory (defaults to ALI_INDEX_DIR / "
             "config.settings.INDEX_DIR).",
    )
    args = parser.parse_args(argv)

    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    from config.settings import INDEX_DIR
    from executors.local.disk_index import retrieve as retrieve_mod
    from executors.local.disk_index import store

    index_dir = args.index_dir or INDEX_DIR
    if not (index_dir / "index.db").exists():
        print(f"[debug-search] no index at {index_dir}", file=sys.stderr)
        return 1

    handle = retrieve_mod.get_handle(index_dir)
    if handle is None:
        print(f"[debug-search] could not open handle at {index_dir}", file=sys.stderr)
        return 1

    terms = retrieve_mod._extract_terms(args.query)
    print(f"query      : {args.query!r}")
    print(f"index_dir  : {index_dir}")
    print(f"terms      : {terms}")
    print(f"vectors    : {'available' if handle.vectors_available else 'none'}")
    print()

    # ─── FTS channel ──────────────────────────────────────────────────────────
    fts_hits = handle._fts_hits(args.query, k=args.k)
    print(f"FTS top-{len(fts_hits)} (bm25 column-weighted name=5.0, text=1.0):")
    _print_chunk_rows(handle, fts_hits)
    print()

    # ─── Vector channel ───────────────────────────────────────────────────────
    vec_hits = handle._vector_hits(args.query, k=args.k)
    print(f"Vector top-{len(vec_hits)} (cosine):")
    if not vec_hits:
        print("  (no vectors available or embedder missing)")
    else:
        _print_chunk_rows(handle, vec_hits)
    print()

    # ─── Fused (what RAG actually sees) ───────────────────────────────────────
    fused = handle.search_content(args.query, k=args.k)
    print(f"Fused top-{len(fused)} (file-deduplicated, filename-boosted):")
    if not fused:
        print("  (no hits)")
    for i, hit in enumerate(fused, 1):
        name = hit.name or Path(hit.path).name
        snippet = (hit.snippet or "").replace("\n", " ")[:100]
        print(
            f"  {i:>2}. {name:<40}  score={hit.score:+.4f}  src={hit.source}"
        )
        print(f"      path: {hit.path}")
        if snippet:
            print(f"      snip: {snippet}")
    print()

    # ─── Filename-only view ──────────────────────────────────────────────────
    files = handle.search_files(args.query, limit=args.k)
    print(f"search_files top-{len(files)} (filename-weighted FTS):")
    if not files:
        print("  (no hits)")
    for i, f in enumerate(files, 1):
        print(f"  {i:>2}. {f.name:<40}  rank={f.score:+.4f}")
        print(f"      path: {f.path}")
    return 0


def _print_chunk_rows(handle, rows: list[tuple[int, float]]) -> None:
    if not rows:
        print("  (no hits)")
        return
    ids = [cid for cid, _ in rows]
    from executors.local.disk_index import store

    details = store.lookup_chunks_by_id(handle._db, ids)
    # Also fetch file names + paths in a single query (lookup_chunks_by_id
    # returns (path, snippet, mtime) but not file_id — that's fine here).
    for i, (cid, rank) in enumerate(rows, 1):
        if cid not in details:
            print(f"  {i:>2}. chunk_id={cid} rank={rank:+.4f} (detail missing)")
            continue
        path, text, _mtime = details[cid]
        name = Path(path).name
        snippet = (text or "").replace("\n", " ")[:80]
        print(f"  {i:>2}. {name:<40}  rank={rank:+.4f}")
        print(f"      path: {path}")
        if snippet:
            print(f"      snip: {snippet}")


if __name__ == "__main__":
    raise SystemExit(main())
