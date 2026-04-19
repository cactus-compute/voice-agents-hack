"""Typed contracts shared between Codex (detection/policy), Cursor (integration),
and Ona (UI/trace). These mirror the JSON shapes defined in AGENTS.md so all
three workstreams can build against stable interfaces in parallel.
"""

from __future__ import annotations

import hashlib
import json
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
PolicyName = Literal["hipaa_base", "hipaa_logging", "hipaa_clinical"]


@dataclass(frozen=True)
class Entity:
    """A single sensitive span detected in text."""

    type: EntityType
    value: str
    start: int = -1
    end: int = -1
    confidence: float = 1.0

    def to_dict(self) -> dict[str, Any]:
        return {
            "type": self.type.value,
            "value": self.value,
            "start": self.start,
            "end": self.end,
            "confidence": self.confidence,
        }


@dataclass(frozen=True)
class DetectionResult:
    """Codex → Cursor / Ona. JSON shape from AGENTS.md:

        {"entities": [{"type": "ssn", "value": "..."}], "risk_level": "high"}
    """

    entities: list[Entity]
    risk_level: RiskLevel

    def to_dict(self) -> dict[str, Any]:
        return {
            "entities": [e.to_dict() for e in self.entities],
            "risk_level": self.risk_level,
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
    rationale: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {"route": self.route, "policy": self.policy, "rationale": self.rationale}


@dataclass(frozen=True)
class MaskedText:
    """Codex → Cursor. The user-safe version of the text plus a token map
    so the original values can be restored on the way back out.
    """

    text: str
    token_map: dict[str, str] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {"text": self.text, "token_map": dict(self.token_map)}


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


GENESIS_HASH = "GENESIS"


@dataclass(frozen=True)
class AuditEntry:
    """One hash-chained row in the compliance evidence trail. Append-only.

    Each row's `entry_hash` is a SHA-256 over the canonical JSON of every
    other field (including `prev_hash`). The next row's `prev_hash` MUST
    equal this row's `entry_hash`, forming a tamper-evident chain a la git
    commits or AWS CloudTrail.

    INVARIANT — the `payload` field MUST NOT contain raw PHI. Store entity
    types, span indices, and lengths only. Raw values stay in the in-memory
    `MaskedText.token_map` and are never written to disk.
    """

    ts: str                       # ISO-8601 UTC, microsecond precision
    surface: str                  # "veil" | "aurora" | "aurora-laptop" | "cli"
    stage: TraceStage
    message: str                  # human-readable XAI explanation
    elapsed_ms: float
    decision: Route | None
    policy: PolicyName | None
    regulation: str               # "hipaa" at MVP; "pci" / "glba" later
    controls: list[str]           # ["164.312(a)(1)", "164.312(b)", ...]
    payload: dict[str, Any]       # span types/indices/lengths only — NEVER raw PHI
    prev_hash: str                # hex digest of previous row, or GENESIS_HASH
    entry_hash: str               # hex digest of this row's canonical body

    def to_dict(self) -> dict[str, Any]:
        return {
            "ts": self.ts,
            "surface": self.surface,
            "stage": self.stage,
            "message": self.message,
            "elapsed_ms": self.elapsed_ms,
            "decision": self.decision,
            "policy": self.policy,
            "regulation": self.regulation,
            "controls": list(self.controls),
            "payload": dict(self.payload),
            "prev_hash": self.prev_hash,
            "entry_hash": self.entry_hash,
        }

    def to_jsonl(self) -> str:
        """One-line JSON suitable for appending to `audit.jsonl`."""
        return json.dumps(self.to_dict(), separators=(",", ":"), sort_keys=True)


def canonical_json(payload: dict[str, Any]) -> str:
    """Deterministic serialization used for hashing.

    Stdlib only. Sorted keys, no whitespace, UTF-8. Sufficient for the demo;
    full RFC 8785 (JCS) canonicalization is post-MVP.
    """
    return json.dumps(payload, separators=(",", ":"), sort_keys=True, ensure_ascii=False)


def compute_entry_hash(body_without_hash: dict[str, Any]) -> str:
    """SHA-256 hex digest of an AuditEntry's canonical JSON sans `entry_hash`."""
    serialized = canonical_json(body_without_hash).encode("utf-8")
    return hashlib.sha256(serialized).hexdigest()


@dataclass(frozen=True)
class ChainVerification:
    """Result of `Tracer.verify_chain(path)`. Used by the `python -m masker
    verify` CLI to power the demo's tamper-test moment.
    """

    valid: bool
    total_entries: int
    broken_at_line: int | None = None      # 1-indexed line number of first failure
    expected_hash: str | None = None       # what the row claims its entry_hash is
    computed_hash: str | None = None       # what we recompute it to be
    reason: str = ""                       # human-readable failure reason

    def to_dict(self) -> dict[str, Any]:
        return {
            "valid": self.valid,
            "total_entries": self.total_entries,
            "broken_at_line": self.broken_at_line,
            "expected_hash": self.expected_hash,
            "computed_hash": self.computed_hash,
            "reason": self.reason,
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
