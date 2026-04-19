"""`python -m masker` — small CLI surface for the demo.

Currently supports a single sub-command:

    python -m masker verify <audit.jsonl>

Recomputes every entry hash and walks the prev_hash chain. Exit code 0 iff
the chain is intact; non-zero (with a structured JSON report on stdout) if
any row was tampered with, reordered, or deleted. This is the artifact we
wave around at auditors.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

from .trace import Tracer


def _verify(args: list[str]) -> int:
    if not args:
        print("usage: python -m masker verify <audit.jsonl>", file=sys.stderr)
        return 2

    path = Path(args[0])
    if not path.exists():
        print(json.dumps({"valid": False, "reason": f"file not found: {path}"}))
        return 1

    result = Tracer.verify_chain(path)
    payload = result.to_dict()

    if result.valid:
        print(
            f"\u2713 chain valid \u2014 {result.total_entries} entries, "
            f"{path.stat().st_size} bytes"
        )
        print(json.dumps(payload, indent=2))
        return 0

    print("\u2717 chain BROKEN", file=sys.stderr)
    print(json.dumps(payload, indent=2), file=sys.stderr)
    return 1


def main(argv: list[str] | None = None) -> int:
    argv = list(sys.argv[1:] if argv is None else argv)
    if not argv:
        print("usage: python -m masker <verify> ...", file=sys.stderr)
        return 2

    cmd, *rest = argv
    if cmd == "verify":
        return _verify(rest)

    print(f"unknown command: {cmd}", file=sys.stderr)
    print("usage: python -m masker verify <audit.jsonl>", file=sys.stderr)
    return 2


if __name__ == "__main__":
    raise SystemExit(main())
