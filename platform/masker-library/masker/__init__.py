"""Masker — on-device privacy layer for Cactus + Gemma voice agents.

Public API surface (deliberately tiny — see MASKER_README.md):

  - filter_input(text)   -> (safe_text, metadata)
  - filter_output(text)  -> safe_text
  - auto_attach()        -> monkey-patches google-genai for drop-in privacy
  - VoiceLoop / default_loop()  -> end-to-end orchestration

Anything else is implementation detail and may move between releases.
"""

from __future__ import annotations

from typing import Any

from . import _native
from .contracts import (
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
    auto_attach,
    default_backend,
)
from .router import Router, default_router
from .trace import Tracer
from .voice_loop import VoiceLoop, default_loop


def filter_input(text: str, *, policy_name: PolicyName = "hipaa_base") -> tuple[str, dict[str, Any]]:
    """Run detection + policy + masking on `text` and return the LLM-safe
    version plus a metadata dict (route, entities, token_map). The most
    common integration point for other teams.
    """
    native = _native.try_filter_input(text, policy_name=policy_name)
    if native is not None:
        return native.masked_input.text, _metadata_dict(
            native.masked_input, native.policy, native.detection
        )

    from . import detection as _detection
    from . import masking as _masking
    from . import policy as _policy

    det = _detection.detect(text)
    decision = _policy.decide(det, policy_name=policy_name)
    masked = _masking.mask(text, det)
    return masked.text, _metadata_dict(masked, decision, det)


def filter_output(text: str) -> str:
    """Re-scan a model's response and re-mask any sensitive spans the model
    happened to echo or hallucinate. Conservative by design — false positives
    are preferable to leaks.
    """
    native = _native.try_filter_output(text)
    if native is not None:
        return native.safe_text

    from . import detection as _detection
    from . import masking as _masking

    det = _detection.detect(text)
    return _masking.scrub_output(text, det)


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
    "CactusCloudBackend",
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
