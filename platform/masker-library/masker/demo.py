"""Demo runner — `python -m masker.demo`.

Walks through the four scenarios from docs/wiki/BACKLOG.md and prints the
trace of each turn. Uses the StubBackend by default so the demo runs in
< 100ms with no model / no network — ideal for CI and screen-recordings.
Pass `--backend cactus` once Cactus + functiongemma are wired, or
`--backend gemini` once GEMINI_API_KEY is set.
"""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import dataclass

from .gemma_wrapper import (
    GeminiCloudBackend,
    LocalCactusBackend,
    StubBackend,
    default_backend,
)
from .router import Router
from .trace import Tracer
from .voice_loop import VoiceLoop


@dataclass
class Scenario:
    label: str
    text: str
    expected_route: str


SCENARIOS: list[Scenario] = [
    Scenario(
        label="A — Personal info",
        text="Text Sarah my address is 4821 Mission Street, my number is 415-555-0123.",
        expected_route="masked-send",
    ),
    Scenario(
        label="B — Healthcare",
        text="I have chest pain and my insurance ID is BCBS-887421, MRN 99812.",
        expected_route="local-only",
    ),
    Scenario(
        label="C — Safe query",
        text="What's the weather tomorrow?",
        expected_route="safe-to-send",
    ),
    Scenario(
        label="D — Work context",
        text="Summarize the Apollo escalation for the Redwood account, contact priya@redwood.com.",
        expected_route="masked-send",
    ),
]


def _backend_from_arg(name: str):
    if name == "stub":
        return StubBackend()
    if name == "cactus":
        return LocalCactusBackend()
    if name == "gemini":
        return GeminiCloudBackend()
    if name == "auto":
        return default_backend()
    raise SystemExit(f"unknown backend: {name}")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Run the four BACKLOG scenarios end-to-end.")
    p.add_argument("--backend", choices=["stub", "cactus", "gemini", "auto"], default="stub")
    p.add_argument("--policy", choices=["hipaa_base", "hipaa_logging", "hipaa_clinical"], default="hipaa_base")
    p.add_argument("--json", action="store_true", help="emit machine-readable JSONL")
    p.add_argument("--scenario", help="run only the scenario whose label contains this string")
    args = p.parse_args(argv)

    backend = _backend_from_arg(args.backend)
    loop = VoiceLoop(router=Router(local_backend=backend), policy_name=args.policy)

    scenarios = SCENARIOS
    if args.scenario:
        needle = args.scenario.lower()
        scenarios = [s for s in scenarios if needle in s.label.lower()]
        if not scenarios:
            print(f"no scenario matched {args.scenario!r}", file=sys.stderr)
            return 2

    failures = 0
    for s in scenarios:
        tracer = Tracer()
        result = loop.run_text_turn(s.text, tracer=tracer)

        if args.json:
            print(json.dumps({"scenario": s.label, "expected": s.expected_route, "result": result.to_dict()}))
            continue

        ok = "OK" if result.policy.route == s.expected_route else "MISMATCH"
        if ok == "MISMATCH":
            failures += 1
        bar = "─" * 78
        print(f"\n{bar}\n[{ok}] {s.label}")
        print(f"  user      : {s.text}")
        print(f"  detected  : {[e.type.value for e in result.detection.entities]} (risk={result.detection.risk_level})")
        print(f"  policy    : {result.policy.route}  (expected={s.expected_route})")
        print(f"  rationale : {result.policy.rationale}")
        print(f"  masked    : {result.masked_input.text}")
        print(f"  → model   : {result.model_output[:160]}")
        print(f"  ← safe    : {result.safe_output[:160]}")
        print(f"  total     : {result.total_ms:.1f} ms")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
