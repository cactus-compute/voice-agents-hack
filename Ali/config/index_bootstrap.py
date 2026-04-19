"""
Startup bootstrap for the disk index.

Invoked once from `main.py` right after preflight. If the index is missing
(or the user asked for a rebuild), we spawn `scripts/build_index.py` as a
subprocess so the heavyweight embedding step runs in a clean interpreter
and doesn't share state with the agent's asyncio loop.

Default behaviour is **background**: the build runs in a subprocess while
main.py continues to bring up the UI and agent loop. Because the index is a
SQLite WAL DB with commits every ~2s, queries against it immediately return
whatever has been indexed so far. Semantic (vector) search and the user
profile aren't available until the build's final step.

Progress protocol:
    The build script writes tqdm output to **stderr** (inherited by this
    process so the user sees it in the terminal) and structured progress
    events to **stdout** as lines prefixed with ``PROGRESS `` followed by a
    JSON object. We capture stdout, parse those events, and forward them
    to the caller-supplied callback (typically the menu bar / overlay).
"""

from __future__ import annotations

import atexit
import json
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path
from typing import Callable


ProgressCallback = Callable[[str, dict], None]


_HERE = Path(__file__).resolve()
_ROOT = _HERE.parent.parent
_BUILD_SCRIPT = _ROOT / "scripts" / "build_index.py"


_active_proc: subprocess.Popen | None = None
_active_lock = threading.Lock()


def ensure_index(
    *,
    force_rebuild: bool = False,
    skip: bool = False,
    background: bool = True,
    on_progress: ProgressCallback | None = None,
    on_complete: Callable[[bool], None] | None = None,
) -> None:
    """Ensure the disk index exists and is up-to-date.

    Default behaviour (`python main.py`):
      * no index yet              → build one in the background
      * partial index on disk     → **resume** the incremental build in the
        background (picks up exactly where the last run left off, reusing
        already-embedded chunks)
      * fully-built index         → skip; use as-is

    Parameters
    ----------
    force_rebuild
        Wipe the existing index and rebuild from scratch (`--rebuild-index`).
    skip
        Bypass the auto-resume behaviour entirely (`--skip-index`). Useful
        when you just want to launch the UI against whatever is on disk.
    background
        If True (default), spawn the build as a detached Popen and return
        immediately so the caller can bring up the UI. If False, block until
        the build finishes.
    on_progress, on_complete
        Optional callbacks; see docstring on the watcher thread.
    """
    from executors.local.disk_index import (
        index_exists,
        index_is_complete,
        index_stats,
        reset_handle,
    )

    complete = index_is_complete() if not force_rebuild else False

    if skip and not force_rebuild:
        stats = index_stats()
        state = (
            "complete"
            if complete
            else ("partial — resume skipped" if index_exists() else "absent")
        )
        if stats is not None:
            print(
                f"[index] --skip-index → {state} ({stats.files} files, "
                f"{stats.chunks} chunks, built {stats.age}).",
                flush=True,
            )
        else:
            print(f"[index] --skip-index → {state}.", flush=True)
        return

    if not force_rebuild and complete:
        stats = index_stats()
        if stats is not None:
            print(
                f"[index] ready — {stats.files} files, {stats.chunks} chunks, "
                f"built {stats.age}",
                flush=True,
            )
        return

    if force_rebuild:
        print(
            "[index] --rebuild-index — wiping existing index and rebuilding "
            "from scratch.",
            flush=True,
        )
    elif index_exists():
        stats = index_stats()
        detail = ""
        if stats is not None:
            detail = (
                f" ({stats.files} files already indexed, "
                f"{stats.chunks} chunks)"
            )
        print(
            f"[index] partial index detected — resuming incremental build "
            f"in background{detail}. Already-indexed files are skipped; "
            "embedding reuses existing vectors.",
            flush=True,
        )
    else:
        print(
            "[index] indexing your laptop in the background (incremental: "
            "already-indexed files are skipped, so resuming an interrupted "
            "build is fast). You can start asking questions right away.",
            flush=True,
        )
        print(
            "[index] semantic search and the \"who am I\" profile activate "
            "once the build completes (tip: set ALI_INDEX_EMBEDDINGS=0 for a "
            "much faster build with filename + content search only).",
            flush=True,
        )

    if background:
        _spawn_background_build(
            on_progress=on_progress,
            on_complete=on_complete,
            reset_handle=reset_handle,
            force_rebuild=force_rebuild,
        )
        return

    # Blocking path: stream output through to the terminal and parse progress
    # so the caller's on_progress callback still fires.
    _blocking_build(
        on_progress=on_progress,
        reset_handle=reset_handle,
        force_rebuild=force_rebuild,
    )


