"""Policy engine. CODEX OWNS THIS FILE.

Maps a DetectionResult to a PolicyDecision (route + policy + reasons).
Ships a HIPAA-first baseline so the pipeline runs end-to-end. Codex can
swap in a richer policy DSL — keep the signature stable.

Contract (see AGENTS.md):
    decide(detection: DetectionResult, *, policy_name: PolicyName) -> PolicyDecision
"""

from __future__ import annotations

from .contracts import DetectionResult, EntityType, PolicyDecision, PolicyName

_HIGH_RISK_LOCAL_ONLY: set[EntityType] = {EntityType.SSN, EntityType.MRN}
_MASKED_SEND_TYPES: set[EntityType] = {
    EntityType.EMAIL,
    EntityType.PHONE,
    EntityType.NAME,
    EntityType.ADDRESS,
    EntityType.DOB,
    EntityType.INSURANCE_ID,
}


def _normalize_policy_name(policy_name: str) -> PolicyName:
    if policy_name == "hipaa_logging":
        return "hipaa_logging_strict"
    if policy_name == "hipaa_clinical":
        return "hipaa_clinical_context"
    return policy_name  # type: ignore[return-value]


def _decision(
    *,
    route: str,
    policy: PolicyName,
    reasons: list[str],
) -> PolicyDecision:
    return PolicyDecision(
        route=route,  # type: ignore[arg-type]
        policy=policy,
        reasons=reasons,
        rationale=", ".join(reasons) if reasons else "no_sensitive_content_detected",
    )


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
    policy_name = _normalize_policy_name(policy_name)
    types = {e.type for e in detection.entities}
    sensitive_types = {etype for etype in types if etype != EntityType.HEALTH_CONTEXT}
    reasons: list[str] = []

    if detection.health_context:
        reasons.append("health_context_detected")
    if sensitive_types:
        reasons.append("contains_identifier")
    if types & _HIGH_RISK_LOCAL_ONLY:
        reasons.append("high_risk_identifier")
    if types & {EntityType.INSURANCE_ID, EntityType.DOB, EntityType.ADDRESS}:
        reasons.append("patient_record_linkable")

    if policy_name == "hipaa_logging_strict":
        if sensitive_types or detection.health_context:
            return _decision(
                route="masked-send",
                policy=policy_name,
                reasons=reasons or ["strict_logging_redaction"],
            )

    if policy_name == "hipaa_clinical_context":
        if types & _HIGH_RISK_LOCAL_ONLY:
            return _decision(
                route="local-only",
                policy=policy_name,
                reasons=reasons,
            )
        if detection.health_context and sensitive_types:
            return _decision(
                route="local-only",
                policy=policy_name,
                reasons=reasons + ["clinical_context_requires_local_review"],
            )
        if detection.health_context:
            return _decision(
                route="masked-send",
                policy=policy_name,
                reasons=reasons or ["clinical_context_detected"],
            )

    if types & _HIGH_RISK_LOCAL_ONLY:
        return _decision(
            route="local-only",
            policy=policy_name,
            reasons=reasons,
        )

    if sensitive_types & _MASKED_SEND_TYPES:
        return _decision(
            route="masked-send",
            policy=policy_name,
            reasons=reasons,
        )

    return _decision(
        route="safe-to-send",
        policy=policy_name,
        reasons=["no_sensitive_content_detected"],
    )
