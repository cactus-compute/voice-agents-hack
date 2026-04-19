"""Startup preflight checks for demo reliability."""

from __future__ import annotations

import importlib.util
import os
import shutil
from pathlib import Path

from config.resources import FILE_ALIASES
from config.settings import CHROME_PROFILE_PATH, GEMINI_API_KEY, VISION_ARTIFACT_DIR


def run_preflight_checks() -> None:
    """Validate key runtime prerequisites before starting the loop."""
    print("[preflight] running startup checks…", flush=True)
    errors: list[str] = []
    warnings: list[str] = []

    # Browser session profile path should be configured to a real directory.
    chrome_profile = Path(os.path.expanduser(CHROME_PROFILE_PATH))
    if not chrome_profile.exists():
        warnings.append(
            f"CHROME_PROFILE_PATH does not exist: {chrome_profile}. "
            "Browser automation may fail."
        )

    # Local file aliases should point at existing files for demo flows.
    for alias, raw_path in FILE_ALIASES.items():
        resolved = Path(os.path.expanduser(raw_path))
        if not resolved.exists():
            warnings.append(
                f"Alias '{alias}' points to missing file: {resolved}. "
                "Update config/resources.py."
            )

    # At least one STT backend is required.
    has_whisper = _module_available("faster_whisper")
    has_cactus = shutil.which("cactus") is not None
    if not (has_whisper or has_cactus):
        errors.append(
            "No STT backend found. Install faster-whisper or cactus CLI."
        )

    # Optional but recommended for non-rule intent handling.
    if not GEMINI_API_KEY and not has_cactus:
        warnings.append(
            "Neither GEMINI_API_KEY nor cactus intent fallback is available. "
            "Only rule-based intents will work."
        )

    artifact_dir = Path(os.path.expanduser(VISION_ARTIFACT_DIR))
    try:
        artifact_dir.mkdir(parents=True, exist_ok=True)
    except Exception as exc:
        errors.append(f"Unable to create VISION_ARTIFACT_DIR '{artifact_dir}': {exc}")

    if shutil.which("screencapture") is None:
        warnings.append(
            "screencapture command not found. Desktop observation snapshots may fail."
        )

    _print_diagnostics(errors, warnings)
    if errors:
        raise RuntimeError("Preflight failed. Resolve errors before running.")


def _module_available(module_name: str) -> bool:
    """Check whether `module_name` can be imported, WITHOUT actually importing it.

    We previously used `__import__(module_name)` which fully loads the module
    and its native deps. For `faster_whisper` that cascade alone cost 5-10s
    at startup (ctranslate2 + tokenizers + numpy), all of which the agent
    thread imports again later anyway. `find_spec` just looks up the module
    on sys.path and returns metadata — microseconds.
    """
    try:
        return importlib.util.find_spec(module_name) is not None
    except (ImportError, ValueError):
        return False


def _print_diagnostics(errors: list[str], warnings: list[str]) -> None:
    if not errors and not warnings:
        print("[preflight] all checks passed.", flush=True)
        return

    for warning in warnings:
        print(f"[preflight][warn] {warning}", flush=True)
    for error in errors:
        print(f"[preflight][error] {error}", flush=True)
