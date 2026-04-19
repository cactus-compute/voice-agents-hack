"""Masker — on-device privacy layer for Cactus + Gemma voice agents.

Public API surface (deliberately tiny — see MASKER_README.md):

  - filter_input(text)   -> (safe_text, metadata)
  - filter_output(text)  -> safe_text
  - auto_attach()        -> monkey-patches google-genai for drop-in privacy
                            with optional hash-chained HIPAA audit trail
  - Tracer.verify_chain(path) -> ChainVerification
  - VoiceLoop / default_loop()  -> end-to-end orchestration

Anything else is implementation detail and may move between releases.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any, Callable

from . import _native
from .contracts import (
    AuditEntry,
    ChainVerification,
    DetectionResult,
    Entity,
    EntityType,
    MaskedText,
    PolicyDecision,
    PolicyName,
    Route,
    TraceEvent,
    TurnResult,
)
from .gemma_wrapper import (
    CactusCloudBackend,
    GemmaBackend,
    GeminiCloudBackend,
    LocalCactusBackend,
    StubBackend,
    default_backend,
)
from .gemma_wrapper import auto_attach as _attach_genai
from .router import Router, default_router
from .trace import Tracer
from .voice_loop import VoiceLoop, default_loop


# ---------------------------------------------------------------------------
# Global compliance tracer
# ---------------------------------------------------------------------------
# `auto_attach()` configures this; `filter_input()` / `filter_output()` write
# evidence rows to it whenever it's set. Module-level state is fine here —
# Masker is configured once per process at app startup, just like a logging
# handler.

_GLOBAL_TRACER: Tracer | None = None
_GLOBAL_POLICY: PolicyName = "hipaa_base"


def _global_tracer() -> Tracer | None:
    return _GLOBAL_TRACER


def _set_global_tracer(tracer: Tracer | None, *, policy: PolicyName = "hipaa_base") -> None:
    """Test hook + auto_attach() implementation detail. Not public API."""
    global _GLOBAL_TRACER, _GLOBAL_POLICY
    _GLOBAL_TRACER = tracer
    _GLOBAL_POLICY = policy


# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------


def filter_input(text: str, *, policy_name: PolicyName | None = None) -> tuple[str, dict[str, Any]]:
    """Run detection + policy + masking on `text` and return the LLM-safe
    version plus a metadata dict (route, entities, token_map). The most
    common integration point for other teams.

    If a global compliance tracer is configured (via `auto_attach(audit_path=...)`)
    this also appends a hash-chained `AuditEntry` to the audit log capturing
    the routing decision, the HIPAA controls satisfied, and span metadata
    (NEVER raw values — token_map stays in process memory only).
    """
    effective_policy: PolicyName = policy_name or _GLOBAL_POLICY

    native = _native.try_filter_input(text, policy_name=effective_policy)
    if native is not None:
        masked = native.masked_input
        decision = native.policy
        detection = native.detection
    else:
        from . import detection as _detection
        from . import masking as _masking
        from . import policy as _policy

        detection = _detection.detect(text)
        decision = _policy.decide(detection, policy_name=effective_policy)
        masked = _masking.mask(text, detection)

    _maybe_record_evidence(masked, decision, detection, stage="policy")

    return masked.text, _metadata_dict(masked, decision, detection)


def filter_output(text: str) -> str:
    """Re-scan a model's response and re-mask any sensitive spans the model
    happened to echo or hallucinate. Conservative by design — false positives
    are preferable to leaks.
    """
    native = _native.try_filter_output(text)
    if native is not None:
        safe = native.safe_text
        det = None
    else:
        from . import detection as _detection
        from . import masking as _masking

        det = _detection.detect(text)
        safe = _masking.scrub_output(text, det)

    _maybe_record_output_evidence(text, safe, det)
    return safe


def auto_attach(
    *,
    backend: GemmaBackend | None = None,
    on_filter: Callable[[str, str], None] | None = None,
    policy: PolicyName = "hipaa_base",
    retention: str = "zero",
    audit_path: str | Path | None = None,
    surface: str = "aurora-laptop",
) -> None:
    """Drop-in privacy + compliance layer for any google-genai caller.

    Existing behavior (monkey-patches `google.genai.Client.models.generate_content`
    so prompts/responses route through `filter_input` / `filter_output`)
    is preserved. New keyword-only params turn on the **HIPAA evidence trail**:

        from masker import auto_attach
        auto_attach(
            policy="hipaa_base",
            retention="zero",
            audit_path="audit.jsonl",
            surface="aurora-laptop",
        )

    Parameters
    ----------
    policy
        Policy name forwarded to the policy engine for every filtered turn.
    retention
        Currently only `"zero"` is supported. Documents the intent: raw
        values live in `MaskedText.token_map` (process memory only) and are
        never written to disk. Audit log payloads carry types/indices/lengths
        only. Future values: `"30d"`, `"90d"` etc. with hashed-PHI vault.
    audit_path
        Where to append the hash-chained audit log. If `None`, no audit
        trail is written (backwards-compatible with the existing demo).
    surface
        Caller identity recorded on every audit row. Useful when multiple
        deployments (veil app, aurora laptop, CLI tests) write to the same
        evidence pipeline.
    """
    if retention not in {"zero"}:
        raise ValueError(
            f"retention={retention!r} not supported in MVP. Use retention='zero'."
        )

    tracer: Tracer | None = None
    if audit_path is not None:
        tracer = Tracer(
            audit_path=audit_path,
            surface=surface,
            regulation="hipaa",
            policy=policy,
        )
    _set_global_tracer(tracer, policy=policy)

    # Monkey-patch google-genai so any caller's existing client picks up
    # filter_input / filter_output transparently. Skip if google-genai
    # isn't installed — the audit trail still works for direct
    # filter_input() callers.
    try:
        _attach_genai(backend=backend, on_filter=on_filter)
    except RuntimeError:
        # google-genai not installed; that's fine for CLI / library usage.
        pass


# ---------------------------------------------------------------------------
# Private — evidence recording
# ---------------------------------------------------------------------------


def _maybe_record_evidence(
    masked: MaskedText,
    decision: PolicyDecision,
    detection: DetectionResult,
    *,
    stage: str,
) -> None:
    """Write one hash-chained AuditEntry summarizing this filter_input call."""
    tracer = _GLOBAL_TRACER
    if tracer is None:
        return

    from .policy import hipaa_controls  # local import to avoid cycle

    spans = [[e.start, e.end] for e in detection.entities]
    types = sorted({e.type.value for e in detection.entities})
    payload = {
        "entity_types": types,
        "spans": spans,
        "input_length": len(masked.text),
        "risk_level": detection.risk_level,
        "rationale": decision.rationale,
    }
    tracer.evidence(
        stage="policy",
        message=f"filter_input → route={decision.route}",
        decision=decision.route,
        controls=hipaa_controls(decision),
        payload=payload,
    )


def _maybe_record_output_evidence(
    raw: str,
    safe: str,
    detection: DetectionResult | None,
) -> None:
    tracer = _GLOBAL_TRACER
    if tracer is None:
        return

    types: list[str] = []
    if detection is not None:
        types = sorted({e.type.value for e in detection.entities})

    payload = {
        "entity_types": types,
        "raw_length": len(raw),
        "safe_length": len(safe),
        "rewrote": raw != safe,
    }
    tracer.evidence(
        stage="output_filter",
        message="filter_output rescan complete",
        decision=None,
        controls=["164.312(b)"],  # audit controls for the rescan itself
        payload=payload,
    )


def _metadata_dict(
    masked: MaskedText,
    decision: PolicyDecision,
    detection: DetectionResult,
) -> dict[str, Any]:
    return {
        "route": decision.route,
        "policy": decision.policy,
        "rationale": decision.rationale,
        "entities": [entity.to_dict() for entity in detection.entities],
        "risk_level": detection.risk_level,
        "token_map": masked.token_map,
    }


__all__ = [
    "AuditEntry",
    "CactusCloudBackend",
    "ChainVerification",
    "DetectionResult",
    "Entity",
    "EntityType",
    "GemmaBackend",
    "GeminiCloudBackend",
    "LocalCactusBackend",
    "MaskedText",
    "PolicyDecision",
    "PolicyName",
    "Route",
    "Router",
    "StubBackend",
    "TraceEvent",
    "Tracer",
    "TurnResult",
    "VoiceLoop",
    "auto_attach",
    "default_backend",
    "default_loop",
    "default_router",
    "filter_input",
    "filter_output",
]
