#!/usr/bin/env python3
"""
Build or rebuild the Ali laptop-wide disk index.

Used by:
  * the startup bootstrap (runs once, first launch)
  * the menu bar "Rebuild Index…" item
  * manual invocation:  python scripts/build_index.py

Output model:
  * stderr — tqdm progress bars + human-readable `[build_index +Xs] …` lines
  * stdout — machine-readable progress events, one JSON object per line,
    prefixed with `PROGRESS ` (consumed by `config/index_bootstrap.py`
    when spawned as a background subprocess so it can update the GUI)
  * stdout — final summary as a single JSON line (last line emitted)
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path

# Allow running as `python scripts/build_index.py` from the project root.
_HERE = Path(__file__).resolve()
_ROOT = _HERE.parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))


def _emit_event(event: str, data: dict) -> None:
    """Write a structured progress event to stdout for the parent process."""
    try:
        line = "PROGRESS " + json.dumps({"event": event, **data})
    except (TypeError, ValueError):
        return
    print(line, flush=True)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Build or update the Ali disk index")
    parser.add_argument(
        "--quiet",
        action="store_true",
        help="suppress progress output (final JSON summary still emitted)",
    )
    parser.add_argument(
        "--no-embeddings",
        action="store_true",
        help="skip the embedding pass (metadata + FTS only)",
    )
    parser.add_argument(
        "--full",
        action="store_true",
        help=(
            "wipe the existing index and rebuild from scratch. Default is "
            "incremental: unchanged files are skipped, modified files are "
            "re-extracted, and previously embedded chunks are reused."
        ),
    )
    parser.add_argument(
        "--full-disk",
        action="store_true",
        help=(
            "expand the filesystem scan scope to the full home directory "
            "plus /Applications. Default scope is Documents + Downloads + "
            "Desktop + /Applications, plus Contacts / Calendar / Messages."
        ),
    )
    args = parser.parse_args(argv)

    # Honour --full-disk by setting the env var _before_ we import settings,
    # so INDEX_SCAN_ROOTS is computed against the broader default.
    if args.full_disk:
        os.environ["ALI_INDEX_FULL_DISK"] = "1"

    os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

    try:
        from tqdm import tqdm  # type: ignore
    except ImportError:
        tqdm = None  # noqa: N816 — keep the name tqdm for clarity

    from config.resources import FILE_ALIASES
    from config.settings import (
        INDEX_CHUNK_TOKENS,
        INDEX_DIR,
        INDEX_EMBED_MODEL,
        INDEX_ENABLE_EMBEDDINGS,
        INDEX_MAX_FILE_BYTES,
        INDEX_SCAN_ROOTS,
        INDEX_SOURCE_HISTORY_DAYS,
        INDEX_SOURCES,
    )
    from executors.local.disk_index.build import BuildConfig, run_build

    resume_raw = FILE_ALIASES.get("resume")
    resume_path = os.path.expanduser(resume_raw) if resume_raw else None
    if resume_path and not Path(resume_path).is_file():
        resume_path = None

    cfg = BuildConfig(
        index_dir=Path(INDEX_DIR),
        scan_roots=list(INDEX_SCAN_ROOTS),
        max_file_bytes=INDEX_MAX_FILE_BYTES,
        embed_model=INDEX_EMBED_MODEL,
        enable_embeddings=INDEX_ENABLE_EMBEDDINGS and not args.no_embeddings,
        chunk_tokens=INDEX_CHUNK_TOKENS,
        resume_path=resume_path,
        source_names=list(INDEX_SOURCES),
        source_history_days=INDEX_SOURCE_HISTORY_DAYS,
    )

    started = time.time()

    # Writers — tqdm.write()/sys.stderr.write() avoid breaking the bar.
    def _say(msg: str) -> None:
        if args.quiet:
            return
        elapsed = int(time.time() - started)
        line = f"[build_index +{elapsed:>4}s] {msg}"
        if tqdm is not None:
            tqdm.write(line, file=sys.stderr)
        else:
            print(line, file=sys.stderr, flush=True)

    extract_bar = None
    embed_bar = None

    def _close_bars() -> None:
        nonlocal extract_bar, embed_bar
        if extract_bar is not None:
            extract_bar.close()
            extract_bar = None
        if embed_bar is not None:
            embed_bar.close()
            embed_bar = None

    def progress(event: str, data: dict) -> None:
        nonlocal extract_bar, embed_bar

        # Always emit structured events so the parent (GUI) can follow along,
        # even when --quiet was passed (the GUI wants progress either way).
        _emit_event(event, data)

        if args.quiet:
            return

        if event == "start":
            _say(
                f"starting ({data.get('mode', 'incremental')}); "
                f"roots={', '.join(data.get('roots') or []) or '(none)'}  "
                f"embeddings={'on' if data.get('embeddings') else 'off'}"
            )
        elif event == "walk_start":
            _say("walking filesystem (this is the longest phase on first run)…")
        elif event == "discovery_done":
            total = int(data.get("total", 0))
            _say(f"discovered {total:,} files — starting extraction")
            if tqdm is not None and total > 0:
                extract_bar = tqdm(
                    total=total,
                    desc="extract",
                    unit="file",
                    file=sys.stderr,
                    dynamic_ncols=True,
                    smoothing=0.05,
                )
        elif event == "progress":
            files = int(data.get("files", 0))
            if extract_bar is not None:
                extract_bar.n = files
                latest = str(data.get("latest") or "")[:40]
                extract_bar.set_postfix_str(f"chunks={data.get('chunks', 0)} · {latest}", refresh=True)
        elif event == "extract_done":
            if extract_bar is not None:
                extract_bar.n = extract_bar.total or int(data.get("files", 0))
                extract_bar.refresh()
                extract_bar.close()
                extract_bar = None
            _say(
                "extract done: "
                f"files={data.get('files')} chunks={data.get('chunks')}  "
                f"(added={data.get('added', 0)} updated={data.get('updated', 0)} "
                f"unchanged={data.get('unchanged', 0)} removed={data.get('removed', 0)})"
            )
        elif event == "embed_skipped":
            reason = data.get("reason", "")
            _say(f"embedding phase skipped ({reason})")
        elif event == "embed_model_load":
            _say(
                f"loading embedding model ({data.get('model')}); first run "
                "downloads ~90MB from HuggingFace…"
            )
        elif event == "embed_model_ready":
            _say(f"embedding model ready ({data.get('model')})")
        elif event == "embed_start":
            total = int(data.get("count", 0))
            _say(f"embedding {total:,} chunks…")
            if tqdm is not None and total > 0:
                embed_bar = tqdm(
                    total=total,
                    desc="embed",
                    unit="chunk",
                    file=sys.stderr,
                    dynamic_ncols=True,
                    smoothing=0.05,
                )
        elif event == "embed_progress":
            if embed_bar is not None:
                embed_bar.n = int(data.get("done", 0))
                embed_bar.refresh()
        elif event == "vector_build_start":
            if embed_bar is not None:
                embed_bar.n = embed_bar.total or int(data.get("count", 0))
                embed_bar.refresh()
                embed_bar.close()
                embed_bar = None
            _say(f"building HNSW index (count={data.get('count')})")
        elif event == "vector_build_done":
            _say("HNSW index saved")
        elif event == "profile_start":
            _say("building user profile…")
        elif event == "profile_error":
            _say(f"[warn] profile error: {data.get('err')}")
        elif event == "profile_done":
            _say("profile written")
        elif event == "source_pass_start":
            sources = data.get("sources") or []
            if sources:
                _say(f"pulling from data sources: {', '.join(sources)}")
        elif event == "source_start":
            _say(f"  • {data.get('source')} — enumerating…")
        elif event == "source_progress":
            _say(
                f"  • {data.get('source')} docs={data.get('docs')} "
                f"(added={data.get('added',0)} updated={data.get('updated',0)} "
                f"unchanged={data.get('unchanged',0)})"
            )
        elif event == "source_done":
            _say(
                f"  ✓ {data.get('source')} docs={data.get('docs')} "
                f"chunks={data.get('chunks')} "
                f"(added={data.get('added',0)} updated={data.get('updated',0)} "
                f"unchanged={data.get('unchanged',0)} "
                f"removed={data.get('removed',0)})"
            )
        elif event == "source_error":
            _say(f"  ! {data.get('source')} error: {data.get('err')}")
        elif event == "done":
            _say(
                f"done in {data.get('duration_s')}s — "
                f"files={data.get('files')} chunks={data.get('chunks')} "
                f"embedded={data.get('embedded')}"
            )

    try:
        result = run_build(cfg, progress=progress, force_rebuild=args.full)
    except Exception as exc:
        import traceback

        _close_bars()
        # Always surface the traceback on stderr so the parent terminal
        # sees exactly what went wrong — otherwise `rc=1 after 0s` tells
        # you nothing.
        traceback.print_exc(file=sys.stderr)
        sys.stderr.flush()
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": f"{type(exc).__name__}: {exc}",
                    "traceback": traceback.format_exc(),
                    "duration_s": round(time.time() - started, 2),
                }
            )
        )
        return 1
    finally:
        _close_bars()

    print(
        json.dumps(
            {
                "ok": True,
                "files": result.files,
                "chunks": result.chunks,
                "embedded": result.embedded,
                "duration_s": round(result.duration_s, 2),
                "index_dir": str(cfg.index_dir),
            }
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
