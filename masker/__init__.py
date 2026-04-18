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
    GemmaBackend,
    GeminiCloudBackend,
    LocalCactusBackend,
    StubBackend,
    auto_attach,
    default_backend,
)
from .privacy import PrivacyPipelineResult, PrivacyTimings, analyze_transcript
from .router import Router, default_router
from .trace import Tracer
from .voice_loop import VoiceLoop, default_loop


def filter_input(text: str, *, policy_name: PolicyName = "hipaa_base") -> tuple[str, dict[str, Any]]:
    """Run detection + policy + masking on `text` and return the LLM-safe
    version plus a metadata dict (route, entities, token_map). The most
    common integration point for other teams.
    """
    result = analyze_transcript(text, policy_name=policy_name)
    det = result.detection
    decision = result.policy
    masked = result.masked
    return masked.text, {
        "route": decision.route,
        "policy": decision.policy,
        "reasons": list(decision.reasons),
        "rationale": decision.rationale,
        "entities": [e.to_dict() for e in det.entities],
        "risk_level": det.risk_level,
        "health_context": det.health_context,
        "token_map": masked.token_map,
        "replacements": masked.replacements,
        "timings": result.timings.to_dict(),
    }


def filter_output(text: str) -> str:
    """Re-scan a model's response and re-mask any sensitive spans the model
    happened to echo or hallucinate. Conservative by design — false positives
    are preferable to leaks.
    """
    from . import detection as _detection
    from . import masking as _masking

    det = _detection.detect(text)
    return _masking.scrub_output(text, det)


__all__ = [
    "DetectionResult",
    "Entity",
    "EntityType",
    "GemmaBackend",
    "GeminiCloudBackend",
    "LocalCactusBackend",
    "MaskedText",
    "PolicyDecision",
    "PolicyName",
    "PrivacyPipelineResult",
    "PrivacyTimings",
    "Route",
    "Router",
    "StubBackend",
    "TraceEvent",
    "Tracer",
    "TurnResult",
    "VoiceLoop",
    "auto_attach",
    "analyze_transcript",
    "default_backend",
    "default_loop",
    "default_router",
    "filter_input",
    "filter_output",
]
