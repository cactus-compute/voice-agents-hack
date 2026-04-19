//! DEK/KEK envelope encryption for Masker audit logs and token vault.
//!
//! Key hierarchy:
//!   Root KEK (workspace-level, 256-bit AES-GCM key, stored in env / HSM)
//!     └─ Per-use-case DEK (256-bit AES-GCM, wrapped by KEK)
//!          └─ Encrypted payload (audit record, token vault entry)
//!
//! All keys are 256-bit random bytes. Nonces are 96-bit random (GCM standard).
//! Wrapped DEKs are stored as base64(nonce || ciphertext || tag).

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use aes_gcm::aead::{Aead, KeyInit, OsRng};
use aes_gcm::{Aes256Gcm, Key, Nonce};
use base64::{engine::general_purpose::STANDARD as B64, Engine};
use rand::RngCore;
use serde::{Deserialize, Serialize};
use thiserror::Error;
use uuid::Uuid;

pub const KEK_ENV_VAR: &str = "MASKER_KEK";

#[derive(Debug, Error)]
pub enum CryptoError {
    #[error("KEK not configured — set {}", KEK_ENV_VAR)]
    KekMissing,
    #[error("DEK not found: {0}")]
    DekNotFound(String),
    #[error("encryption failed: {0}")]
    Encrypt(String),
    #[error("decryption failed: {0}")]
    Decrypt(String),
    #[error("base64 decode error: {0}")]
    Base64(String),
    #[error("invalid key length")]
    InvalidKeyLength,
}

// ── Raw key material ──────────────────────────────────────────────────────────

/// Generate 32 cryptographically random bytes.
pub fn generate_key_bytes() -> [u8; 32] {
    let mut key = [0u8; 32];
    OsRng.fill_bytes(&mut key);
    key
}

/// Generate a 12-byte random nonce (GCM standard).
fn random_nonce() -> [u8; 12] {
    let mut n = [0u8; 12];
    OsRng.fill_bytes(&mut n);
    n
}

// ── Low-level AES-256-GCM ─────────────────────────────────────────────────────

