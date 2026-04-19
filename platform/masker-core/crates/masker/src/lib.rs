//! # Masker (Rust)
//!
//! On-device PII/PHI middleware for voice agents. Sits in front of any LLM
//! call, classifies the input with a small Gemma-class model, decides per a
//! HIPAA-first policy whether the turn must stay local / be masked / can pass
//! through verbatim, and re-scans the model's output for leaked secrets.
//!
//! This crate is the canonical privacy engine. The Python package in
//! `platform/masker-library/masker/` is the easiest adoption surface for
//! external teams, and delegates to this core when the compiled `masker`
//! binary is available:
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

pub mod audio_pipeline;
pub mod audit_logger;
pub mod backends;
#[cfg(feature = "cactus")]
pub mod cactus_sdk;
pub mod client_registry;
pub mod contracts;
pub mod crypto;
pub mod detection;
pub mod masking;
pub mod policy;
pub mod router;
pub mod trace;
pub mod voice_loop;

#[cfg(feature = "cactus")]
pub use audio_pipeline::CactusSttBackend;
pub use audio_pipeline::{
    AudioChunk, AudioChunkResult, PipelineConfig, SttBackend, StubStt, StubTts, TtsBackend,
};
pub use audit_logger::{AdminSink, AuditEntry, AuditLogger, AuditRecord, InMemorySink, StdoutSink};
pub use backends::{default_backend, GemmaBackend, StubBackend};
pub use client_registry::{ClientConfig, ClientRegistry, Environment};
pub use contracts::{
    DetectionResult, Entity, EntityType, MaskedText, PolicyDecision, PolicyName, Route, TraceEvent,
    TraceStage, TurnResult,
};
pub use crypto::{Dek, Kek, KeyStore, TokenVault};
#[cfg(feature = "cactus")]
pub use detection::CactusFallbackDetector;
pub use detection::{Detector, RegexDetector};
pub use masking::MaskMode;
pub use router::{default_router, Router};
pub use trace::Tracer;
pub use voice_loop::{default_loop, VoiceLoop};

/// Convenience facade — convert a raw user input into the safe form your LLM
/// can consume, plus the policy decision driving it. Mirrors `filter_input`
/// in the Python library package.
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

// ── StreamingPipeline ─────────────────────────────────────────────────────────

use std::sync::Arc;

/// High-level streaming pipeline that ties together:
///   - Client key registry (API key → policy)
///   - DEK/KEK key store (per-use-case encryption)
///   - Token vault (reversible SSN/insurance_id tokenization)
///   - Audio pipeline (STT → detect → policy → mask → TTS)
///   - Encrypted audit logger (AuditRecord → DEK-encrypted → AdminSink)
///
/// Construct once per process; call `process` for each audio chunk.
///
/// ```no_run
/// use masker::{StreamingPipeline, AudioChunk};
///
/// let pipeline = StreamingPipeline::new_with_defaults();
/// let chunk = AudioChunk {
///     seq: 0,
///     data: b"My SSN is 482-55-1234.".to_vec(),
///     source_path: None,
///     sample_rate: 16_000,
///     duration_ms: 500,
/// };
/// let result = pipeline.process("ses_001", None, &chunk).unwrap();
/// println!("route: {:?}", result.route);
/// ```
pub struct StreamingPipeline {
    registry: Arc<ClientRegistry>,
    pipeline_cfg: audio_pipeline::PipelineConfig,
    logger: AuditLogger,
}

impl StreamingPipeline {
    /// Create a pipeline with stub STT/TTS, a fresh KEK, and an in-memory
    /// audit sink. Suitable for testing and CLI demo.
    pub fn new_with_defaults() -> Self {
        let kek = Kek::generate();
        let key_store = KeyStore::new(kek);
        let token_vault = TokenVault::new();
        let sink = InMemorySink::new();
        let logger = AuditLogger::new(key_store.clone(), sink);
        let pipeline_cfg = audio_pipeline::PipelineConfig {
            stt: Arc::new(StubStt),
            tts: Arc::new(StubTts),
            detector: Arc::new(detection::RegexDetector),
            key_store,
            token_vault,
        };
        Self {
            registry: Arc::new(ClientRegistry::with_defaults()),
            pipeline_cfg,
            logger,
        }
    }

    /// Create a pipeline with a custom STT/TTS backend and admin sink.
    pub fn new(
        stt: Arc<dyn SttBackend>,
        tts: Arc<dyn TtsBackend>,
        detector: Arc<dyn detection::Detector>,
        kek: Kek,
        sink: Arc<dyn AdminSink>,
    ) -> Self {
        let key_store = KeyStore::new(kek);
        let token_vault = TokenVault::new();
        let logger = AuditLogger::new(key_store.clone(), sink);
        let pipeline_cfg = audio_pipeline::PipelineConfig {
            stt,
            tts,
            detector,
            key_store,
            token_vault,
        };
        Self {
            registry: Arc::new(ClientRegistry::with_defaults()),
            pipeline_cfg,
            logger,
        }
    }

    #[cfg(feature = "cactus")]
    pub fn new_with_cactus_defaults() -> anyhow::Result<Self> {
        let kek = Kek::generate();
        let key_store = KeyStore::new(kek);
        let token_vault = TokenVault::new();
        let sink = InMemorySink::new();
        let logger = AuditLogger::new(key_store.clone(), sink);
        let detector: Arc<dyn detection::Detector> =
            match detection::CactusFallbackDetector::from_env() {
                Ok(detector) => Arc::new(detector),
                Err(_) => Arc::new(detection::RegexDetector),
            };
        let pipeline_cfg = audio_pipeline::PipelineConfig {
            stt: Arc::new(audio_pipeline::CactusSttBackend::from_env()?),
            tts: Arc::new(StubTts),
            detector,
            key_store,
            token_vault,
        };

        Ok(Self {
            registry: Arc::new(ClientRegistry::with_defaults()),
            pipeline_cfg,
            logger,
        })
    }

    /// Process one audio chunk.
    ///
    /// - `session_id`: caller-assigned session identifier (for audit grouping)
    /// - `api_key`: optional client API key; falls back to HIPAA-base default
    /// - `chunk`: the audio chunk to process
    ///
    /// Returns the `AudioChunkResult` and emits an encrypted `AuditEntry` to
    /// the configured `AdminSink`.
    pub fn process(
        &self,
        session_id: &str,
        api_key: Option<&str>,
        chunk: &AudioChunk,
    ) -> anyhow::Result<AudioChunkResult> {
        let client = self.registry.resolve(api_key);
        let result = audio_pipeline::process_chunk(chunk, &client, &self.pipeline_cfg)?;
        self.logger.log(session_id, &client, &result)?;
        Ok(result)
    }

    /// Access the underlying client registry (e.g. to register new keys).
    pub fn registry(&self) -> &ClientRegistry {
        &self.registry
    }
}
