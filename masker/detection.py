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

_PATTERNS: list[tuple[EntityType, Pattern[str]]] = [
    (EntityType.SSN, re.compile(r"\b\d{3}-\d{2}-\d{4}\b")),
    (EntityType.PHONE, re.compile(r"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b")),
    (EntityType.EMAIL, re.compile(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b")),
    (EntityType.INSURANCE_ID, re.compile(r"\b(?:insurance|member|policy)\s*(?:id|#|number)?\s*[:#]?\s*([A-Z0-9-]{6,})\b", re.IGNORECASE)),
    (EntityType.MRN, re.compile(r"\bMRN\s*[:#]?\s*([A-Z0-9-]{4,})\b", re.IGNORECASE)),
    (EntityType.DOB, re.compile(r"\b(?:0?[1-9]|1[0-2])[/-](?:0?[1-9]|[12]\d|3[01])[/-](?:19|20)\d{2}\b")),
    (EntityType.ADDRESS, re.compile(r"\b\d{1,5}\s+[A-Z][a-z]+(?:\s+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way))?\b")),
]

_HEALTH_KEYWORDS = re.compile(
    r"\b(chest pain|diabetes|cancer|asthma|prescription|medication|symptom[s]?|"
    r"diagnosis|insurance|patient|medical|hipaa|surgery|allergy|allergies|"
    r"blood pressure|heart attack|depression|anxiety)\b",
    re.IGNORECASE,
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
    for etype, pattern in _PATTERNS:
        for m in pattern.finditer(text):
            value = m.group(1) if m.groups() else m.group(0)
            entities.append(
                Entity(
                    type=etype,
                    value=value,
                    start=m.start(),
                    end=m.end(),
                    confidence=0.9,
                )
            )

    has_health = bool(_HEALTH_KEYWORDS.search(text))
    if has_health:
        m = _HEALTH_KEYWORDS.search(text)
        if m:
            entities.append(
                Entity(
                    type=EntityType.HEALTH_CONTEXT,
                    value=m.group(0),
                    start=m.start(),
                    end=m.end(),
                    confidence=0.7,
                )
            )

    risk = _risk_from_entities(
        [e for e in entities if e.type != EntityType.HEALTH_CONTEXT],
        has_health,
    )
    return DetectionResult(entities=entities, risk_level=risk)