fn aes_encrypt(key_bytes: &[u8; 32], plaintext: &[u8]) -> Result<Vec<u8>, CryptoError> {
    let key = Key::<Aes256Gcm>::from_slice(key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce_bytes = random_nonce();
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ciphertext = cipher
        .encrypt(nonce, plaintext)
        .map_err(|e| CryptoError::Encrypt(e.to_string()))?;
    // Output: nonce(12) || ciphertext+tag
    let mut out = Vec::with_capacity(12 + ciphertext.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ciphertext);
    Ok(out)
}

fn aes_decrypt(key_bytes: &[u8; 32], blob: &[u8]) -> Result<Vec<u8>, CryptoError> {
    if blob.len() < 12 {
        return Err(CryptoError::Decrypt("blob too short".into()));
    }
    let (nonce_bytes, ciphertext) = blob.split_at(12);
    let key = Key::<Aes256Gcm>::from_slice(key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(nonce_bytes);
    cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| CryptoError::Decrypt(e.to_string()))
}

// ── KEK ───────────────────────────────────────────────────────────────────────

/// Workspace-level Key Encryption Key.
/// Loaded once from `MASKER_KEK` (base64-encoded 32 bytes).
/// In production this would be fetched from an HSM or cloud KMS.
#[derive(Clone)]
pub struct Kek {
    pub id: String,
    key: [u8; 32],
}

impl Kek {
    /// Load from the `MASKER_KEK` environment variable (base64).
    pub fn from_env() -> Result<Self, CryptoError> {
        let raw = std::env::var(KEK_ENV_VAR).map_err(|_| CryptoError::KekMissing)?;
        Self::from_base64(&raw)
    }

    /// Parse a base64-encoded 32-byte key.
    pub fn from_base64(b64: &str) -> Result<Self, CryptoError> {
        let bytes = B64
            .decode(b64.trim())
            .map_err(|e| CryptoError::Base64(e.to_string()))?;
        if bytes.len() != 32 {
            return Err(CryptoError::InvalidKeyLength);
        }
        let mut key = [0u8; 32];
        key.copy_from_slice(&bytes);
        Ok(Self {
            id: format!("kek_{}", &hex::encode(&key[..4])),
            key,
        })
    }

    /// Generate a fresh random KEK (for testing / first-run bootstrap).
    pub fn generate() -> Self {
        let key = generate_key_bytes();
        Self {
            id: format!("kek_{}", &hex::encode(&key[..4])),
            key,
        }
    }

    /// Export as base64 (for storage / display).
    pub fn to_base64(&self) -> String {
        B64.encode(self.key)
    }

    /// Wrap (encrypt) a DEK with this KEK. Returns base64 blob.
    pub fn wrap_dek(&self, dek: &Dek) -> Result<String, CryptoError> {
        let blob = aes_encrypt(&self.key, &dek.key)?;
        Ok(B64.encode(blob))
    }

    /// Unwrap (decrypt) a wrapped DEK blob.
    pub fn unwrap_dek(&self, wrapped_b64: &str, dek_id: &str) -> Result<Dek, CryptoError> {
        let blob = B64
            .decode(wrapped_b64)
            .map_err(|e| CryptoError::Base64(e.to_string()))?;
        let key_bytes = aes_decrypt(&self.key, &blob)?;
        if key_bytes.len() != 32 {
            return Err(CryptoError::InvalidKeyLength);
        }
        let mut key = [0u8; 32];
        key.copy_from_slice(&key_bytes);
        Ok(Dek {
            id: dek_id.to_string(),
            key,
        })
    }
}

// ── DEK ───────────────────────────────────────────────────────────────────────

/// Per-use-case Data Encryption Key.
#[derive(Clone)]
pub struct Dek {
    pub id: String,
    key: [u8; 32],
}

impl Dek {
    /// Generate a fresh random DEK for a use case.
    pub fn generate(use_case: &str) -> Self {
        let key = generate_key_bytes();
        Self {
            id: format!("dek_{}_{}", use_case.replace(' ', "_"), &hex::encode(&key[..4])),
            key,
        }
    }

    /// Encrypt arbitrary bytes. Returns base64 blob.
    pub fn encrypt(&self, plaintext: &[u8]) -> Result<String, CryptoError> {
        let blob = aes_encrypt(&self.key, plaintext)?;
        Ok(B64.encode(blob))
    }

    /// Decrypt a base64 blob produced by `encrypt`.
    pub fn decrypt(&self, ciphertext_b64: &str) -> Result<Vec<u8>, CryptoError> {
        let blob = B64
            .decode(ciphertext_b64)
            .map_err(|e| CryptoError::Base64(e.to_string()))?;
        aes_decrypt(&self.key, &blob)
    }

    /// Encrypt a JSON-serialisable value.
    pub fn encrypt_json<T: Serialize>(&self, value: &T) -> Result<String, CryptoError> {
        let json = serde_json::to_vec(value)
            .map_err(|e| CryptoError::Encrypt(format!("json: {e}")))?;
        self.encrypt(&json)
    }

    /// Decrypt and deserialise a JSON value.
    pub fn decrypt_json<T: for<'de> Deserialize<'de>>(
        &self,
        ciphertext_b64: &str,
    ) -> Result<T, CryptoError> {
        let bytes = self.decrypt(ciphertext_b64)?;
        serde_json::from_slice(&bytes)
            .map_err(|e| CryptoError::Decrypt(format!("json: {e}")))
    }
}

// ── Key store ─────────────────────────────────────────────────────────────────

/// Wrapped DEK record stored in the key store.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct WrappedDek {
    pub dek_id: String,
    pub use_case: String,
    pub kek_id: String,
    /// base64(nonce || ciphertext || tag) of the raw DEK bytes, encrypted by KEK.
    pub wrapped_key: String,
    pub created_at: String,
}

/// In-memory key store. In production this would be backed by a database.
/// Holds the KEK and all wrapped DEKs. DEKs are unwrapped on demand and
/// cached in plaintext for the lifetime of the process.
pub struct KeyStore {
    kek: Kek,
    wrapped: RwLock<HashMap<String, WrappedDek>>,
    /// Plaintext DEK cache (use_case → Dek).
    cache: RwLock<HashMap<String, Dek>>,
}

impl KeyStore {
    pub fn new(kek: Kek) -> Arc<Self> {
        Arc::new(Self {
            kek,
            wrapped: RwLock::new(HashMap::new()),
            cache: RwLock::new(HashMap::new()),
        })
    }

    /// Get or create a DEK for a use case.
    pub fn dek_for(&self, use_case: &str) -> Result<Dek, CryptoError> {
        // Fast path: already in plaintext cache.
        {
            let cache = self.cache.read().unwrap();
            if let Some(dek) = cache.get(use_case) {
                return Ok(dek.clone());
            }
        }

        // Check wrapped store — unwrap if present.
        {
            let wrapped = self.wrapped.read().unwrap();
            if let Some(record) = wrapped.get(use_case) {
                let dek = self.kek.unwrap_dek(&record.wrapped_key, &record.dek_id)?;
                let mut cache = self.cache.write().unwrap();
                cache.insert(use_case.to_string(), dek.clone());
                return Ok(dek);
            }
        }

        // Generate a new DEK, wrap it, store it.
        let dek = Dek::generate(use_case);
        let wrapped_key = self.kek.wrap_dek(&dek)?;
        let record = WrappedDek {
            dek_id: dek.id.clone(),
            use_case: use_case.to_string(),
            kek_id: self.kek.id.clone(),
            wrapped_key,
            created_at: chrono::Utc::now().to_rfc3339(),
        };

        {
            let mut wrapped = self.wrapped.write().unwrap();
            wrapped.insert(use_case.to_string(), record);
        }
        {
            let mut cache = self.cache.write().unwrap();
            cache.insert(use_case.to_string(), dek.clone());
        }

        Ok(dek)
    }

