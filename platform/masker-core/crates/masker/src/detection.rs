//! Sensitive-content detection. Mirrors the regex baseline in
//! `platform/masker-library/masker/detection.py`. Codex-equivalent agents are
//! expected to swap the body of [`detect`] for a Gemma-classifier without
//! changing the signature.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::contracts::{DetectionResult, Entity, EntityType, RiskLevel};

struct Pat {
    kind: EntityType,
    re: Regex,
    /// Capture index whose span/value should be used. 0 means use the full match.
    capture: usize,
}

static PATTERNS: Lazy<Vec<Pat>> = Lazy::new(|| {
    vec![
        Pat {
            kind: EntityType::Ssn,
            re: Regex::new(r"\b\d{3}-\d{2}-\d{4}\b").unwrap(),
            capture: 0,
        },
        Pat {
            kind: EntityType::Phone,
            re: Regex::new(r"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b").unwrap(),
            capture: 0,
        },
        Pat {
            kind: EntityType::Email,
            re: Regex::new(r"\b[\w.+-]+@[\w-]+\.[\w.-]+\b").unwrap(),
            capture: 0,
        },
        Pat {
            kind: EntityType::InsuranceId,
            // Allow optional connector words like "is" / "=" between the
            // keyword ("insurance ID") and the actual value.
            re: Regex::new(
                r"(?i)\b(?:insurance|member|policy)\s*(?:id|#|number)?(?:\s+(?:is|=|number))?\s*[:#=]?\s*([A-Z]{2,}-?[A-Z0-9]{4,}|[A-Z0-9]{6,})\b",
            )
            .unwrap(),
            capture: 1,
        },
        Pat {
            kind: EntityType::Mrn,
            re: Regex::new(r"(?i)\bMRN\s*(?:#|number|is)?\s*[:#=]?\s*([A-Z0-9-]{4,})\b").unwrap(),
            capture: 1,
        },
        Pat {
            kind: EntityType::Dob,
            re: Regex::new(
                r"\b(?:0?[1-9]|1[0-2])[/-](?:0?[1-9]|[12]\d|3[01])[/-](?:19|20)\d{2}\b",
            )
            .unwrap(),
            capture: 0,
        },
        Pat {
            kind: EntityType::Address,
            re: Regex::new(
                r"\b\d{1,5}\s+[A-Z][a-z]+(?:\s+(?:Street|St|Avenue|Ave|Road|Rd|Boulevard|Blvd|Drive|Dr|Lane|Ln|Way))?\b",
            )
            .unwrap(),
            capture: 0,
        },
    ]
});

static HEALTH_KEYWORDS: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"(?i)\b(chest pain|diabetes|cancer|asthma|prescription|medication|symptoms?|diagnosis|insurance|patient|medical|hipaa|surgery|allergy|allergies|blood pressure|heart attack|depression|anxiety)\b",
    )
    .unwrap()
});

fn risk_from_entities(entities: &[Entity], has_health: bool) -> RiskLevel {
    if entities.is_empty() && !has_health {
        return RiskLevel::None;
    }
    let high = entities.iter().any(|e| {
        matches!(
            e.kind,
            EntityType::Ssn | EntityType::Mrn | EntityType::InsuranceId
        )
    });
    if high {
        return RiskLevel::High;
    }
    if has_health && !entities.is_empty() {
        return RiskLevel::High;
    }
    if !entities.is_empty() {
        return RiskLevel::Medium;
    }
    RiskLevel::Low
}

/// Detect sensitive entities in `text`.
///
/// Replace this function body to plug in a Gemma classifier; the signature
/// is the contract Cursor / Ona depend on.
pub fn detect(text: &str) -> DetectionResult {
    let mut entities: Vec<Entity> = Vec::new();

    for pat in PATTERNS.iter() {
        for caps in pat.re.captures_iter(text) {
            let m = match caps.get(pat.capture) {
                Some(g) => g,
                None => continue,
            };
            entities.push(Entity {
                kind: pat.kind,
                value: m.as_str().to_string(),
                start: m.start(),
                end: m.end(),
                confidence: 0.9,
            });
        }
    }

    let health_match = HEALTH_KEYWORDS.find(text);
    let has_health = health_match.is_some();
    if let Some(m) = health_match {
        entities.push(Entity {
            kind: EntityType::HealthContext,
            value: m.as_str().to_string(),
            start: m.start(),
            end: m.end(),
            confidence: 0.7,
        });
    }

    let identifying: Vec<Entity> = entities
        .iter()
        .filter(|e| !matches!(e.kind, EntityType::HealthContext))
        .cloned()
        .collect();
    let risk = risk_from_entities(&identifying, has_health);

    DetectionResult {
        entities,
        risk_level: risk,
    }
}
