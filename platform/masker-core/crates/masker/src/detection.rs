//! Sensitive-content detection. Regex remains the deterministic baseline and
//! fallback. When Cactus is enabled, a Gemma-backed detector can be layered on
//! top and merged with the regex result.

use once_cell::sync::Lazy;
use regex::Regex;

use crate::contracts::{DetectionResult, Entity, EntityType, RiskLevel};

#[cfg(feature = "cactus")]
use {crate::backends::GemmaBackend, crate::backends::LocalCactusBackend, serde::Deserialize};

pub trait Detector: Send + Sync {
    fn name(&self) -> &'static str;
    fn detect(&self, text: &str) -> DetectionResult;

    fn detect_with_audio(&self, text: &str, audio_path: Option<&str>) -> DetectionResult {
        let _ = audio_path;
        self.detect(text)
    }
}

#[derive(Default)]
pub struct RegexDetector;

impl Detector for RegexDetector {
    fn name(&self) -> &'static str {
        "regex"
    }

    fn detect(&self, text: &str) -> DetectionResult {
        detect_regex(text)
    }
}

pub fn detect(text: &str) -> DetectionResult {
    detect_regex(text)
}

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

static SSN_CUES: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)\b(ssn|s\s*s\s*n|sns|social security(?: number)?)\b").unwrap());

static CARD_CUES: Lazy<Regex> = Lazy::new(|| {
    Regex::new(
        r"(?i)\b(credit card(?: number)?|debit card(?: number)?|card number|grid card(?: number)?)\b",
    )
    .unwrap()
});

static CVV_CUES: Lazy<Regex> =
    Lazy::new(|| Regex::new(r"(?i)\b(c\s*v\s*v|cvv|security code)\b").unwrap());

static WORD_TOKENS: Lazy<Regex> = Lazy::new(|| Regex::new(r"[A-Za-z0-9']+").unwrap());

#[derive(Clone)]
struct WordToken<'a> {
    raw: &'a str,
    normalized: String,
    start: usize,
    end: usize,
}

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

fn detect_regex(text: &str) -> DetectionResult {
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

    entities.extend(find_spoken_ssn_entities(text));
    entities.extend(find_contextual_financial_entities(text));
    dedupe_entities(&mut entities);

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

fn find_spoken_ssn_entities(text: &str) -> Vec<Entity> {
    let tokens = tokenize_words(text);
    let mut entities = Vec::new();

    for cue in SSN_CUES.find_iter(text) {
        let Some(start_idx) = tokens.iter().position(|token| token.start >= cue.end()) else {
            continue;
        };

        if let Some(entity) =
            parse_number_after_cue(text, &tokens, start_idx, EntityType::Ssn, 8, 9, 0.8)
        {
            entities.push(entity);
        }
    }

    entities
}

fn find_contextual_financial_entities(text: &str) -> Vec<Entity> {
    let tokens = tokenize_words(text);
    let mut entities = Vec::new();

    for cue in CARD_CUES.find_iter(text) {
        let Some(start_idx) = tokens.iter().position(|token| token.start >= cue.end()) else {
            continue;
        };

        if let Some(entity) =
            parse_number_after_cue(text, &tokens, start_idx, EntityType::Other, 8, 19, 0.75)
        {
            entities.push(entity);
        }
    }

    for cue in CVV_CUES.find_iter(text) {
        let Some(start_idx) = tokens.iter().position(|token| token.start >= cue.end()) else {
            continue;
        };

        if let Some(entity) =
            parse_number_after_cue(text, &tokens, start_idx, EntityType::Other, 3, 4, 0.75)
        {
            entities.push(entity);
        }
    }

    entities
}

fn tokenize_words(text: &str) -> Vec<WordToken<'_>> {
    WORD_TOKENS
        .find_iter(text)
        .map(|m| WordToken {
            raw: m.as_str(),
            normalized: m.as_str().to_ascii_lowercase(),
            start: m.start(),
            end: m.end(),
        })
        .collect()
}

