"""Typed contracts shared between Codex (detection/policy), Cursor (integration),
and Ona (UI/trace). These mirror the JSON shapes defined in AGENTS.md so all
three workstreams can build against stable interfaces in parallel.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Literal


class EntityType(str, Enum):
    SSN = "ssn"
    PHONE = "phone"
    EMAIL = "email"
    NAME = "name"
    ADDRESS = "address"
    INSURANCE_ID = "insurance_id"
    MRN = "mrn"
    DOB = "dob"
    HEALTH_CONTEXT = "health_context"
    OTHER = "other"


RiskLevel = Literal["none", "low", "medium", "high"]
Route = Literal["local-only", "masked-send", "safe-to-send"]
PolicyName = Literal[
    "hipaa_base",
    "hipaa_logging_strict",
    "hipaa_clinical_context",
]


@dataclass(frozen=True)
class Entity:
    """A single sensitive span detected in text."""

    type: EntityType
    value: str
    start: int = -1
    end: int = -1
    confidence: float = 1.0
    health_context: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "type": self.type.value,
            "value": self.value,
            "start": self.start,
            "end": self.end,
            "confidence": self.confidence,
            "health_context": self.health_context,
        }


@dataclass(frozen=True)
class DetectionResult:
    """Codex → Cursor / Ona. JSON shape from AGENTS.md:

        {"entities": [{"type": "ssn", "value": "..."}], "risk_level": "high"}
    """

    entities: list[Entity]
    risk_level: RiskLevel
    health_context: bool = False

    def to_dict(self) -> dict[str, Any]:
        return {
            "entities": [e.to_dict() for e in self.entities],
            "risk_level": self.risk_level,
            "health_context": self.health_context,
        }

    @property
    def has_sensitive(self) -> bool:
        return self.risk_level in ("medium", "high")


@dataclass(frozen=True)
class PolicyDecision:
    """Codex → Cursor. JSON shape from AGENTS.md:

        {"route": "masked-send", "policy": "hipaa_base"}
    """

    route: Route
    policy: PolicyName
    reasons: list[str] = field(default_factory=list)
    rationale: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "route": self.route,
            "policy": self.policy,
            "reasons": list(self.reasons),
            "rationale": self.rationale,
        }


@dataclass(frozen=True)
class MaskedText:
    """Codex → Cursor. The user-safe version of the text plus a token map
    so the original values can be restored on the way back out.
    """

    text: str
    token_map: dict[str, str] = field(default_factory=dict)
    replacements: list[dict[str, Any]] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "text": self.text,
            "token_map": dict(self.token_map),
            "replacements": list(self.replacements),
        }


TraceStage = Literal[
    "stt", "detection", "policy", "masking", "routing", "llm", "output_filter", "tts"
]


@dataclass(frozen=True)
class TraceEvent:
    """All → Ona. JSON shape from AGENTS.md:

        {"stage": "masking", "message": "Masked SSN"}
    """

    stage: TraceStage
    message: str
    elapsed_ms: float = 0.0
    payload: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "stage": self.stage,
            "message": self.message,
            "elapsed_ms": self.elapsed_ms,
            "payload": dict(self.payload),
        }


@dataclass
class TurnResult:
    """End-to-end output of a single voice turn. Returned by the voice loop
    and consumed by the trace UI / external integrations.
    """

    user_text: str
    detection: DetectionResult
    policy: PolicyDecision
    masked_input: MaskedText
    model_output: str
    safe_output: str
    trace: list[TraceEvent]
    total_ms: float

    def to_dict(self) -> dict[str, Any]:
        return {
            "user_text": self.user_text,
            "detection": self.detection.to_dict(),
            "policy": self.policy.to_dict(),
            "masked_input": self.masked_input.to_dict(),
            "model_output": self.model_output,
            "safe_output": self.safe_output,
            "trace": [t.to_dict() for t in self.trace],
            "total_ms": self.total_ms,
        }
