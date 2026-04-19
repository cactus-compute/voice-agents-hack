//! Encrypted audit logger.
//!
//! Every processed audio chunk produces an `AuditRecord`. The record is:
//!   1. Serialised to JSON
//!   2. Encrypted with the session's DEK (AES-256-GCM)
//!   3. Wrapped in an `AuditEntry` that carries the DEK id and KEK id
//!      (so the admin can locate the right keys to decrypt)
//!   4. Emitted to an `AdminSink` (in-memory by default; file / HTTP in prod)
//!
//! The admin dashboard receives `AuditEntry` records. It can decrypt them
//! only if it has access to the KEK (which lives in the HSM / env).

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use crate::audio_pipeline::AudioChunkResult;
use crate::client_registry::ClientConfig;
use crate::crypto::{CryptoError, Dek, KeyStore};

// ── Audit record (plaintext) ──────────────────────────────────────────────────

/// Full plaintext record for one processed audio chunk.
/// This is what gets encrypted and stored.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditRecord {
    pub session_id: String,
    pub chunk_seq: u64,
    pub timestamp: String,
    /// Client API key prefix (never the full key).
    pub client_key_prefix: String,
    pub client_label: String,
    pub use_case: String,
    pub environment: String,
    pub policy_applied: String,
    pub route: String,
    /// SHA-256 hash of the raw transcript (never stored in plaintext).
    pub raw_transcript_hash: String,
    /// The masked transcript (safe to store — PII already removed).
    pub masked_transcript: String,
    /// Number of entities detected.
    pub entity_count: usize,
    /// Entity types detected (not values).
    pub entity_types: Vec<String>,
    /// Processing time in milliseconds.
    pub processing_ms: u64,
    /// DEK id used for vault tokens in this chunk.
    pub dek_id: String,
    /// KEK id that wraps the DEK.
    pub kek_id: String,
    /// Trace events (stage + message, no raw PII).
    pub trace: Vec<TraceEntry>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TraceEntry {
    pub stage: String,
    pub message: String,
    pub elapsed_ms: f64,
}

// ── Audit entry (encrypted, stored/transmitted) ───────────────────────────────

/// Envelope stored in the audit log. The `encrypted_record` field contains
/// the DEK-encrypted JSON of `AuditRecord`. Only the metadata fields are
/// in plaintext so the admin can index/search without decrypting.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AuditEntry {
    /// Unique entry id.
    pub id: String,
    pub session_id: String,
    pub chunk_seq: u64,
    pub timestamp: String,
    pub client_key_prefix: String,
    pub use_case: String,
    pub environment: String,
    pub policy_applied: String,
    pub route: String,
    pub entity_count: usize,
    pub processing_ms: u64,
    /// DEK id — admin uses this to look up the wrapped DEK.
    pub dek_id: String,
    /// KEK id — admin uses this to locate the KEK.
    pub kek_id: String,
    /// base64(nonce || AES-256-GCM(AuditRecord JSON)).
    pub encrypted_record: String,
}

// ── Admin sink trait ──────────────────────────────────────────────────────────

/// Destination for audit entries. Implement this to send to a database,
/// HTTP endpoint, or file.
pub trait AdminSink: Send + Sync {
    fn emit(&self, entry: AuditEntry) -> anyhow::Result<()>;
}

/// In-memory sink — stores all entries in a Vec. Used for testing and demo.
pub struct InMemorySink {
    entries: Mutex<Vec<AuditEntry>>,
}

