"""Policy engine. CODEX OWNS THIS FILE.

Maps a DetectionResult to a PolicyDecision (route + policy + rationale).
Ships a HIPAA-first baseline so the pipeline runs end-to-end. Codex can
swap in a richer policy DSL — keep the signature stable.

Contract (see AGENTS.md):
    decide(detection: DetectionResult, *, policy_name: PolicyName) -> PolicyDecision
"""

from __future__ import annotations

from .contracts import DetectionResult, EntityType, PolicyDecision, PolicyName

_HIGH_RISK_LOCAL_ONLY: set[EntityType] = {EntityType.SSN, EntityType.MRN}


def decide(
    detection: DetectionResult,
    *,
    policy_name: PolicyName = "hipaa_base",
) -> PolicyDecision:
    """Decide the route for a turn given detected entities.

    Routes:
      - local-only: never leaves the device (highest sensitivity)
      - masked-send: forward to LLM with sensitive spans replaced
      - safe-to-send: forward verbatim (no PHI/PII detected)
    """
    types = {e.type for e in detection.entities}

    if policy_name == "hipaa_logging":
        if detection.has_sensitive:
            return PolicyDecision(
                route="masked-send",
                policy=policy_name,
                rationale="Strict logging policy: any sensitive data must be masked before traversal.",
            )

    if policy_name == "hipaa_clinical":
        if types & _HIGH_RISK_LOCAL_ONLY:
            return PolicyDecision(
                route="local-only",
                policy=policy_name,
                rationale="Direct identifiers (SSN/MRN) must stay on-device under clinical policy.",
            )
        if EntityType.HEALTH_CONTEXT in types and detection.entities:
            return PolicyDecision(
                route="masked-send",
                policy=policy_name,
                rationale="Clinical context with identifiers → mask identifiers, keep medical context.",
            )

    if types & _HIGH_RISK_LOCAL_ONLY:
        return PolicyDecision(
            route="local-only",
            policy=policy_name,
            rationale=f"High-risk identifiers detected: {sorted(t.value for t in types & _HIGH_RISK_LOCAL_ONLY)}",
        )

    if detection.has_sensitive:
        sensitive = sorted({e.type.value for e in detection.entities if e.type != EntityType.HEALTH_CONTEXT})
        return PolicyDecision(
            route="masked-send",
            policy=policy_name,
            rationale=f"Sensitive entities present: {sensitive}",
        )

    return PolicyDecision(
        route="safe-to-send",
        policy=policy_name,
        rationale="No sensitive entities detected.",
    )
