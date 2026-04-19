//! Policy engine. Mirrors the HIPAA-first baseline in
//! `platform/masker-library/masker/policy.py`.

use std::collections::HashSet;

use crate::contracts::{DetectionResult, EntityType, PolicyDecision, PolicyName, Route};

fn is_high_risk_local_only(t: EntityType) -> bool {
    matches!(t, EntityType::Ssn | EntityType::Mrn)
}

pub fn decide(detection: &DetectionResult, policy_name: PolicyName) -> PolicyDecision {
    let types: HashSet<EntityType> = detection.entities.iter().map(|e| e.kind).collect();

    if matches!(policy_name, PolicyName::HipaaLogging) && detection.has_sensitive() {
        return PolicyDecision {
            route: Route::MaskedSend,
            policy: policy_name,
            rationale: "Strict logging policy: any sensitive data must be masked before traversal."
                .to_string(),
        };
    }

    // GDPR: mask all personal identifiers, allow non-personal context.
    if matches!(policy_name, PolicyName::GdprBase) && detection.has_sensitive() {
        return PolicyDecision {
            route: Route::MaskedSend,
            policy: policy_name,
            rationale: "GDPR base: all personal data must be masked before forwarding.".to_string(),
        };
    }

    if matches!(policy_name, PolicyName::HipaaClinical) {
        if types.iter().any(|&t| is_high_risk_local_only(t)) {
            return PolicyDecision {
                route: Route::LocalOnly,
                policy: policy_name,
                rationale:
                    "Direct identifiers (SSN/MRN) must stay on-device under clinical policy."
                        .to_string(),
            };
        }
        if types.contains(&EntityType::HealthContext) && !detection.entities.is_empty() {
            return PolicyDecision {
                route: Route::MaskedSend,
                policy: policy_name,
                rationale:
                    "Clinical context with identifiers → mask identifiers, keep medical context."
                        .to_string(),
            };
        }
    }

    if types.iter().any(|&t| is_high_risk_local_only(t)) {
        let mut hits: Vec<&'static str> = types
            .iter()
            .filter(|t| is_high_risk_local_only(**t))
            .map(|t| t.as_str())
            .collect();
        hits.sort();
        return PolicyDecision {
            route: Route::LocalOnly,
            policy: policy_name,
            rationale: format!("High-risk identifiers detected: {:?}", hits),
        };
    }

    if detection.has_sensitive() {
        let mut sensitive: Vec<&'static str> = detection
            .entities
            .iter()
            .filter(|e| !matches!(e.kind, EntityType::HealthContext))
            .map(|e| e.kind.as_str())
            .collect();
        sensitive.sort();
        sensitive.dedup();
        return PolicyDecision {
            route: Route::MaskedSend,
            policy: policy_name,
            rationale: format!("Sensitive entities present: {:?}", sensitive),
        };
    }

    PolicyDecision {
        route: Route::SafeToSend,
        policy: policy_name,
        rationale: "No sensitive entities detected.".to_string(),
    }
}