fn parse_number_after_cue(
    text: &str,
    tokens: &[WordToken<'_>],
    start_idx: usize,
    kind: EntityType,
    min_digits: usize,
    max_digits: usize,
    confidence: f32,
) -> Option<Entity> {
    let mut first_digit_idx = None;
    let mut last_digit_idx = None;
    let mut total_digits = 0usize;
    let mut examined = 0usize;
    let mut saw_digit = false;

    for token in tokens.iter().skip(start_idx).take(16) {
        examined += 1;

        if !saw_digit && is_spoken_number_filler(&token.normalized) {
            continue;
        }

        if let Some(digit_len) = ssn_digit_piece_len(token.raw, &token.normalized) {
            if first_digit_idx.is_none() {
                first_digit_idx = Some(token.start);
            }
            last_digit_idx = Some(token.end);
            total_digits += digit_len;
            saw_digit = true;

            if total_digits > max_digits {
                return None;
            }
            continue;
        }

        if is_spoken_number_separator(&token.normalized) {
            if !saw_digit {
                break;
            }
            continue;
        }

        if saw_digit {
            break;
        }

        if examined >= 4 {
            break;
        }
    }

    let (start, end) = match (first_digit_idx, last_digit_idx) {
        (Some(start), Some(end)) => (start, end),
        _ => return None,
    };

    if total_digits < min_digits || total_digits > max_digits {
        return None;
    }

    Some(Entity {
        kind,
        value: text[start..end].to_string(),
        start,
        end,
        confidence,
    })
}

fn ssn_digit_piece_len(raw: &str, normalized: &str) -> Option<usize> {
    match normalized {
        "zero" | "oh" | "o" | "one" | "two" | "three" | "four" | "five" | "six" | "seven"
        | "eight" | "nine" => Some(1),
        _ if raw.chars().all(|c| c.is_ascii_digit()) => Some(raw.len()),
        _ => None,
    }
}

fn is_spoken_number_separator(word: &str) -> bool {
    matches!(word, "dash" | "hyphen" | "minus")
}

fn is_spoken_number_filler(word: &str) -> bool {
    matches!(
        word,
        "is" | "was" | "number" | "num" | "equals" | "equal" | "colon" | "my" | "the"
    )
}

#[cfg(feature = "cactus")]
#[derive(Debug, Deserialize)]
struct ModelDetectionPayload {
    #[serde(default)]
    entities: Vec<ModelEntity>,
    risk_level: Option<String>,
}

#[cfg(feature = "cactus")]
#[derive(Debug, Deserialize)]
struct ModelEntity {
    #[serde(rename = "type")]
    kind: String,
    value: String,
    confidence: Option<f32>,
}

#[cfg(feature = "cactus")]
pub struct CactusFallbackDetector {
    primary: LocalCactusBackend,
    fallback: RegexDetector,
}

#[cfg(feature = "cactus")]
impl CactusFallbackDetector {
    pub fn from_env() -> Result<Self, crate::backends::BackendError> {
        let model_path = std::env::var("CACTUS_DETECTION_MODEL_PATH")
            .or_else(|_| std::env::var("CACTUS_MODEL_PATH"))
            .map_err(|_| {
                crate::backends::BackendError::NotConfigured(
                    "CACTUS_DETECTION_MODEL_PATH or CACTUS_MODEL_PATH missing".into(),
                )
            })?;

        let system_prompt = Some(
            "You are a privacy classifier for spoken healthcare and enterprise audio. \
Return JSON only. Never wrap it in markdown. \
Schema: {\"entities\":[{\"type\":\"ssn|phone|email|name|address|insurance_id|mrn|dob|health_context|other\",\"value\":\"exact span from the transcript\",\"confidence\":0.0}],\"risk_level\":\"none|low|medium|high\"}. \
If audio is attached, use it as the primary source of truth and treat the transcript as a noisy hint. \
If a sensitive value is audible but not verbatim in the transcript, still emit it in `value`."
                .to_string(),
        );

        Ok(Self {
            primary: LocalCactusBackend::new(model_path, system_prompt)?,
            fallback: RegexDetector,
        })
    }

    fn try_primary_detect(&self, text: &str) -> Option<DetectionResult> {
        let prompt =
            format!("Transcript:\n{text}\n\nReturn only the JSON object for the schema above.");
        let response = self.primary.generate(&prompt, 256).ok()?;
        let payload = parse_model_detection_payload(&response)?;
        Some(materialize_payload(text, payload))
    }

    fn try_primary_detect_with_audio(
        &self,
        text: &str,
        audio_path: &str,
    ) -> Option<DetectionResult> {
        let prompt = format!(
            "Attached audio contains a user utterance.\nTranscript hint (may be wrong or incomplete):\n{text}\n\nUse the audio to identify sensitive information. Prefer audio over the transcript when they disagree. Return only the JSON object for the schema above."
        );
        let response = self
            .primary
            .generate_with_audio(&prompt, audio_path, 256)
            .ok()?;
        let payload = parse_model_detection_payload(&response)?;
        Some(materialize_payload(text, payload))
    }

    fn detect_internal(&self, text: &str, audio_path: Option<&str>) -> DetectionResult {
        let regex = self.fallback.detect(text);
        let primary = audio_path
            .and_then(|path| self.try_primary_detect_with_audio(text, path))
            .or_else(|| self.try_primary_detect(text));

        match primary {
            Some(primary) => merge_detection_results(primary, regex),
            None => regex,
        }
    }
}

#[cfg(feature = "cactus")]
impl Detector for CactusFallbackDetector {
    fn name(&self) -> &'static str {
        "cactus+regex"
    }

    fn detect(&self, text: &str) -> DetectionResult {
        self.detect_internal(text, None)
    }

    fn detect_with_audio(&self, text: &str, audio_path: Option<&str>) -> DetectionResult {
        self.detect_internal(text, audio_path)
    }
}

