//! Typed contracts shared between every workstream.
//!
//! These mirror the JSON shapes from `AGENTS.md` so the integration layer,
//! the detection/policy layer, and the trace UI can all build against stable
//! interfaces. The Python reference implementation lives in `masker/contracts.py`.

use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EntityType {
    Ssn,
    Phone,
    Email,
    Name,
    Address,
    InsuranceId,
    Mrn,
    Dob,
    HealthContext,
    Other,
}

impl EntityType {
    pub fn as_str(self) -> &'static str {
        match self {
            EntityType::Ssn => "ssn",
            EntityType::Phone => "phone",
            EntityType::Email => "email",
            EntityType::Name => "name",
            EntityType::Address => "address",
            EntityType::InsuranceId => "insurance_id",
            EntityType::Mrn => "mrn",
            EntityType::Dob => "dob",
            EntityType::HealthContext => "health_context",
            EntityType::Other => "other",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RiskLevel {
    None,
    Low,
    Medium,
    High,
}

impl RiskLevel {
    pub fn as_str(self) -> &'static str {
        match self {
            RiskLevel::None => "none",
            RiskLevel::Low => "low",
            RiskLevel::Medium => "medium",
            RiskLevel::High => "high",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Route {
    LocalOnly,
    MaskedSend,
    SafeToSend,
}

impl Route {
    pub fn as_str(self) -> &'static str {
        match self {
            Route::LocalOnly => "local-only",
            Route::MaskedSend => "masked-send",
            Route::SafeToSend => "safe-to-send",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
#[allow(clippy::enum_variant_names)] // HIPAA prefix is intentional — policy family
pub enum PolicyName {
    HipaaBase,
    HipaaLogging,
    HipaaClinical,
}

impl PolicyName {
    pub fn as_str(self) -> &'static str {
        match self {
            PolicyName::HipaaBase => "hipaa_base",
            PolicyName::HipaaLogging => "hipaa_logging",
            PolicyName::HipaaClinical => "hipaa_clinical",
        }
    }
}

/// A single sensitive span detected in text.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Entity {
    #[serde(rename = "type")]
    pub kind: EntityType,
    pub value: String,
    /// Byte offsets into the original UTF-8 string.
    pub start: usize,
    pub end: usize,
    pub confidence: f32,
}

impl Entity {
    pub fn new(kind: EntityType, value: impl Into<String>, start: usize, end: usize) -> Self {
        Self {
            kind,
            value: value.into(),
            start,
            end,
            confidence: 0.9,
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DetectionResult {
    pub entities: Vec<Entity>,
    pub risk_level: RiskLevel,
}

impl DetectionResult {
    pub fn has_sensitive(&self) -> bool {
        matches!(self.risk_level, RiskLevel::Medium | RiskLevel::High)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PolicyDecision {
    pub route: Route,
    pub policy: PolicyName,
    #[serde(default)]
    pub rationale: String,
}

/// User-safe version of the text plus a token map for re-hydration.
/// Stored as BTreeMap so JSON output is deterministic.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MaskedText {
    pub text: String,
    pub token_map: BTreeMap<String, String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum TraceStage {
    Stt,
    Detection,
    Policy,
    Masking,
    Routing,
    Llm,
    OutputFilter,
    Tts,
}

impl TraceStage {
    pub fn as_str(self) -> &'static str {
        match self {
            TraceStage::Stt => "stt",
            TraceStage::Detection => "detection",
            TraceStage::Policy => "policy",
            TraceStage::Masking => "masking",
            TraceStage::Routing => "routing",
            TraceStage::Llm => "llm",
            TraceStage::OutputFilter => "output_filter",
            TraceStage::Tts => "tts",
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceEvent {
    pub stage: TraceStage,
    pub message: String,
    pub elapsed_ms: f64,
    #[serde(default)]
    pub payload: serde_json::Map<String, serde_json::Value>,
}

/// End-to-end output of a single voice turn.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TurnResult {
    pub user_text: String,
    pub detection: DetectionResult,
    pub policy: PolicyDecision,
    pub masked_input: MaskedText,
    pub model_output: String,
    pub safe_output: String,
    pub trace: Vec<TraceEvent>,
    pub total_ms: f64,
}
