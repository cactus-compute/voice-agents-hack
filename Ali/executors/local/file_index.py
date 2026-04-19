"""
Layer 4A — Local Executor: File index helpers.

Safe wrappers around macOS Spotlight (`mdfind`) and a bounded filesystem walk
for the Cactus-driven file resolver. No shell interpolation, allowlisted roots
only, strict predicate validation.
"""

from __future__ import annotations

import asyncio
import os
import shutil
from pathlib import Path

_MAX_PREDICATE_LEN = 400

_PREDICATE_BAD_SUBSTRINGS = (";", "`", "$(", "&&", "||", "\n", "\r")

_WALK_SKIP_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".Trash",
    ".Trashes",
    "node_modules",
    "Library",
    ".cache",
    ".venv",
    "venv",
    "__pycache__",
    ".DS_Store",
}


def validate_predicate(predicate: str) -> str | None:
    """Return a normalized predicate string if safe, else None."""
    if not isinstance(predicate, str):
        return None
    p = predicate.strip()
    if not p:
        return None
    if len(p) > _MAX_PREDICATE_LEN:
        return None
    for bad in _PREDICATE_BAD_SUBSTRINGS:
        if bad in p:
            return None
    return p


async def run_mdfind(predicate: str, only_in: Path, limit: int) -> list[Path]:
    """Run `mdfind -onlyin <only_in> -0 <predicate>` and return bounded results."""
    mdfind_bin = shutil.which("mdfind")
    if not mdfind_bin:
        return []

    try:
        only_in_resolved = only_in.expanduser().resolve()
    except OSError:
        return []
    if not only_in_resolved.exists() or not only_in_resolved.is_dir():
        return []

    safe_predicate = validate_predicate(predicate)
    if safe_predicate is None:
        return []

    try:
        proc = await asyncio.create_subprocess_exec(
            mdfind_bin,
            "-onlyin",
            str(only_in_resolved),
            "-0",
            safe_predicate,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _stderr = await proc.communicate()
    except (OSError, asyncio.CancelledError):
        return []

    if proc.returncode != 0:
        return []

    results: list[Path] = []
    for chunk in stdout.split(b"\x00"):
        if not chunk:
            continue
        try:
            candidate = Path(os.fsdecode(chunk))
        except (UnicodeDecodeError, ValueError):
            continue
        if not _is_under(candidate, only_in_resolved):
            continue
        if not candidate.is_file():
            continue
        results.append(candidate)
        if len(results) >= limit:
            break
    return results


def bounded_walk(roots: list[Path], limit: int, max_depth: int) -> list[Path]:
    """Depth- and count-bounded walk across `roots`."""
    collected: list[Path] = []
    if limit <= 0:
        return collected

    for root in roots:
        try:
            root_resolved = root.expanduser().resolve()
        except OSError:
            continue
        if not root_resolved.exists() or not root_resolved.is_dir():
            continue

        base_depth = len(root_resolved.parts)
        for dirpath, dirnames, filenames in os.walk(root_resolved, followlinks=False):
            current = Path(dirpath)
            depth = len(current.parts) - base_depth
            if depth >= max_depth:
                dirnames[:] = []
            else:
                dirnames[:] = [d for d in dirnames if not _should_skip_dir(d)]

            for name in filenames:
                if name.startswith("."):
                    continue
                candidate = current / name
                if not _is_under(candidate, root_resolved):
                    continue
                try:
                    if not candidate.is_file():
                        continue
                except OSError:
                    continue
                collected.append(candidate)
                if len(collected) >= limit:
                    return collected
    return collected


def _should_skip_dir(name: str) -> bool:
    if name in _WALK_SKIP_DIRS:
        return True
    if name.startswith("."):
        return True
    return False


def _is_under(path: Path, root: Path) -> bool:
    try:
        resolved = path.resolve()
    except OSError:
        return False
    try:
        return resolved.is_relative_to(root)
    except AttributeError:
        try:
            resolved.relative_to(root)
            return True
        except ValueError:
            return False