#[cfg(feature = "cactus")]
fn parse_model_detection_payload(raw: &str) -> Option<ModelDetectionPayload> {
    let trimmed = raw.trim();
    let candidate = trimmed
        .strip_prefix("```json")
        .or_else(|| trimmed.strip_prefix("```"))
        .map(|s| s.trim())
        .and_then(|s| s.strip_suffix("```"))
        .map(str::trim)
        .unwrap_or(trimmed);

    serde_json::from_str(candidate).ok()
}

#[cfg(feature = "cactus")]
fn materialize_payload(text: &str, payload: ModelDetectionPayload) -> DetectionResult {
    let mut entities = Vec::new();
    let mut claimed_has_health = false;

    for item in payload.entities {
        let kind = match entity_type_from_str(&item.kind) {
            Some(kind) => kind,
            None => continue,
        };
        if kind == EntityType::HealthContext {
            claimed_has_health = true;
        }
        if let Some((start, end, value)) = locate_span(text, &item.value) {
            entities.push(Entity {
                kind,
                value,
                start,
                end,
                confidence: item.confidence.unwrap_or(0.7),
            });
        } else if !item.value.trim().is_empty() {
            entities.push(Entity {
                kind,
                value: item.value.trim().to_string(),
                start: 0,
                end: 0,
                confidence: item.confidence.unwrap_or(0.7),
            });
        }
    }

    dedupe_entities(&mut entities);

    let risk_level = payload
        .risk_level
        .as_deref()
        .and_then(risk_level_from_str)
        .unwrap_or_else(|| {
            let identifying: Vec<Entity> = entities
                .iter()
                .filter(|e| !matches!(e.kind, EntityType::HealthContext))
                .cloned()
                .collect();
            let has_health =
                claimed_has_health || entities.iter().any(|e| e.kind == EntityType::HealthContext);
            risk_from_entities(&identifying, has_health)
        });

    DetectionResult {
        entities,
        risk_level,
    }
}

#[cfg(feature = "cactus")]
fn locate_span(text: &str, needle: &str) -> Option<(usize, usize, String)> {
    let needle = needle.trim();
    if needle.is_empty() {
        return None;
    }
    text.find(needle)
        .map(|start| (start, start + needle.len(), needle.to_string()))
}

#[cfg(feature = "cactus")]
fn entity_type_from_str(kind: &str) -> Option<EntityType> {
    match kind.trim().to_ascii_lowercase().as_str() {
        "ssn" => Some(EntityType::Ssn),
        "phone" => Some(EntityType::Phone),
        "email" => Some(EntityType::Email),
        "name" => Some(EntityType::Name),
        "address" => Some(EntityType::Address),
        "insurance_id" => Some(EntityType::InsuranceId),
        "mrn" => Some(EntityType::Mrn),
        "dob" => Some(EntityType::Dob),
        "health_context" => Some(EntityType::HealthContext),
        "other" => Some(EntityType::Other),
        _ => None,
    }
}

#[cfg(feature = "cactus")]
fn risk_level_from_str(value: &str) -> Option<RiskLevel> {
    match value.trim().to_ascii_lowercase().as_str() {
        "none" => Some(RiskLevel::None),
        "low" => Some(RiskLevel::Low),
        "medium" => Some(RiskLevel::Medium),
        "high" => Some(RiskLevel::High),
        _ => None,
    }
}

#[cfg(feature = "cactus")]
fn merge_detection_results(primary: DetectionResult, fallback: DetectionResult) -> DetectionResult {
    let mut entities = primary.entities;
    entities.extend(fallback.entities);
    dedupe_entities(&mut entities);

    DetectionResult {
        entities,
        risk_level: max_risk(primary.risk_level, fallback.risk_level),
    }
}

