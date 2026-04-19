"""
Filesystem discovery for the disk index.

Walks the configured roots bounded by a deny-list and size cap, yielding
`(path, size, mtime)` tuples for the extractor. We prefer a direct walk over
shelling out to `mdfind` for the build pass because:

  * we need every readable file, not just Spotlight-indexed ones
  * walk gives us size + mtime in one syscall (st_ino cache)
  * we can skip deny-listed dirs without follow-up filtering
"""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator


# Directory basenames we never descend into.
_DENY_DIRS: frozenset[str] = frozenset(
    {
        # VCS / build caches
        ".git",
        ".hg",
        ".svn",
        "node_modules",
        "__pycache__",
        ".venv",
        "venv",
        ".tox",
        ".mypy_cache",
        ".pytest_cache",
        ".ruff_cache",
        ".next",
        ".nuxt",
        ".parcel-cache",
        "target",
        "dist",
        "build",
        # macOS & system junk
        ".Trash",
        ".Trashes",
        ".Spotlight-V100",
        ".DocumentRevisions-V100",
        ".fseventsd",
        ".TemporaryItems",
        ".MobileBackups",
        # Huge caches we don't want to index
        "Caches",
        "DerivedData",
        "CrashReporter",
    }
)

# Absolute path prefixes to skip outright.
_DENY_ABS_PREFIXES: tuple[str, ...] = (
    "/System",
    "/Library",
    "/private/var",
    "/private/tmp",
    "/usr",
    "/bin",
    "/sbin",
    "/opt/homebrew",
    "/cores",
    "/dev",
    "/Volumes/Recovery",
    "/Volumes/.timemachine",
    os.path.expanduser("~/Library"),
)

# File extensions we skip during discovery (saves an extract call).
_BINARY_EXTS: frozenset[str] = frozenset(
    {
        ".dmg",
        ".iso",
        ".pkg",
        ".ipa",
        ".apk",
        ".exe",
        ".dll",
        ".so",
        ".dylib",
        ".a",
        ".o",
        ".class",
        ".jar",
        ".war",
        ".zip",
        ".tar",
        ".tgz",
        ".gz",
        ".bz2",
        ".xz",
        ".7z",
        ".rar",
        ".mov",
        ".mp4",
        ".m4v",
        ".mkv",
        ".webm",
        ".avi",
        ".wmv",
        ".mpg",
        ".mpeg",
        ".mp3",
        ".m4a",
        ".wav",
        ".flac",
        ".aiff",
        ".ogg",
        ".heic",
        ".jpg",
        ".jpeg",
        ".png",
        ".gif",
        ".bmp",
        ".tif",
        ".tiff",
        ".webp",
        ".svgz",
        ".psd",
        ".ai",
        ".indd",
        ".raw",
        ".nef",
        ".orf",
        ".cr2",
        ".arw",
        ".sketch",
        ".fig",
        ".xcf",
        ".pyc",
        ".pyo",
        ".woff",
        ".woff2",
        ".ttf",
        ".otf",
        ".eot",
    }
)


@dataclass(frozen=True)
class Candidate:
    path: Path
    size: int
    mtime: float
    ext: str


def iter_candidates(
    roots: Iterable[Path],
    *,
    max_file_bytes: int,
) -> Iterator[Candidate]:
    """Yield files under `roots` that are plausible content-index candidates."""
    seen: set[str] = set()
    for raw_root in roots:
        try:
            root = raw_root.expanduser().resolve()
        except OSError:
            continue
        if not root.exists() or not root.is_dir():
            continue
        if _is_deny_abs(str(root)):
            continue
        for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
            # prune deny-listed children in-place so os.walk skips them
            dirnames[:] = [d for d in dirnames if not _skip_dir(dirpath, d)]

            for fname in filenames:
                if fname.startswith("."):
                    continue
                full = os.path.join(dirpath, fname)
                if full in seen:
                    continue
                seen.add(full)
                ext = os.path.splitext(fname)[1].lower()
                if ext in _BINARY_EXTS:
                    continue
                try:
                    st = os.stat(full, follow_symlinks=False)
                except OSError:
                    continue
                if not _is_regular_file(st):
                    continue
                if st.st_size > max_file_bytes:
                    continue
                yield Candidate(
                    path=Path(full),
                    size=int(st.st_size),
                    mtime=float(st.st_mtime),
                    ext=ext,
                )


def _skip_dir(parent: str, name: str) -> bool:
    if name.startswith(".") and name not in {".config", ".ssh"}:
        return True
    if name in _DENY_DIRS:
        return True
    full = os.path.join(parent, name)
    if _is_deny_abs(full):
        return True
    # Skip macOS bundles (e.g. .app, .pkg, .framework) - they're opaque to us.
    if name.endswith((".app", ".framework", ".bundle", ".plugin", ".kext")):
        return True
    return False


def _is_deny_abs(path: str) -> bool:
    for pref in _DENY_ABS_PREFIXES:
        if path == pref or path.startswith(pref + "/"):
            return True
    return False


def _is_regular_file(st: os.stat_result) -> bool:
    import stat as _stat

    return _stat.S_ISREG(st.st_mode)
