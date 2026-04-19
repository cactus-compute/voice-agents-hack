//! Client key registry — maps API keys to policy configurations.
//!
//! Each client is identified by an opaque API key (e.g. `msk_live_k9Xp…`).
//! The registry resolves a key to a `ClientConfig` which carries:
//!   - the policy to apply (default: HIPAA-base)
//!   - the use-case name (used to select the right DEK)
//!   - the environment (prod / staging / dev)
//!
//! In production this would be backed by a database. Here we use an in-memory
//! store seeded with sensible defaults, plus a fallback for unknown keys.

use std::collections::HashMap;
use std::sync::RwLock;

use serde::{Deserialize, Serialize};

use crate::contracts::PolicyName;

// ── Client config ─────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ClientConfig {
    /// Opaque API key prefix (first 12 chars, for logging — never the full key).
    pub key_prefix: String,
    /// Human-readable label.
    pub label: String,
    /// Policy to apply to every session from this client.
    pub policy: PolicyName,
    /// Use-case name — used to select the DEK from the key store.
    pub use_case: String,
    /// Environment tag.
    pub environment: Environment,
    /// Whether this key is active.
    pub active: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Environment {
    Production,
    Staging,
    Development,
}

impl std::fmt::Display for Environment {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Production => write!(f, "production"),
            Self::Staging => write!(f, "staging"),
            Self::Development => write!(f, "development"),
        }
    }
}

// ── Registry ──────────────────────────────────────────────────────────────────

/// Default policy applied when no API key is provided or the key is unknown.
pub const DEFAULT_POLICY: PolicyName = PolicyName::HipaaBase;
pub const DEFAULT_USE_CASE: &str = "default";

pub struct ClientRegistry {
    /// Full API key → ClientConfig.
    store: RwLock<HashMap<String, ClientConfig>>,
}

impl ClientRegistry {
    /// Create a registry pre-seeded with demo clients.
    pub fn with_defaults() -> Self {
        let mut store = HashMap::new();

        // Production healthcare client
        store.insert(
            "msk_live_k9Xp_healthcare_prod".to_string(),
            ClientConfig {
                key_prefix: "msk_live_k9Xp".to_string(),
                label: "Healthcare Intake — Production".to_string(),
                policy: PolicyName::HipaaBase,
                use_case: "healthcare_intake".to_string(),
                environment: Environment::Production,
                active: true,
            },
        );

        // Clinical (stricter) healthcare client
        store.insert(
            "msk_live_a7Yz_clinical_prod".to_string(),
            ClientConfig {
                key_prefix: "msk_live_a7Yz".to_string(),
                label: "Healthcare Clinical — Production".to_string(),
                policy: PolicyName::HipaaClinical,
                use_case: "healthcare_clinical".to_string(),
                environment: Environment::Production,
                active: true,
            },
        );

        // HR assistant (GDPR)
        store.insert(
            "msk_live_r2Wq_hr_prod".to_string(),
            ClientConfig {
                key_prefix: "msk_live_r2Wq".to_string(),
                label: "HR Assistant — Production".to_string(),
                policy: PolicyName::GdprBase,
                use_case: "hr_assistant".to_string(),
                environment: Environment::Production,
                active: true,
            },
        );

        // Staging / dev key — permissive, observe-only
        store.insert(
            "msk_test_d1Lm_dev".to_string(),
            ClientConfig {
                key_prefix: "msk_test_d1Lm".to_string(),
                label: "Dev Local".to_string(),
                policy: PolicyName::HipaaBase,
                use_case: "default".to_string(),
                environment: Environment::Development,
                active: true,
            },
        );

        Self {
            store: RwLock::new(store),
        }
    }

    /// Resolve an API key to a client config.
    /// Returns the default HIPAA-base config for unknown or missing keys.
    pub fn resolve(&self, api_key: Option<&str>) -> ClientConfig {
        let Some(key) = api_key else {
            return Self::default_config();
        };
        let store = self.store.read().unwrap();
        store
            .get(key)
            .filter(|c| c.active)
            .cloned()
            .unwrap_or_else(Self::default_config)
    }

    /// Register a new client key at runtime.
    pub fn register(&self, api_key: String, config: ClientConfig) {
        self.store.write().unwrap().insert(api_key, config);
    }

    /// Revoke a key.
    pub fn revoke(&self, api_key: &str) {
        let mut store = self.store.write().unwrap();
        if let Some(c) = store.get_mut(api_key) {
            c.active = false;
        }
    }

    /// List all registered configs (keys redacted to prefix).
    pub fn list(&self) -> Vec<ClientConfig> {
        self.store.read().unwrap().values().cloned().collect()
    }

    fn default_config() -> ClientConfig {
        ClientConfig {
            key_prefix: "anonymous".to_string(),
            label: "Anonymous / Default".to_string(),
            policy: DEFAULT_POLICY,
            use_case: DEFAULT_USE_CASE.to_string(),
            environment: Environment::Production,
            active: true,
        }
    }
}

impl Default for ClientRegistry {
    fn default() -> Self {
        Self::with_defaults()
    }
}

// ── Tests ─────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn known_key_resolves_to_correct_policy() {
        let reg = ClientRegistry::with_defaults();
        let cfg = reg.resolve(Some("msk_live_k9Xp_healthcare_prod"));
        assert_eq!(cfg.policy, PolicyName::HipaaBase);
        assert_eq!(cfg.use_case, "healthcare_intake");
    }

    #[test]
    fn clinical_key_resolves_to_clinical_policy() {
        let reg = ClientRegistry::with_defaults();
        let cfg = reg.resolve(Some("msk_live_a7Yz_clinical_prod"));
        assert_eq!(cfg.policy, PolicyName::HipaaClinical);
    }

    #[test]
    fn unknown_key_falls_back_to_hipaa_base() {
        let reg = ClientRegistry::with_defaults();
        let cfg = reg.resolve(Some("msk_live_unknown_key"));
        assert_eq!(cfg.policy, DEFAULT_POLICY);
    }

    #[test]
    fn no_key_falls_back_to_hipaa_base() {
        let reg = ClientRegistry::with_defaults();
        let cfg = reg.resolve(None);
        assert_eq!(cfg.policy, DEFAULT_POLICY);
    }

    #[test]
    fn revoked_key_falls_back_to_default() {
        let reg = ClientRegistry::with_defaults();
        reg.revoke("msk_live_k9Xp_healthcare_prod");
        let cfg = reg.resolve(Some("msk_live_k9Xp_healthcare_prod"));
        assert_eq!(cfg.key_prefix, "anonymous");
    }

    #[test]
    fn register_and_resolve_new_key() {
        let reg = ClientRegistry::with_defaults();
        reg.register(
            "msk_live_custom_key".to_string(),
            ClientConfig {
                key_prefix: "msk_live_cust".to_string(),
                label: "Custom".to_string(),
                policy: PolicyName::GdprBase,
                use_case: "custom_uc".to_string(),
                environment: Environment::Staging,
                active: true,
            },
        );
        let cfg = reg.resolve(Some("msk_live_custom_key"));
        assert_eq!(cfg.policy, PolicyName::GdprBase);
        assert_eq!(cfg.use_case, "custom_uc");
    }
}