def _blocking_build(
    *,
    on_progress: ProgressCallback | None,
    reset_handle: Callable[[], None],
    force_rebuild: bool,
) -> None:
    from executors.local.disk_index import index_stats

    cmd = [sys.executable, "-u", str(_BUILD_SCRIPT)]
    if force_rebuild:
        cmd.append("--full")
    proc = subprocess.Popen(
        cmd,
        cwd=str(_ROOT),
        stdout=subprocess.PIPE,
        stderr=None,  # inherit — tqdm bar goes straight to the terminal
        bufsize=1,
        text=True,
    )

    final_summary: dict | None = None
    assert proc.stdout is not None
    for raw_line in proc.stdout:
        line = raw_line.rstrip("\n")
        event = _parse_progress_line(line)
        if event is not None:
            if on_progress is not None:
                try:
                    on_progress(event["event"], event)
                except Exception:
                    pass
        elif line.startswith("{") and line.endswith("}"):
            try:
                final_summary = json.loads(line)
            except json.JSONDecodeError:
                pass

    rc = proc.wait()
    if rc != 0 or (final_summary and not final_summary.get("ok")):
        print(
            "[index][warn] build failed; continuing with whatever partial "
            "index exists (you can retry later from the menu bar).",
            flush=True,
        )
        return

    reset_handle()
    stats = index_stats()
    if stats is not None:
        print(
            f"[index] built — {stats.files} files, {stats.chunks} chunks.",
            flush=True,
        )


def _spawn_background_build(
    *,
    on_progress: ProgressCallback | None,
    on_complete: Callable[[bool], None] | None,
    reset_handle: Callable[[], None],
    force_rebuild: bool,
) -> None:
    """Launch the build script as a detached subprocess and start a watcher."""
    global _active_proc
    with _active_lock:
        if _active_proc is not None and _active_proc.poll() is None:
            print(
                "[index] build already running (pid=%d); ignoring new request"
                % _active_proc.pid,
                flush=True,
            )
            return
        cmd = [sys.executable, "-u", str(_BUILD_SCRIPT)]
        if force_rebuild:
            cmd.append("--full")
        proc = subprocess.Popen(
            cmd,
            cwd=str(_ROOT),
            stdout=subprocess.PIPE,
            stderr=None,  # inherit so the terminal shows the tqdm bar
            bufsize=1,
            text=True,
        )
        _active_proc = proc
        mode = "full rebuild" if force_rebuild else "incremental"
        print(
            f"[index] {mode} pid={proc.pid} running in background…",
            flush=True,
        )

    atexit.register(_terminate_active_build)

    def _watch() -> None:
        started = time.time()
        final_summary: dict | None = None
        assert proc.stdout is not None
        try:
            for raw_line in proc.stdout:
                line = raw_line.rstrip("\n")
                event = _parse_progress_line(line)
                if event is not None:
                    if on_progress is not None:
                        try:
                            on_progress(event["event"], event)
                        except Exception:
                            pass
                    continue
                if line.startswith("{") and line.endswith("}"):
                    try:
                        final_summary = json.loads(line)
                    except json.JSONDecodeError:
                        pass
                    continue
                print(line, flush=True)
        except Exception as exc:
            print(f"[index][warn] stdout watcher error: {exc}", flush=True)

        rc = proc.wait()
        duration = int(time.time() - started)
        ok = rc == 0
        if ok:
            print(
                f"[index] build complete in {duration}s — reopening handles.",
                flush=True,
            )
            try:
                reset_handle()
            except Exception as exc:
                print(f"[index][warn] handle reset failed: {exc}", flush=True)
        else:
            err = ""
            if isinstance(final_summary, dict):
                err = str(final_summary.get("error") or "")
            print(
                f"[index][warn] build exited with rc={rc} after {duration}s"
                + (f": {err}" if err else "")
                + " — see traceback on stderr above.",
                flush=True,
            )
        if on_complete is not None:
            try:
                on_complete(ok)
            except Exception:
                pass
        with _active_lock:
            global _active_proc
            if _active_proc is proc:
                _active_proc = None

    threading.Thread(target=_watch, daemon=True, name="index-build-watcher").start()


def _parse_progress_line(line: str) -> dict | None:
    """Decode a ``PROGRESS {...}`` line emitted by the build subprocess."""
    if not line.startswith("PROGRESS "):
        return None
    raw = line[len("PROGRESS ") :].strip()
    if not raw:
        return None
    try:
        data = json.loads(raw)
    except json.JSONDecodeError:
        return None
    if not isinstance(data, dict) or "event" not in data:
        return None
    return data


def _terminate_active_build() -> None:
    """Kill a still-running build when the parent process exits."""
    with _active_lock:
        proc = _active_proc
    if proc is None:
        return
    if proc.poll() is not None:
        return
    try:
        proc.send_signal(signal.SIGTERM)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            proc.kill()
    except Exception:
        pass


def parse_build_summary(stdout: bytes | str) -> dict | None:
    """Pull the final JSON line the build script emits (for callers that
    capture stdout instead of streaming it)."""
    if isinstance(stdout, bytes):
        stdout = stdout.decode("utf-8", errors="ignore")
    for line in reversed(stdout.strip().splitlines()):
        line = line.strip()
        if line.startswith("PROGRESS "):
            continue
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    return None
