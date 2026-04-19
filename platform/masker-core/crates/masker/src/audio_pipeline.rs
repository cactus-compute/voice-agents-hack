//! Streaming audio pipeline.
//!
//! Pipeline stages per audio chunk:
//!
//!   AudioChunk
//!     → SttBackend::transcribe()   — raw bytes → transcript text
//!     → detection::scan()          — detect PII/PHI entities
//!     → policy::decide()           — apply client policy → route decision
//!     → masking::mask()            — mask/redact entities; tokenize via vault
//!     → TtsBackend::synthesise()   — masked text → audio bytes
//!     → AudioChunkResult           — emitted to caller + audit logger
//!
//! STT and TTS are trait objects so real Cactus backends can be plugged in
//! without changing the pipeline logic.

use std::sync::Arc;
use std::time::Instant;

use serde::{Deserialize, Serialize};

use crate::client_registry::ClientConfig;
use crate::contracts::{
    DetectionResult, MaskedText, PolicyDecision, Route, TraceEvent, TraceStage,
};
use crate::crypto::{KeyStore, TokenVault};
use crate::{detection, masking, policy};

// ── Audio types ───────────────────────────────────────────────────────────────

/// A raw audio chunk from the microphone or network stream.
/// `data` is raw PCM bytes (16-bit LE, 16 kHz mono) or any opaque audio blob
/// when using an external STT service.
#[derive(Debug, Clone)]
pub struct AudioChunk {
    /// Monotonically increasing sequence number within a session.
    pub seq: u64,
    /// Raw audio bytes (or UTF-8 text bytes when using StubStt).
    pub data: Vec<u8>,
    /// Sample rate in Hz (informational).
    pub sample_rate: u32,
    /// Duration in milliseconds (informational).
    pub duration_ms: u32,
}

/// The result of processing one audio chunk through the full pipeline.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AudioChunkResult {
    pub seq: u64,
    /// Transcript as received from STT (before masking).
    pub raw_transcript: String,
    /// Transcript after masking (what was sent to TTS / model).
    pub masked_transcript: String,
    /// Detection result.
    pub detection: DetectionResult,
    /// Policy decision.
    pub policy: PolicyDecision,
    /// Masking result (masked text + token map).
    pub masked: MaskedText,
    /// Route taken.
    pub route: Route,
    /// Synthesised audio bytes (masked text → speech).
    /// Empty when route is LocalOnly.
    #[serde(skip)]
    pub audio_out: Vec<u8>,
    /// Processing time in milliseconds.
    pub processing_ms: u64,
    /// Trace events for this chunk.
    pub trace: Vec<TraceEvent>,
}

// ── STT / TTS traits ──────────────────────────────────────────────────────────

/// Speech-to-text backend.
pub trait SttBackend: Send + Sync {
    fn transcribe(&self, audio: &[u8]) -> anyhow::Result<String>;
}

/// Text-to-speech backend.
pub trait TtsBackend: Send + Sync {
    fn synthesise(&self, text: &str) -> anyhow::Result<Vec<u8>>;
}

// ── Stub backends ─────────────────────────────────────────────────────────────

/// Stub STT: interprets audio bytes as UTF-8 text directly.
/// Used for testing and demo mode where "audio" is actually text.
pub struct StubStt;
impl SttBackend for StubStt {
    fn transcribe(&self, audio: &[u8]) -> anyhow::Result<String> {
        Ok(String::from_utf8_lossy(audio).into_owned())
    }
}

/// Stub TTS: returns the text as UTF-8 bytes.
pub struct StubTts;
impl TtsBackend for StubTts {
    fn synthesise(&self, text: &str) -> anyhow::Result<Vec<u8>> {
        Ok(text.as_bytes().to_vec())
    }
}

// ── Pipeline config ───────────────────────────────────────────────────────────

pub struct PipelineConfig {
    pub stt: Arc<dyn SttBackend>,
    pub tts: Arc<dyn TtsBackend>,
    pub key_store: Arc<KeyStore>,
    pub token_vault: Arc<TokenVault>,
}

// ── Trace helper ──────────────────────────────────────────────────────────────

fn event(stage: TraceStage, message: impl Into<String>, elapsed_ms: f64) -> TraceEvent {
    TraceEvent {
        stage,
        message: message.into(),
        elapsed_ms,
        payload: Default::default(),
    }
}

