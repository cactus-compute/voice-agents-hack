"""Sensitive-content detection. CODEX OWNS THIS FILE.

This file currently ships a regex-only baseline so the Cursor integration
layer can run end-to-end before Codex's real Gemma-based classifier lands.
Replace the body of `detect()` — keep the signature stable.

Contract (see AGENTS.md):
    detect(text: str) -> DetectionResult
"""

from __future__ import annotations

import re
from typing import Pattern

from .contracts import DetectionResult, Entity, EntityType, RiskLevel

_PATTERNS: list[tuple[EntityType, Pattern[str], float]] = [
    (EntityType.SSN, re.compile(r"\b\d{3}-\d{2}-\d{4}\b"), 0.99),
    (
        EntityType.PHONE,
        re.compile(r"(?<!\d)(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}(?!\d)"),
        0.95,
    ),
    (EntityType.EMAIL, re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b"), 0.98),
    (
        EntityType.INSURANCE_ID,
        re.compile(
            r"\b(?:insurance|member|policy)\s*(?:id|#|number)?\s*(?:is\s+)?[:#]?\s*([A-Z0-9-]{6,})\b",
            re.IGNORECASE,
        ),
        0.93,
    ),
    (EntityType.MRN, re.compile(r"\bMRN\s*[:#]?\s*([A-Z0-9-]{4,})\b", re.IGNORECASE), 0.97),
    (
        EntityType.DOB,
        re.compile(r"\b(?:0?[1-9]|1[0-2])[/-](?:0?[1-9]|[12]\d|3[01])[/-](?:19|20)\d{2}\b"),
        0.96,
    ),
    (
        EntityType.ADDRESS,
        re.compile(
            r"\b\d{1,5}\s+[A-Z][a-z]+(?:\s+[A-Z][a-z]+)?\s+"
            r"(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way)\b"
        ),
        0.84,
    ),
]

_HEALTH_KEYWORDS = re.compile(
    r"\b(chest pain|doctor|diagnosis|diagnosed|symptom[s]?|insurance id|insurance|"
    r"patient|medical|prescription|medication|allergy|allergies|asthma|diabetes|"
    r"cancer|blood pressure|heart attack|anxiety|depression|surgery)\b",
    re.IGNORECASE,
)

_NAME_PATTERNS: list[Pattern[str]] = [
    re.compile(r"\b(?:my name is|patient name is|this is)\s+([A-Z][a-z]+(?:\s+[A-Z][a-z]+){0,2})\b"),
]

_PATIENT_ID_PATTERNS: list[tuple[EntityType, Pattern[str], float]] = [
    (
        EntityType.MRN,
        re.compile(
            r"\b(?:patient id|patient identifier)\s*(?:is\s+)?[:#]?\s*([A-Z0-9-]{4,})\b",
            re.IGNORECASE,
        ),
        0.9,
    ),
]


def _append_entity(
    entities: list[Entity],
    *,
    type_: EntityType,
    value: str,
    start: int,
    end: int,
    confidence: float,
    health_context: bool = False,
) -> None:
    if any(existing.start == start and existing.end == end and existing.type == type_ for existing in entities):
        return
    entities.append(
        Entity(
            type=type_,
            value=value,
            start=start,
            end=end,
            confidence=confidence,
            health_context=health_context,
        )
    )


def _risk_from_entities(entities: list[Entity], has_health_context: bool) -> RiskLevel:
    if not entities and not has_health_context:
        return "none"
    high_risk_types = {EntityType.SSN, EntityType.MRN, EntityType.INSURANCE_ID}
    if any(e.type in high_risk_types for e in entities):
        return "high"
    if has_health_context and entities:
        return "high"
    if entities:
        return "medium"
    return "low"


def detect(text: str) -> DetectionResult:
    """Detect sensitive entities in `text`.

    Codex: replace the body to use Gemma 4 / functiongemma classification.
    Keep returning a DetectionResult so the rest of the pipeline is unaffected.
    """
    entities: list[Entity] = []
    for etype, pattern, confidence in _PATTERNS:
        for m in pattern.finditer(text):
            has_capture = bool(m.groups())
            value = m.group(1) if has_capture else m.group(0)
            _append_entity(
                entities,
                type_=etype,
                value=value,
                start=m.start(1) if has_capture else m.start(),
                end=m.end(1) if has_capture else m.end(),
                confidence=confidence,
            )

    for etype, pattern, confidence in _PATIENT_ID_PATTERNS:
        for m in pattern.finditer(text):
            _append_entity(
                entities,
                type_=etype,
                value=m.group(1),
                start=m.start(1),
                end=m.end(1),
                confidence=confidence,
                health_context=True,
            )

    for pattern in _NAME_PATTERNS:
        for m in pattern.finditer(text):
            _append_entity(
                entities,
                type_=EntityType.NAME,
                value=m.group(1),
                start=m.start(1),
                end=m.end(1),
                confidence=0.72,
            )

    health_matches = list(_HEALTH_KEYWORDS.finditer(text))
    has_health = bool(health_matches)
    for m in health_matches:
        _append_entity(
            entities,
            type_=EntityType.HEALTH_CONTEXT,
            value=m.group(0),
            start=m.start(),
            end=m.end(),
            confidence=0.7,
            health_context=True,
        )

    risk = _risk_from_entities(
        [e for e in entities if e.type != EntityType.HEALTH_CONTEXT],
        has_health,
    )
    return DetectionResult(
        entities=sorted(entities, key=lambda entity: (entity.start, entity.end, entity.type.value)),
        risk_level=risk,
        health_context=has_health,
    )
