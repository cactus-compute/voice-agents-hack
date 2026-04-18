use std::fmt::Write as _;
use std::time::Instant;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EntityType {
    Ssn,
    Phone,
    Email,
    Name,
    InsuranceId,
    Mrn,
    HealthContext,
}

impl EntityType {
    pub fn as_str(&self) -> &'static str {
        match self {
            EntityType::Ssn => "ssn",
            EntityType::Phone => "phone",
            EntityType::Email => "email",
            EntityType::Name => "name",
            EntityType::InsuranceId => "insurance_id",
            EntityType::Mrn => "mrn",
            EntityType::HealthContext => "health_context",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RiskLevel {
    None,
    Low,
    Medium,
    High,
}

impl RiskLevel {
    pub fn as_str(&self) -> &'static str {
        match self {
            RiskLevel::None => "none",
            RiskLevel::Low => "low",
            RiskLevel::Medium => "medium",
            RiskLevel::High => "high",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PolicyPreset {
    HipaaBase,
    HipaaLoggingStrict,
    HipaaClinicalContext,
}

impl PolicyPreset {
    pub fn as_str(&self) -> &'static str {
        match self {
            PolicyPreset::HipaaBase => "hipaa_base",
            PolicyPreset::HipaaLoggingStrict => "hipaa_logging_strict",
            PolicyPreset::HipaaClinicalContext => "hipaa_clinical_context",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RouteDecision {
    LocalOnly,
    MaskedSend,
    SafeToSend,
}

impl RouteDecision {
    pub fn as_str(&self) -> &'static str {
        match self {
            RouteDecision::LocalOnly => "local-only",
            RouteDecision::MaskedSend => "masked-send",
            RouteDecision::SafeToSend => "safe-to-send",
        }
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct Entity {
    pub entity_type: EntityType,
    pub value: String,
    pub start: usize,
    pub end: usize,
    pub confidence: f32,
    pub health_context: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct DetectionResult {
    pub entities: Vec<Entity>,
    pub risk_level: RiskLevel,
    pub health_context: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PolicyDecision {
    pub route: RouteDecision,
    pub policy: PolicyPreset,
    pub reasons: Vec<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Replacement {
    pub entity_type: EntityType,
    pub original: String,
    pub replacement: String,
    pub start: usize,
    pub end: usize,
}

#[derive(Debug, Clone, PartialEq)]
pub struct MaskedTranscript {
    pub text: String,
    pub replacements: Vec<Replacement>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Timings {
    pub detection_ms: f64,
    pub policy_ms: f64,
    pub masking_ms: f64,
}

impl Timings {
    pub fn total_ms(&self) -> f64 {
        self.detection_ms + self.policy_ms + self.masking_ms
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct PrivacyResult {
    pub detection: DetectionResult,
    pub decision: PolicyDecision,
    pub masked: MaskedTranscript,
    pub timings: Timings,
}

pub fn analyze_transcript(text: &str, policy: PolicyPreset) -> PrivacyResult {
    let detection_started = Instant::now();
    let detection = detect(text);
    let detection_ms = detection_started.elapsed().as_secs_f64() * 1000.0;

    let policy_started = Instant::now();
    let decision = decide(&detection, policy);
    let policy_ms = policy_started.elapsed().as_secs_f64() * 1000.0;

    let masking_started = Instant::now();
    let masked = mask(text, &detection);
    let masking_ms = masking_started.elapsed().as_secs_f64() * 1000.0;

    PrivacyResult {
        detection,
        decision,
        masked,
        timings: Timings {
            detection_ms,
            policy_ms,
            masking_ms,
        },
    }
}

pub fn detect(text: &str) -> DetectionResult {
    let mut entities = Vec::new();

    entities.extend(find_ssns(text));
    entities.extend(find_emails(text));
    entities.extend(find_phones(text));
    entities.extend(find_tagged_value(
        text,
        &["insurance id", "member id", "policy number"],
        EntityType::InsuranceId,
        0.93,
        false,
    ));
    entities.extend(find_tagged_value(text, &["mrn", "patient id", "patient identifier"], EntityType::Mrn, 0.96, true));
    entities.extend(find_names(text));
    entities.extend(find_health_context(text));

    entities.sort_by_key(|entity| (entity.start, entity.end, entity.entity_type.as_str().to_string()));
    entities.dedup_by(|left, right| {
        left.start == right.start && left.end == right.end && left.entity_type == right.entity_type
    });

    let health_context = entities
        .iter()
        .any(|entity| entity.entity_type == EntityType::HealthContext);
    let non_context_entities = entities
        .iter()
        .filter(|entity| entity.entity_type != EntityType::HealthContext)
        .count();
    let high_risk = entities.iter().any(|entity| {
        matches!(entity.entity_type, EntityType::Ssn | EntityType::Mrn | EntityType::InsuranceId)
    });

    let risk_level = if high_risk || (health_context && non_context_entities > 0) {
        RiskLevel::High
    } else if non_context_entities > 0 {
        RiskLevel::Medium
    } else if health_context {
        RiskLevel::Low
    } else {
        RiskLevel::None
    };

    DetectionResult {
        entities,
        risk_level,
        health_context,
    }
}

pub fn decide(detection: &DetectionResult, policy: PolicyPreset) -> PolicyDecision {
    let mut reasons = Vec::new();
    let has_identifiers = detection
        .entities
        .iter()
        .any(|entity| entity.entity_type != EntityType::HealthContext);
    let has_high_risk = detection.entities.iter().any(|entity| {
        matches!(entity.entity_type, EntityType::Ssn | EntityType::Mrn | EntityType::InsuranceId)
    });
    let has_linkable = detection.entities.iter().any(|entity| {
        matches!(entity.entity_type, EntityType::InsuranceId | EntityType::Mrn | EntityType::Name)
    });

    if detection.health_context {
        reasons.push("health_context_detected".to_string());
    }
    if has_identifiers {
        reasons.push("contains_identifier".to_string());
    }
    if has_high_risk {
        reasons.push("high_risk_identifier".to_string());
    }
    if has_linkable {
        reasons.push("patient_record_linkable".to_string());
    }

    if matches!(policy, PolicyPreset::HipaaClinicalContext) && detection.health_context && has_identifiers {
        reasons.push("clinical_context_requires_local_review".to_string());
    }

    let route = match policy {
        PolicyPreset::HipaaLoggingStrict if has_identifiers || detection.health_context => {
            RouteDecision::MaskedSend
        }
        PolicyPreset::HipaaClinicalContext if has_high_risk => RouteDecision::LocalOnly,
        PolicyPreset::HipaaClinicalContext if detection.health_context && has_identifiers => {
            reasons.push("clinical_context_requires_local_review".to_string());
            RouteDecision::LocalOnly
        }
        PolicyPreset::HipaaClinicalContext if detection.health_context => RouteDecision::MaskedSend,
        _ if has_high_risk => RouteDecision::LocalOnly,
        _ if has_identifiers => RouteDecision::MaskedSend,
        _ => {
            if reasons.is_empty() {
                reasons.push("no_sensitive_content_detected".to_string());
            }
            RouteDecision::SafeToSend
        }
    };

    if reasons.is_empty() {
        reasons.push("no_sensitive_content_detected".to_string());
    }

    PolicyDecision {
        route,
        policy,
        reasons,
    }
}

pub fn mask(text: &str, detection: &DetectionResult) -> MaskedTranscript {
    let mut replacements: Vec<Replacement> = detection
        .entities
        .iter()
        .filter(|entity| entity.entity_type != EntityType::HealthContext)
        .map(|entity| Replacement {
            entity_type: entity.entity_type.clone(),
            original: entity.value.clone(),
            replacement: "[MASKED]".to_string(),
            start: entity.start,
            end: entity.end,
        })
        .collect();

    replacements.sort_by_key(|replacement| replacement.start);

    let mut filtered = Vec::new();
    let mut last_end = 0usize;
    for replacement in replacements {
        if replacement.start >= last_end {
            last_end = replacement.end;
            filtered.push(replacement);
        }
    }

    let mut output = String::new();
    let mut cursor = 0usize;
    for replacement in &filtered {
        output.push_str(&text[cursor..replacement.start]);
        output.push_str(&replacement.replacement);
        cursor = replacement.end;
    }
    output.push_str(&text[cursor..]);

    MaskedTranscript {
        text: output,
        replacements: filtered,
    }
}

pub fn scrub_output(output: &str, detection: &DetectionResult) -> String {
    let mut scrubbed = output.to_string();
    for entity in &detection.entities {
        if entity.entity_type != EntityType::HealthContext && !entity.value.is_empty() {
            scrubbed = scrubbed.replace(&entity.value, "[MASKED]");
        }
    }
    scrubbed
}

pub fn to_json(result: &PrivacyResult) -> String {
    let mut json = String::new();
    json.push_str("{\n");
    json.push_str("  \"detection\": {\n");
    json.push_str("    \"entities\": [\n");
    for (idx, entity) in result.detection.entities.iter().enumerate() {
        let _ = writeln!(
            json,
            "      {{\"type\":\"{}\",\"value\":\"{}\",\"start\":{},\"end\":{},\"confidence\":{:.2},\"health_context\":{}}}{}",
            entity.entity_type.as_str(),
            escape_json(&entity.value),
            entity.start,
            entity.end,
            entity.confidence,
            if entity.health_context { "true" } else { "false" },
            if idx + 1 == result.detection.entities.len() { "" } else { "," }
        );
    }
    let _ = writeln!(
        json,
        "    ],\n    \"risk_level\": \"{}\",\n    \"health_context\": {}\n  }},",
        result.detection.risk_level.as_str(),
        if result.detection.health_context { "true" } else { "false" }
    );
    let _ = writeln!(
        json,
        "  \"policy\": {{\"route\":\"{}\",\"policy\":\"{}\",\"reasons\":[{}]}},",
        result.decision.route.as_str(),
        result.decision.policy.as_str(),
        result
            .decision
            .reasons
            .iter()
            .map(|reason| format!("\"{}\"", escape_json(reason)))
            .collect::<Vec<_>>()
            .join(",")
    );
    let _ = writeln!(
        json,
        "  \"masked\": {{\"text\": \"{}\"}},",
        escape_json(&result.masked.text)
    );
    let _ = writeln!(
        json,
        "  \"timings\": {{\"detection_ms\": {:.3}, \"policy_ms\": {:.3}, \"masking_ms\": {:.3}, \"total_ms\": {:.3}}}",
        result.timings.detection_ms,
        result.timings.policy_ms,
        result.timings.masking_ms,
        result.timings.total_ms()
    );
    json.push('}');
    json
}

fn is_word_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'_'
}

fn find_ssns(text: &str) -> Vec<Entity> {
    let bytes = text.as_bytes();
    let mut entities = Vec::new();
    let mut idx = 0usize;
    while idx + 11 <= bytes.len() {
        let slice = &bytes[idx..idx + 11];
        let valid = slice[0].is_ascii_digit()
            && slice[1].is_ascii_digit()
            && slice[2].is_ascii_digit()
            && slice[3] == b'-'
            && slice[4].is_ascii_digit()
            && slice[5].is_ascii_digit()
            && slice[6] == b'-'
            && slice[7].is_ascii_digit()
            && slice[8].is_ascii_digit()
            && slice[9].is_ascii_digit()
            && slice[10].is_ascii_digit();
        let left_ok = idx == 0 || !is_word_byte(bytes[idx - 1]);
        let right_ok = idx + 11 == bytes.len() || !is_word_byte(bytes[idx + 11]);
        if valid && left_ok && right_ok {
            entities.push(Entity {
                entity_type: EntityType::Ssn,
                value: text[idx..idx + 11].to_string(),
                start: idx,
                end: idx + 11,
                confidence: 0.99,
                health_context: false,
            });
            idx += 11;
        } else {
            idx += 1;
        }
    }
    entities
}

fn find_emails(text: &str) -> Vec<Entity> {
    let bytes = text.as_bytes();
    let mut entities = Vec::new();
    for (idx, byte) in bytes.iter().enumerate() {
        if *byte != b'@' {
            continue;
        }
        let mut start = idx;
        while start > 0 && is_email_char(bytes[start - 1]) {
            start -= 1;
        }
        let mut end = idx + 1;
        while end < bytes.len() && is_email_char(bytes[end]) {
            end += 1;
        }
        if start < idx && end > idx + 1 {
            let candidate = &text[start..end];
            if candidate.contains('.') {
                entities.push(Entity {
                    entity_type: EntityType::Email,
                    value: candidate.to_string(),
                    start,
                    end,
                    confidence: 0.98,
                    health_context: false,
                });
            }
        }
    }
    entities
}

fn is_email_char(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'+' | b'-')
}

fn find_phones(text: &str) -> Vec<Entity> {
    let bytes = text.as_bytes();
    let mut entities = Vec::new();
    let mut idx = 0usize;
    while idx < bytes.len() {
        if !bytes[idx].is_ascii_digit() && bytes[idx] != b'(' && bytes[idx] != b'+' {
            idx += 1;
            continue;
        }
        let mut end = idx;
        let mut digit_count = 0usize;
        while end < bytes.len() && (bytes[end].is_ascii_digit() || b"()+-. ".contains(&bytes[end])) {
            if bytes[end].is_ascii_digit() {
                digit_count += 1;
            }
            end += 1;
        }
        let candidate = text[idx..end].trim();
        let normalized_digits = candidate.chars().filter(|ch| ch.is_ascii_digit()).count();
        if digit_count == normalized_digits && (normalized_digits == 10 || normalized_digits == 11) {
            let start_offset = text[idx..end].find(candidate).unwrap_or(0);
            let start = idx + start_offset;
            let finish = start + candidate.len();
            entities.push(Entity {
                entity_type: EntityType::Phone,
                value: candidate.to_string(),
                start,
                end: finish,
                confidence: 0.95,
                health_context: false,
            });
            idx = end;
        } else {
            idx += 1;
        }
    }
    entities
}

fn find_tagged_value(
    text: &str,
    labels: &[&str],
    entity_type: EntityType,
    confidence: f32,
    health_context: bool,
) -> Vec<Entity> {
    let lower = text.to_ascii_lowercase();
    let mut entities = Vec::new();
    for label in labels {
        let mut search_from = 0usize;
        while let Some(relative) = lower[search_from..].find(label) {
            let label_start = search_from + relative;
            let mut cursor = label_start + label.len();
            while let Some(byte) = lower.as_bytes().get(cursor) {
                if byte.is_ascii_whitespace() || *byte == b':' || *byte == b'#' {
                    cursor += 1;
                } else {
                    break;
                }
            }
            if lower[cursor..].starts_with("is ") {
                cursor += 3;
            }
            let start = cursor;
            while let Some(byte) = text.as_bytes().get(cursor) {
                if byte.is_ascii_alphanumeric() || *byte == b'-' {
                    cursor += 1;
                } else {
                    break;
                }
            }
            let value = text[start..cursor].trim();
            if value.len() >= 4 {
                entities.push(Entity {
                    entity_type: entity_type.clone(),
                    value: value.to_string(),
                    start,
                    end: start + value.len(),
                    confidence,
                    health_context,
                });
            }
            search_from = label_start + label.len();
        }
    }
    entities
}

fn find_names(text: &str) -> Vec<Entity> {
    let lower = text.to_ascii_lowercase();
    let labels = ["my name is ", "patient name is ", "this is "];
    let mut entities = Vec::new();
    for label in labels {
        let mut search_from = 0usize;
        while let Some(relative) = lower[search_from..].find(label) {
            let start = search_from + relative + label.len();
            let remaining = &text[start..];
            let end = remaining
                .find(|ch: char| matches!(ch, ',' | '.' | ';' | ':' | '\n'))
                .map(|offset| start + offset)
                .unwrap_or(text.len());
            let candidate = text[start..end].trim();
            let parts: Vec<&str> = candidate.split_whitespace().collect();
            let title_case = !parts.is_empty()
                && parts.len() <= 3
                && parts.iter().all(|part| {
                    let mut chars = part.chars();
                    matches!(chars.next(), Some(ch) if ch.is_ascii_uppercase())
                        && chars.all(|ch| ch.is_ascii_lowercase())
                });
            if title_case {
                entities.push(Entity {
                    entity_type: EntityType::Name,
                    value: candidate.to_string(),
                    start,
                    end: start + candidate.len(),
                    confidence: 0.72,
                    health_context: false,
                });
            }
            search_from = start;
        }
    }
    entities
}

fn find_health_context(text: &str) -> Vec<Entity> {
    let keywords = [
        "chest pain",
        "doctor",
        "diagnosis",
        "diagnosed",
        "symptom",
        "symptoms",
        "insurance",
        "insurance id",
        "patient",
        "medical",
        "prescription",
        "medication",
        "allergy",
        "allergies",
        "asthma",
        "diabetes",
        "cancer",
        "blood pressure",
        "heart attack",
        "anxiety",
        "depression",
        "surgery",
    ];
    let lower = text.to_ascii_lowercase();
    let mut entities = Vec::new();
    for keyword in keywords {
        let mut search_from = 0usize;
        while let Some(relative) = lower[search_from..].find(keyword) {
            let start = search_from + relative;
            let end = start + keyword.len();
            entities.push(Entity {
                entity_type: EntityType::HealthContext,
                value: text[start..end].to_string(),
                start,
                end,
                confidence: 0.70,
                health_context: true,
            });
            search_from = end;
        }
    }
    entities
}

fn escape_json(input: &str) -> String {
    input
        .replace('\\', "\\\\")
        .replace('"', "\\\"")
        .replace('\n', "\\n")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn safe_query_routes_safe_to_send() {
        let result = analyze_transcript("What's the weather tomorrow?", PolicyPreset::HipaaBase);
        assert_eq!(result.detection.risk_level, RiskLevel::None);
        assert_eq!(result.decision.route, RouteDecision::SafeToSend);
    }

    #[test]
    fn healthcare_identifier_routes_local_only_in_clinical_policy() {
        let result = analyze_transcript(
            "My doctor said I have chest pain and my insurance ID is BCBS-887421.",
            PolicyPreset::HipaaClinicalContext,
        );
        assert_eq!(result.detection.risk_level, RiskLevel::High);
        assert!(result.detection.health_context);
        assert_eq!(result.decision.route, RouteDecision::LocalOnly);
        assert!(result
            .decision
            .reasons
            .contains(&"clinical_context_requires_local_review".to_string()));
    }

    #[test]
    fn personal_info_routes_masked_send() {
        let result =
            analyze_transcript("Email me at jane@example.com or call 415-555-0123.", PolicyPreset::HipaaBase);
        assert_eq!(result.decision.route, RouteDecision::MaskedSend);
        assert!(result.masked.text.contains("[MASKED]"));
        assert!(!result.masked.text.contains("jane@example.com"));
    }

    #[test]
    fn masking_preserves_context() {
        let text = "My doctor said my insurance ID is BCBS-887421.";
        let detection = detect(text);
        let masked = mask(text, &detection);
        assert_eq!(masked.text, "My doctor said my insurance ID is [MASKED].");
    }

    #[test]
    fn scrub_output_re_masks_leaked_values() {
        let detection = detect("Please email jane@example.com");
        let scrubbed = scrub_output("I will contact jane@example.com now.", &detection);
        assert_eq!(scrubbed, "I will contact [MASKED] now.");
    }
}