// ── Core processing ───────────────────────────────────────────────────────────

/// Process a single audio chunk through the full pipeline.
pub fn process_chunk(
    chunk: &AudioChunk,
    client: &ClientConfig,
    config: &PipelineConfig,
) -> anyhow::Result<AudioChunkResult> {
    let t0 = Instant::now();
    let mut trace: Vec<TraceEvent> = Vec::new();

    // ── Stage 1: STT ─────────────────────────────────────────────────────────
    let raw_transcript = config.stt.transcribe(&chunk.data)?;
    trace.push(event(
        TraceStage::Stt,
        format!(
            "Transcribed {} bytes → {} chars",
            chunk.data.len(),
            raw_transcript.len()
        ),
        t0.elapsed().as_secs_f64() * 1000.0,
    ));

    // ── Stage 2: Detection ────────────────────────────────────────────────────
    let detection = detection::detect(&raw_transcript);
    trace.push(event(
        TraceStage::Detection,
        format!(
            "Detected {} entities: [{}]",
            detection.entities.len(),
            detection
                .entities
                .iter()
                .map(|e| e.kind.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ),
        t0.elapsed().as_secs_f64() * 1000.0,
    ));

    // ── Stage 3: Policy ───────────────────────────────────────────────────────
    let policy_decision = policy::decide(&detection, client.policy);
    trace.push(event(
        TraceStage::Policy,
        format!(
            "Policy={} route={:?}: {}",
            client.policy.as_str(),
            policy_decision.route,
            policy_decision.rationale
        ),
        t0.elapsed().as_secs_f64() * 1000.0,
    ));

    let route = policy_decision.route;

    // ── Stage 4: Masking ──────────────────────────────────────────────────────
    // Use placeholder mode for masked-send (readable by model).
    // For tokenize-capable entities, store encrypted originals in the vault.
    let mut masked = masking::mask(&raw_transcript, &detection, masking::MaskMode::Placeholder);

    // Vault tokenization: for SSN and insurance_id, replace the placeholder
    // with a stable vault token so the original can be rehydrated later.
    let dek = config.key_store.dek_for(&client.use_case)
        .map_err(|e| anyhow::anyhow!("key store: {e}"))?;

    for entity in &detection.entities {
        use crate::contracts::EntityType;
        if matches!(entity.kind, EntityType::Ssn | EntityType::InsuranceId) {
            let placeholder = format!("[MASKED:{}]", entity.kind.as_str());
            if masked.text.contains(&placeholder) {
                let token = config
                    .token_vault
                    .put(entity.kind.as_str(), &entity.value, &dek)
                    .map_err(|e| anyhow::anyhow!("vault: {e}"))?;
                masked.text = masked.text.replacen(&placeholder, &token, 1);
                masked.token_map.insert(token, entity.value.clone());
            }
        }
    }

    let masked_transcript = masked.text.clone();
    trace.push(event(
        TraceStage::Masking,
        format!(
            "Masked {} spans; {} vault tokens (dek={})",
            masked.token_map.len(),
            detection.entities.iter().filter(|e| {
                use crate::contracts::EntityType;
                matches!(e.kind, EntityType::Ssn | EntityType::InsuranceId)
            }).count(),
            dek.id
        ),
        t0.elapsed().as_secs_f64() * 1000.0,
    ));

    // ── Stage 5: TTS ──────────────────────────────────────────────────────────
    let audio_out = match route {
        Route::LocalOnly => {
            trace.push(event(
                TraceStage::Routing,
                "local-only: TTS skipped, audio not forwarded",
                t0.elapsed().as_secs_f64() * 1000.0,
            ));
            Vec::new()
        }
        Route::MaskedSend => {
            let audio = config.tts.synthesise(&masked_transcript)?;
            trace.push(event(
                TraceStage::Routing,
                format!(
                    "masked-send: synthesised {} bytes from masked transcript",
                    audio.len()
                ),
                t0.elapsed().as_secs_f64() * 1000.0,
            ));
            audio
        }
        Route::SafeToSend => {
            let audio = config.tts.synthesise(&raw_transcript)?;
            trace.push(event(
                TraceStage::Routing,
                format!(
                    "safe-to-send: synthesised {} bytes from original transcript",
                    audio.len()
                ),
                t0.elapsed().as_secs_f64() * 1000.0,
            ));
            audio
        }
    };

    Ok(AudioChunkResult {
        seq: chunk.seq,
        raw_transcript,
        masked_transcript,
        detection,
        policy: policy_decision,
        masked,
        route,
        audio_out,
        processing_ms: t0.elapsed().as_millis() as u64,
        trace,
    })
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::client_registry::ClientRegistry;
    use crate::crypto::{Kek, KeyStore, TokenVault};

    fn make_config() -> PipelineConfig {
        let kek = Kek::generate();
        PipelineConfig {
            stt: Arc::new(StubStt),
            tts: Arc::new(StubTts),
            key_store: KeyStore::new(kek),
            token_vault: TokenVault::new(),
        }
    }

    fn chunk(seq: u64, text: &str) -> AudioChunk {
        AudioChunk {
            seq,
            data: text.as_bytes().to_vec(),
            sample_rate: 16_000,
            duration_ms: 500,
        }
    }

    #[test]
    fn safe_query_passes_through() {
        let cfg = make_config();
        let client = ClientRegistry::with_defaults().resolve(None);
        let result = process_chunk(&chunk(0, "What are the clinic hours on Saturday?"), &client, &cfg).unwrap();
        assert_eq!(result.route, Route::SafeToSend);
        assert_eq!(result.detection.entities.len(), 0);
        assert_eq!(result.audio_out, b"What are the clinic hours on Saturday?");
    }

    #[test]
    fn ssn_triggers_local_only() {
        let cfg = make_config();
        let client = ClientRegistry::with_defaults().resolve(None);
        let result = process_chunk(&chunk(1, "My SSN is 482-55-1234."), &client, &cfg).unwrap();
        assert_eq!(result.route, Route::LocalOnly);
        assert!(result.audio_out.is_empty());
    }

    #[test]
    fn email_triggers_masked_send_and_audio_is_non_empty() {
        let cfg = make_config();
        let client = ClientRegistry::with_defaults().resolve(None);
        // Email is reliably detected as a sensitive entity → masked-send.
        let result = process_chunk(&chunk(2, "Please email sarah@example.com about the appointment."), &client, &cfg).unwrap();
        assert_eq!(result.route, Route::MaskedSend);
        assert!(!result.masked_transcript.contains("sarah@example.com"));
        assert!(!result.audio_out.is_empty());
    }

    #[test]
    fn clinical_key_uses_clinical_policy() {
        let cfg = make_config();
        let client = ClientRegistry::with_defaults().resolve(Some("msk_live_a7Yz_clinical_prod"));
        assert_eq!(client.policy, crate::contracts::PolicyName::HipaaClinical);
        let result = process_chunk(&chunk(3, "Patient SSN 319-44-8821 has chest pain."), &client, &cfg).unwrap();
        assert_eq!(result.route, Route::LocalOnly);
    }

    #[test]
    fn all_trace_stages_present() {
        let cfg = make_config();
        let client = ClientRegistry::with_defaults().resolve(None);
        let result = process_chunk(&chunk(4, "Call John at 555-867-5309."), &client, &cfg).unwrap();
        let stages: Vec<_> = result.trace.iter().map(|e| e.stage).collect();
        assert!(stages.contains(&TraceStage::Stt));
        assert!(stages.contains(&TraceStage::Detection));
        assert!(stages.contains(&TraceStage::Policy));
        assert!(stages.contains(&TraceStage::Masking));
        assert!(stages.contains(&TraceStage::Routing));
    }

    #[test]
    fn ssn_is_vault_tokenized() {
        let cfg = make_config();
        let client = ClientRegistry::with_defaults().resolve(None);
        // SSN triggers local-only so no audio, but masking still runs.
        let result = process_chunk(&chunk(5, "My SSN is 482-55-1234."), &client, &cfg).unwrap();
        // The masked transcript should contain a vault token, not the raw SSN.
        assert!(!result.masked_transcript.contains("482-55-1234"));
    }

    #[test]
    fn processing_time_under_one_second() {
        let cfg = make_config();
        let client = ClientRegistry::with_defaults().resolve(None);
        let result = process_chunk(&chunk(6, "Hello world."), &client, &cfg).unwrap();
        assert!(result.processing_ms < 1_000);
    }
}