impl InMemorySink {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            entries: Mutex::new(Vec::new()),
        })
    }

    pub fn entries(&self) -> Vec<AuditEntry> {
        self.entries.lock().unwrap().clone()
    }

    pub fn len(&self) -> usize {
        self.entries.lock().unwrap().len()
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

impl AdminSink for InMemorySink {
    fn emit(&self, entry: AuditEntry) -> anyhow::Result<()> {
        self.entries.lock().unwrap().push(entry);
        Ok(())
    }
}

impl Default for InMemorySink {
    fn default() -> Self {
        Self {
            entries: Mutex::new(Vec::new()),
        }
    }
}

/// Stdout sink — pretty-prints entries as JSON lines. Useful for CLI demo.
pub struct StdoutSink;

impl AdminSink for StdoutSink {
    fn emit(&self, entry: AuditEntry) -> anyhow::Result<()> {
        println!("{}", serde_json::to_string(&entry)?);
        Ok(())
    }
}

// ── Logger ────────────────────────────────────────────────────────────────────

pub struct AuditLogger {
    key_store: Arc<KeyStore>,
    sink: Arc<dyn AdminSink>,
}

impl AuditLogger {
    pub fn new(key_store: Arc<KeyStore>, sink: Arc<dyn AdminSink>) -> Self {
        Self { key_store, sink }
    }

    /// Build, encrypt, and emit an audit entry for a processed chunk.
    pub fn log(
        &self,
        session_id: &str,
        client: &ClientConfig,
        result: &AudioChunkResult,
    ) -> anyhow::Result<()> {
        let dek = self
            .key_store
            .dek_for(&client.use_case)
            .map_err(|e| anyhow::anyhow!("audit dek: {e}"))?;

        let record = build_record(session_id, client, result, &dek, self.key_store.kek_id());
        let entry = encrypt_record(&record, &dek, self.key_store.kek_id())
            .map_err(|e| anyhow::anyhow!("audit encrypt: {e}"))?;

        self.sink.emit(entry)?;
        Ok(())
    }

    /// Decrypt an audit entry back to its plaintext record.
    /// Requires the DEK for the entry's use case.
    pub fn decrypt_entry(
        &self,
        entry: &AuditEntry,
        use_case: &str,
    ) -> anyhow::Result<AuditRecord> {
        let dek = self
            .key_store
            .dek_for(use_case)
            .map_err(|e| anyhow::anyhow!("decrypt dek: {e}"))?;
        dek.decrypt_json(&entry.encrypted_record)
            .map_err(|e| anyhow::anyhow!("decrypt record: {e}"))
    }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

fn hash_transcript(text: &str) -> String {
    use sha2::{Digest, Sha256};
    let mut h = Sha256::new();
    h.update(text.as_bytes());
    hex::encode(h.finalize())
}

fn build_record(
    session_id: &str,
    client: &ClientConfig,
    result: &AudioChunkResult,
    dek: &Dek,
    kek_id: &str,
) -> AuditRecord {
    AuditRecord {
        session_id: session_id.to_string(),
        chunk_seq: result.seq,
        timestamp: chrono::Utc::now().to_rfc3339(),
        client_key_prefix: client.key_prefix.clone(),
        client_label: client.label.clone(),
        use_case: client.use_case.clone(),
        environment: client.environment.to_string(),
        policy_applied: client.policy.as_str().to_string(),
        route: format!("{:?}", result.route).to_lowercase(),
        raw_transcript_hash: hash_transcript(&result.raw_transcript),
        masked_transcript: result.masked_transcript.clone(),
        entity_count: result.detection.entities.len(),
        entity_types: result
            .detection
            .entities
            .iter()
            .map(|e| e.kind.as_str().to_string())
            .collect(),
        processing_ms: result.processing_ms,
        dek_id: dek.id.clone(),
        kek_id: kek_id.to_string(),
        trace: result
            .trace
            .iter()
            .map(|e| TraceEntry {
                stage: format!("{:?}", e.stage).to_lowercase(),
                message: e.message.clone(),
                elapsed_ms: e.elapsed_ms,
            })
            .collect(),
    }
}

fn encrypt_record(
    record: &AuditRecord,
    dek: &Dek,
    kek_id: &str,
) -> Result<AuditEntry, CryptoError> {
    let encrypted_record = dek.encrypt_json(record)?;
    Ok(AuditEntry {
        id: format!("aud_{}", uuid::Uuid::new_v4().simple()),
        session_id: record.session_id.clone(),
        chunk_seq: record.chunk_seq,
        timestamp: record.timestamp.clone(),
        client_key_prefix: record.client_key_prefix.clone(),
        use_case: record.use_case.clone(),
        environment: record.environment.clone(),
        policy_applied: record.policy_applied.clone(),
        route: record.route.clone(),
        entity_count: record.entity_count,
        processing_ms: record.processing_ms,
        dek_id: record.dek_id.clone(),
        kek_id: kek_id.to_string(),
        encrypted_record,
    })
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::audio_pipeline::{process_chunk, AudioChunk, PipelineConfig, StubStt, StubTts};
    use crate::client_registry::ClientRegistry;
    use crate::crypto::{Kek, KeyStore, TokenVault};

    fn setup() -> (PipelineConfig, Arc<KeyStore>, Arc<InMemorySink>) {
        let kek = Kek::generate();
        let key_store = KeyStore::new(kek);
        let sink = InMemorySink::new();
        let cfg = PipelineConfig {
            stt: Arc::new(StubStt),
            tts: Arc::new(StubTts),
            key_store: key_store.clone(),
            token_vault: TokenVault::new(),
        };
        (cfg, key_store, sink)
    }

    #[test]
    fn audit_entry_is_emitted_per_chunk() {
        let (cfg, key_store, sink) = setup();
        let logger = AuditLogger::new(key_store, sink.clone());
        let client = ClientRegistry::with_defaults().resolve(None);
        let chunk = AudioChunk {
            seq: 0,
            data: b"What are the clinic hours?".to_vec(),
            sample_rate: 16_000,
            duration_ms: 500,
        };
        let result = process_chunk(&chunk, &client, &cfg).unwrap();
        logger.log("ses_test_001", &client, &result).unwrap();
        assert_eq!(sink.len(), 1);
    }

    #[test]
    fn audit_entry_does_not_contain_raw_transcript() {
        let (cfg, key_store, sink) = setup();
        let logger = AuditLogger::new(key_store, sink.clone());
        let client = ClientRegistry::with_defaults().resolve(None);
        let chunk = AudioChunk {
            seq: 0,
            data: b"My SSN is 482-55-1234.".to_vec(),
            sample_rate: 16_000,
            duration_ms: 500,
        };
        let result = process_chunk(&chunk, &client, &cfg).unwrap();
        logger.log("ses_test_002", &client, &result).unwrap();

        let entry = sink.entries().into_iter().next().unwrap();
        // The plaintext entry must not contain the raw SSN.
        let entry_json = serde_json::to_string(&entry).unwrap();
        assert!(!entry_json.contains("482-55-1234"), "raw SSN leaked into audit entry");
        // The encrypted_record field must be non-empty base64.
        assert!(!entry.encrypted_record.is_empty());
    }

    #[test]
    fn audit_entry_decrypt_roundtrip() {
        let (cfg, key_store, sink) = setup();
        let logger = AuditLogger::new(key_store.clone(), sink.clone());
        let client = ClientRegistry::with_defaults().resolve(None);
        // Use an email address — reliably detected and masked.
        let chunk = AudioChunk {
            seq: 1,
            data: b"Please email sarah@example.com about the appointment.".to_vec(),
            sample_rate: 16_000,
            duration_ms: 500,
        };
        let result = process_chunk(&chunk, &client, &cfg).unwrap();
        logger.log("ses_test_003", &client, &result).unwrap();

        let entry = sink.entries().into_iter().next().unwrap();
        let record = logger.decrypt_entry(&entry, &client.use_case).unwrap();

        assert_eq!(record.session_id, "ses_test_003");
        assert_eq!(record.chunk_seq, 1);
        assert_eq!(record.policy_applied, "hipaa_base");
        // Masked transcript must not contain the original email.
        assert!(!record.masked_transcript.contains("sarah@example.com"));
    }

    #[test]
    fn audit_entry_metadata_is_plaintext_indexable() {
        let (cfg, key_store, sink) = setup();
        let logger = AuditLogger::new(key_store, sink.clone());
        let client = ClientRegistry::with_defaults().resolve(None);
        let chunk = AudioChunk {
            seq: 2,
            data: b"My SSN is 482-55-1234.".to_vec(),
            sample_rate: 16_000,
            duration_ms: 500,
        };
        let result = process_chunk(&chunk, &client, &cfg).unwrap();
        logger.log("ses_test_004", &client, &result).unwrap();

        let entry = sink.entries().into_iter().next().unwrap();
        // These fields must be readable without decryption.
        assert_eq!(entry.session_id, "ses_test_004");
        assert_eq!(entry.policy_applied, "hipaa_base");
        assert_eq!(entry.entity_count, 1);
        assert!(!entry.dek_id.is_empty());
        assert!(!entry.kek_id.is_empty());
    }
}
