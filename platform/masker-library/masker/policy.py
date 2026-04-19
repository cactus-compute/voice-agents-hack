"""Policy engine. CODEX OWNS THIS FILE.

Maps a DetectionResult to a PolicyDecision (route + policy + rationale).
Ships a HIPAA-first baseline so the pipeline runs end-to-end. Codex can
swap in a richer policy DSL — keep the signature stable.

Contract (see AGENTS.md):
    decide(detection: DetectionResult, *, policy_name: PolicyName) -> PolicyDecision
"""

from __future__ import annotations

from .contracts import DetectionResult, EntityType, PolicyDecision, PolicyName, Route

_HIGH_RISK_LOCAL_ONLY: set[EntityType] = {EntityType.SSN, EntityType.MRN}


# ---------------------------------------------------------------------------
# HIPAA control mapping
# ---------------------------------------------------------------------------
# Each route maps to the HIPAA Security Rule / Safe Harbor citations the
# decision satisfies. These get tagged onto every AuditEntry so a privacy
# officer can hand the audit trail straight to OCR. See HIPAA-MAPPING.md
# for the full citation table.
HIPAA_CONTROLS_BY_ROUTE: dict[Route, list[str]] = {
    "local-only": [
        "164.312(a)(1)",     # Access control — restrict to authorized persons
        "164.312(b)",        # Audit controls — record + examine activity
        "164.514(b)(2)",     # Safe Harbor de-identification baseline
    ],
    "masked-send": [
        "164.312(a)(1)",     # Access control
        "164.312(b)",        # Audit controls
        "164.514(b)(2)(R)",  # Safe Harbor — any other unique identifying number
    ],
    "safe-to-send": [
        "164.312(b)",        # Audit controls (still log the no-op decision)
    ],
}


def hipaa_controls(decision: PolicyDecision) -> list[str]:
    """Return the HIPAA citations satisfied by this routing decision.

    Defensive: an unknown route returns just the audit-controls citation so
    the chain still records *something* rather than silently dropping the
    row. Unknown routes are a programming error — surface them in review.
    """
    return list(HIPAA_CONTROLS_BY_ROUTE.get(decision.route, ["164.312(b)"]))


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