fn dedupe_entities(entities: &mut Vec<Entity>) {
    entities.sort_by(|a, b| {
        (a.start, a.end, a.kind.as_str(), a.value.as_str()).cmp(&(
            b.start,
            b.end,
            b.kind.as_str(),
            b.value.as_str(),
        ))
    });
    entities.dedup_by(|a, b| {
        a.kind == b.kind && a.start == b.start && a.end == b.end && a.value == b.value
    });
}

#[cfg(feature = "cactus")]
fn max_risk(a: RiskLevel, b: RiskLevel) -> RiskLevel {
    use RiskLevel::*;
    match (a, b) {
        (High, _) | (_, High) => High,
        (Medium, _) | (_, Medium) => Medium,
        (Low, _) | (_, Low) => Low,
        _ => None,
    }
}

#[cfg(test)]
mod regex_tests {
    use super::*;

    #[test]
    fn detects_spoken_ssn_after_ssn_cue() {
        let detection = detect("My SSN is one two three four five six seven eight nine.");

        assert_eq!(detection.risk_level, RiskLevel::High);
        assert!(detection
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::Ssn));
    }

    #[test]
    fn detects_spoken_ssn_with_dash_words() {
        let detection = detect(
            "Social security number one two three dash four five dash six seven eight nine.",
        );

        assert!(detection
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::Ssn));
    }

    #[test]
    fn does_not_treat_plain_counting_as_ssn() {
        let detection = detect("One two three four five six seven eight nine reasons to call.");

        assert!(!detection
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::Ssn));
    }

    #[test]
    fn detects_noisy_ssn_after_sns_cue() {
        let detection = detect("My SNS 23178284 and I need help.");

        assert!(detection
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::Ssn));
        assert_eq!(detection.risk_level, RiskLevel::High);
    }

    #[test]
    fn detects_credit_card_number_after_contextual_cue() {
        let detection = detect("My credit card number is 4285946 1234.");

        assert!(detection
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::Other));
        assert_eq!(detection.risk_level, RiskLevel::Medium);
    }

    #[test]
    fn detects_cvv_after_contextual_cue() {
        let detection = detect("The C V V number is 123.");

        assert!(detection
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::Other));
        assert_eq!(detection.risk_level, RiskLevel::Medium);
    }
}

#[cfg(all(test, feature = "cactus"))]
mod cactus_tests {
    use super::*;

    #[test]
    fn merge_keeps_regex_entities_when_model_misses_them() {
        let primary = DetectionResult {
            entities: vec![Entity {
                kind: EntityType::HealthContext,
                value: "chest pain".into(),
                start: 17,
                end: 27,
                confidence: 0.8,
            }],
            risk_level: RiskLevel::Low,
        };

        let fallback = DetectionResult {
            entities: vec![Entity {
                kind: EntityType::Mrn,
                value: "99812".into(),
                start: 32,
                end: 37,
                confidence: 0.9,
            }],
            risk_level: RiskLevel::High,
        };

        let merged = merge_detection_results(primary, fallback);

        assert_eq!(merged.risk_level, RiskLevel::High);
        assert!(merged
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::HealthContext));
        assert!(merged
            .entities
            .iter()
            .any(|entity| entity.kind == EntityType::Mrn));
    }

    #[test]
    fn merge_dedupes_same_entity_reported_by_model_and_regex() {
        let entity = Entity {
            kind: EntityType::Ssn,
            value: "123-45-6789".into(),
            start: 10,
            end: 21,
            confidence: 0.95,
        };

        let merged = merge_detection_results(
            DetectionResult {
                entities: vec![entity.clone()],
                risk_level: RiskLevel::High,
            },
            DetectionResult {
                entities: vec![entity],
                risk_level: RiskLevel::High,
            },
        );

        assert_eq!(merged.entities.len(), 1);
        assert_eq!(merged.entities[0].kind, EntityType::Ssn);
    }

    #[test]
    fn materialize_payload_keeps_audio_only_entities_without_transcript_span() {
        let payload = ModelDetectionPayload {
            entities: vec![ModelEntity {
                kind: "ssn".into(),
                value: "123-45-6789".into(),
                confidence: Some(0.91),
            }],
            risk_level: Some("high".into()),
        };

        let result = materialize_payload("My SSN is one two three four five six.", payload);

        assert_eq!(result.risk_level, RiskLevel::High);
        assert_eq!(result.entities.len(), 1);
        assert_eq!(result.entities[0].kind, EntityType::Ssn);
        assert_eq!(result.entities[0].start, 0);
        assert_eq!(result.entities[0].end, 0);
        assert_eq!(result.entities[0].value, "123-45-6789");
    }
}
