#!/usr/bin/env python3
"""Fast smoke test for YC Voice Agent wiring.

This script avoids hard-failing on optional demo dependencies (like pyaudio)
and instead reports what is missing so setup can be completed quickly.
"""

from __future__ import annotations

import ast
import importlib
import sys
import time
from pathlib import Path


def check_import(path: str, required: bool = True) -> bool:
    try:
        importlib.import_module(path)
        print(f"[ok] import {path}")
        return True
    except Exception as exc:  # pragma: no cover - smoke script behavior
        level = "error" if required else "warn"
        print(f"[{level}] import {path}: {exc}")
        if required:
            raise
        return False


def check_syntax(path: Path) -> None:
    source = path.read_text(encoding="utf-8")
    ast.parse(source, filename=str(path))
    print(f"[ok] syntax {path.relative_to(path.parents[1])}")


def check_plan() -> None:
    from intent.schema import KnownGoal
    from orchestrator.plans import get_plan

    required = [
        KnownGoal.APPLY_TO_JOB,
        KnownGoal.SEND_MESSAGE,
        KnownGoal.SEND_EMAIL,
        KnownGoal.ADD_CALENDAR_EVENT,
    ]
    for goal in required:
        steps = get_plan(goal)
        if not steps:
            raise AssertionError(f"Missing plan for {goal.value}")
        print(f"[ok] plan {goal.value}: {len(steps)} steps")


def check_resources() -> None:
    from config.resources import FILE_ALIASES

    if "resume" not in FILE_ALIASES:
        raise AssertionError("FILE_ALIASES missing 'resume'")
    print("[ok] file alias 'resume' configured")


def main() -> int:
    started = time.perf_counter()
    root = Path(__file__).resolve().parents[1]
    if str(root) not in sys.path:
        sys.path.insert(0, str(root))

    required_modules = [
        "intent.schema",
        "orchestrator.plans",
        "orchestrator.state",
        "config.resources",
    ]
    optional_modules = [
        "main",
        "voice.capture",
        "voice.transcribe",
        "intent.parser",
        "orchestrator.orchestrator",
        "executors.local.applescript",
        "executors.browser.browser",
        "ui.confirmation",
    ]
    for module in required_modules:
        check_import(module, required=True)
    for module in optional_modules:
        check_import(module, required=False)

    syntax_targets = [
        root / "main.py",
        root / "voice" / "capture.py",
        root / "voice" / "transcribe.py",
        root / "intent" / "parser.py",
        root / "orchestrator" / "orchestrator.py",
    ]
    for path in syntax_targets:
        check_syntax(path)

    check_plan()
    check_resources()
    elapsed = time.perf_counter() - started
    print(f"[smoke] PASS in {elapsed:.2f}s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
