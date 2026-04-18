"""Single-entry privacy pipeline for transcript text.

Codex owns this helper so integration layers can call one function and receive:
  detection result + policy decision + masked transcript + timing metadata
"""

from __future__ import annotations

import time
from dataclasses import dataclass

from . import detection as _detection
from . import masking as _masking
from . import policy as _policy
from .contracts import DetectionResult, MaskedText, PolicyDecision, PolicyName


@dataclass(frozen=True)
class PrivacyTimings:
    detection_ms: float
    policy_ms: float
    masking_ms: float

    def to_dict(self) -> dict[str, float]:
        return {
            "detection_ms": self.detection_ms,
            "policy_ms": self.policy_ms,
            "masking_ms": self.masking_ms,
            "total_ms": self.detection_ms + self.policy_ms + self.masking_ms,
        }


@dataclass(frozen=True)
class PrivacyPipelineResult:
    detection: DetectionResult
    policy: PolicyDecision
    masked: MaskedText
    timings: PrivacyTimings

    def to_dict(self) -> dict[str, object]:
        return {
            "detection": self.detection.to_dict(),
            "policy": self.policy.to_dict(),
            "masked": self.masked.to_dict(),
            "timings": self.timings.to_dict(),
        }


def analyze_transcript(
    text: str,
    *,
    policy_name: PolicyName = "hipaa_base",
    mask_mode: _masking.MaskMode = "placeholder",
) -> PrivacyPipelineResult:
    detection_started = time.perf_counter()
    detection = _detection.detect(text)
    detection_ms = (time.perf_counter() - detection_started) * 1000.0

    policy_started = time.perf_counter()
    decision = _policy.decide(detection, policy_name=policy_name)
    policy_ms = (time.perf_counter() - policy_started) * 1000.0

    masking_started = time.perf_counter()
    masked = _masking.mask(text, detection, mode=mask_mode)
    masking_ms = (time.perf_counter() - masking_started) * 1000.0

    return PrivacyPipelineResult(
        detection=detection,
        policy=decision,
        masked=masked,
        timings=PrivacyTimings(
            detection_ms=detection_ms,
            policy_ms=policy_ms,
            masking_ms=masking_ms,
        ),
    )
