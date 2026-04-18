//! # Masker (Rust)
//!
//! On-device PII/PHI middleware for voice agents. Sits in front of any LLM
//! call, classifies the input with a small Gemma-class model, decides per a
//! HIPAA-first policy whether the turn must stay local / be masked / can pass
//! through verbatim, and re-scans the model's output for leaked secrets.
//!
//! This crate is the Rust port of the original `masker/` Python package and
//! is the integration surface external teams plug into:
//!
//! ```ignore
//! use masker::{default_loop, Tracer};
//!
//! let loop_ = default_loop();
//! let tracer = Tracer::new();
//! let turn = loop_.run_text_turn("My SSN is 123-45-6789", &tracer);
//! println!("safe output: {}", turn.safe_output);
//! ```
//!
//! Public surface is intentionally small:
//! - [`detection`] — `detect(text) -> DetectionResult`
//! - [`policy`]    — `decide(detection, policy_name) -> PolicyDecision`
//! - [`masking`]   — `mask`, `unmask`, `scrub_output`
//! - [`backends`]  — pluggable Gemma backends (`stub`, `gemini`, `cactus`)
//! - [`voice_loop::VoiceLoop`] — orchestrates the full turn

pub mod backends;
pub mod contracts;
pub mod detection;
pub mod masking;
pub mod policy;
pub mod router;
pub mod trace;
pub mod voice_loop;

pub use backends::{default_backend, GemmaBackend, StubBackend};
pub use contracts::{
    DetectionResult, Entity, EntityType, MaskedText, PolicyDecision, PolicyName, Route,
    TraceEvent, TraceStage, TurnResult,
};
pub use masking::MaskMode;
pub use router::{default_router, Router};
pub use trace::Tracer;
pub use voice_loop::{default_loop, VoiceLoop};

/// Convenience facade — convert a raw user input into the safe form your LLM
/// can consume, plus the policy decision driving it. Mirrors `filter_input`
/// in the Python package.
pub fn filter_input(text: &str) -> (MaskedText, PolicyDecision, DetectionResult) {
    let det = detection::detect(text);
    let dec = policy::decide(&det, PolicyName::HipaaBase);
    let masked = masking::mask(text, &det, MaskMode::Placeholder);
    (masked, dec, det)
}

/// Re-mask any sensitive content that leaked back through the LLM output.
pub fn filter_output(model_text: &str, detection: &DetectionResult) -> String {
    masking::scrub_output(model_text, detection)
}
