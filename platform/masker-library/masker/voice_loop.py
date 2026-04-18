"""End-to-end voice / text loop. CURSOR OWNS THIS FILE.

Orchestrates: input → STT → detection → policy → masking → routing → output filter.
Returns a TurnResult that Ona's UI consumes for the trace view.

Two entry surfaces:

  - `run_text_turn(text)`   — headless, used by tests and the demo CLI
  - `run_voice_turn()`      — mic in / TTS out, calls into `cactus transcribe`
                              under the hood (Phase-1 uses scripted text fallback)
"""

from __future__ import annotations

import shutil
import subprocess
import time
from dataclasses import dataclass

from . import _native
from .contracts import PolicyName, TurnResult
from . import detection as _detection
from . import masking as _masking
from . import policy as _policy
from .router import Router, default_router
from .trace import Tracer


@dataclass
class VoiceLoop:
    router: Router
    policy_name: PolicyName = "hipaa_base"
    mask_mode: str = "placeholder"

    def run_text_turn(self, text: str, tracer: Tracer | None = None) -> TurnResult:
        tracer = tracer or Tracer()
        t0 = time.perf_counter()

        native = _native.try_filter_input(
            text,
            policy_name=self.policy_name,
            mask_mode=self.mask_mode,
        )
        if native is not None:
            det = native.detection
            decision = native.policy
            masked = native.masked_input
            _record_trace_events(tracer, native.trace)
        else:
            with tracer.span("detection", "Scanning input for PII/PHI"):
                det = _detection.detect(text)
            tracer.event(
                "detection",
                f"risk={det.risk_level}, entities={len(det.entities)}",
                risk=det.risk_level,
                entity_types=[e.type.value for e in det.entities],
            )

            with tracer.span("policy", f"Applying {self.policy_name}"):
                decision = _policy.decide(det, policy_name=self.policy_name)
            tracer.event("policy", f"route={decision.route}", **decision.to_dict())

            with tracer.span("masking", "Masking sensitive spans"):
                masked = _masking.mask(text, det, mode=self.mask_mode)  # type: ignore[arg-type]
            if masked.token_map:
                tracer.event(
                    "masking",
                    f"masked {len(masked.token_map)} span(s)",
                    masked_count=len(masked.token_map),
                )

        model_text = self.router.execute(
            original_text=text,
            masked=masked,
            decision=decision,
            tracer=tracer,
        )

        native_output = _native.try_filter_output(model_text, detection=det)
        if native_output is not None:
            safe_out = native_output.safe_text
            _record_trace_events(tracer, native_output.trace)
        else:
            with tracer.span("output_filter", "Re-scanning model output for leakage"):
                safe_out = _masking.scrub_output(model_text, det)
            if safe_out != model_text:
                tracer.event("output_filter", "scrubbed leaked entity from output")

        total_ms = (time.perf_counter() - t0) * 1000.0
        return TurnResult(
            user_text=text,
            detection=det,
            policy=decision,
            masked_input=masked,
            model_output=model_text,
            safe_output=safe_out,
            trace=list(tracer.events),
            total_ms=total_ms,
        )

    def run_voice_turn(self, *, audio_file: str | None = None, tracer: Tracer | None = None) -> TurnResult:
        """Voice-in variant. Uses `cactus transcribe` to convert audio → text.
        Falls back to `input()` prompt if no `cactus` CLI is available so dev
        loops still work without a mic / model.
        """
        tracer = tracer or Tracer()
        with tracer.span("stt", "Transcribing audio"):
            text = _transcribe(audio_file)
        if not text:
            text = input("masker> ").strip()
        return self.run_text_turn(text, tracer=tracer)


def _transcribe(audio_file: str | None) -> str:
    if not shutil.which("cactus"):
        return ""
    cmd = ["cactus", "transcribe"]
    if audio_file:
        cmd += ["--file", audio_file]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
    except subprocess.TimeoutExpired:
        return ""
    if proc.returncode != 0:
        return ""
    return proc.stdout.strip()


def default_loop(*, policy_name: PolicyName = "hipaa_base") -> VoiceLoop:
    return VoiceLoop(router=default_router(), policy_name=policy_name)


def _record_trace_events(tracer: Tracer, events: list) -> None:
    for event in events:
        tracer._record(event)  # type: ignore[attr-defined]