    /// List all wrapped DEK records (for admin / audit export).
    pub fn list_wrapped_deks(&self) -> Vec<WrappedDek> {
        self.wrapped.read().unwrap().values().cloned().collect()
    }

    pub fn kek_id(&self) -> &str {
        &self.kek.id
    }
}

// ── Token vault ───────────────────────────────────────────────────────────────

/// A reversible token entry: maps a stable opaque token to an encrypted
/// original value. The DEK used is the one for the session's use case.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct TokenEntry {
    pub token: String,
    pub entity_type: String,
    pub encrypted_value: String, // DEK-encrypted original
    pub dek_id: String,
    pub created_at: String,
}

/// In-memory token vault. In production backed by a database.
pub struct TokenVault {
    store: RwLock<HashMap<String, TokenEntry>>,
}

impl TokenVault {
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            store: RwLock::new(HashMap::new()),
        })
    }

    /// Store a token → encrypted value mapping. Returns the token.
    pub fn put(
        &self,
        entity_type: &str,
        original_value: &str,
        dek: &Dek,
    ) -> Result<String, CryptoError> {
        let token = format!("tok_{}", Uuid::new_v4().simple());
        let encrypted_value = dek.encrypt(original_value.as_bytes())?;
        let entry = TokenEntry {
            token: token.clone(),
            entity_type: entity_type.to_string(),
            encrypted_value,
            dek_id: dek.id.clone(),
            created_at: chrono::Utc::now().to_rfc3339(),
        };
        self.store.write().unwrap().insert(token.clone(), entry);
        Ok(token)
    }

    /// Rehydrate a token back to its original value using the DEK.
    pub fn get(&self, token: &str, dek: &Dek) -> Result<String, CryptoError> {
        let store = self.store.read().unwrap();
        let entry = store
            .get(token)
            .ok_or_else(|| CryptoError::DekNotFound(token.to_string()))?;
        let bytes = dek.decrypt(&entry.encrypted_value)?;
        String::from_utf8(bytes).map_err(|e| CryptoError::Decrypt(format!("utf8: {e}")))
    }

    /// List all token entries (for admin export — values remain encrypted).
    pub fn list(&self) -> Vec<TokenEntry> {
        self.store.read().unwrap().values().cloned().collect()
    }
}

impl Default for TokenVault {
    fn default() -> Self {
        Self {
            store: RwLock::new(HashMap::new()),
        }
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn kek_wrap_unwrap_roundtrip() {
        let kek = Kek::generate();
        let dek = Dek::generate("healthcare");
        let wrapped = kek.wrap_dek(&dek).unwrap();
        let recovered = kek.unwrap_dek(&wrapped, &dek.id).unwrap();
        // Encrypt with original, decrypt with recovered — must match.
        let ct = dek.encrypt(b"patient-data").unwrap();
        let pt = recovered.decrypt(&ct).unwrap();
        assert_eq!(pt, b"patient-data");
    }

    #[test]
    fn kek_base64_roundtrip() {
        let kek = Kek::generate();
        let b64 = kek.to_base64();
        let kek2 = Kek::from_base64(&b64).unwrap();
        assert_eq!(kek.id, kek2.id);
    }

    #[test]
    fn dek_encrypt_decrypt_json() {
        let dek = Dek::generate("hr");
        let value = serde_json::json!({"ssn": "123-45-6789", "name": "Alice"});
        let ct = dek.encrypt_json(&value).unwrap();
        let recovered: serde_json::Value = dek.decrypt_json(&ct).unwrap();
        assert_eq!(recovered["ssn"], "123-45-6789");
    }

    #[test]
    fn key_store_dek_for_same_use_case() {
        let kek = Kek::generate();
        let store = KeyStore::new(kek);
        let dek1 = store.dek_for("healthcare").unwrap();
        let dek2 = store.dek_for("healthcare").unwrap();
        // Same use case → same DEK id.
        assert_eq!(dek1.id, dek2.id);
        // Different use case → different DEK.
        let dek3 = store.dek_for("hr").unwrap();
        assert_ne!(dek1.id, dek3.id);
    }

    #[test]
    fn token_vault_put_get_roundtrip() {
        let kek = Kek::generate();
        let store = KeyStore::new(kek);
        let dek = store.dek_for("healthcare").unwrap();
        let vault = TokenVault::new();
        let token = vault.put("ssn", "482-55-1234", &dek).unwrap();
        assert!(token.starts_with("tok_"));
        let recovered = vault.get(&token, &dek).unwrap();
        assert_eq!(recovered, "482-55-1234");
    }

    #[test]
    fn token_vault_wrong_token_errors() {
        let kek = Kek::generate();
        let store = KeyStore::new(kek);
        let dek = store.dek_for("healthcare").unwrap();
        let vault = TokenVault::new();
        assert!(vault.get("tok_nonexistent", &dek).is_err());
    }
}
