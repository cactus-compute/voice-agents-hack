//! Gemini cloud backend — pure-Rust HTTP, no SDK dependency.
//!
//! Uses the public REST endpoint:
//!   POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent
//! Auth: `?key=$GEMINI_API_KEY`.

use serde_json::json;

use super::{BackendError, GemmaBackend};

const DEFAULT_MODEL: &str = "gemini-1.5-flash-latest";

#[derive(Debug, Clone)]
pub struct GeminiCloudBackend {
    api_key: String,
    model: String,
    timeout_s: u64,
}

impl GeminiCloudBackend {
    pub fn new(api_key: impl Into<String>, model: impl Into<String>) -> Self {
        Self {
            api_key: api_key.into(),
            model: model.into(),
            timeout_s: 30,
        }
    }

    pub fn from_env() -> Result<Self, BackendError> {
        let key = std::env::var("GEMINI_API_KEY")
            .map_err(|_| BackendError::NotConfigured("GEMINI_API_KEY missing".into()))?;
        let model = std::env::var("GEMINI_MODEL").unwrap_or_else(|_| DEFAULT_MODEL.to_string());
        Ok(Self::new(key, model))
    }
}

impl GemmaBackend for GeminiCloudBackend {
    fn name(&self) -> &'static str {
        "gemini-cloud"
    }

    fn generate(&self, prompt: &str, max_tokens: usize) -> Result<String, BackendError> {
        let url = format!(
            "https://generativelanguage.googleapis.com/v1beta/models/{}:generateContent?key={}",
            self.model, self.api_key
        );

        let body = json!({
            "contents": [{
                "role": "user",
                "parts": [{ "text": prompt }],
            }],
            "generationConfig": {
                "maxOutputTokens": max_tokens,
                "temperature": 0.2,
            }
        });

        let agent = ureq::AgentBuilder::new()
            .timeout(std::time::Duration::from_secs(self.timeout_s))
            .build();

        let resp = agent
            .post(&url)
            .set("Content-Type", "application/json")
            .send_json(body)
            .map_err(|e| BackendError::Transport(format!("{e}")))?;

        let v: serde_json::Value = resp
            .into_json()
            .map_err(|e| BackendError::Transport(format!("decode: {e}")))?;

        let text = v
            .pointer("/candidates/0/content/parts/0/text")
            .and_then(|t| t.as_str())
            .ok_or(BackendError::EmptyResponse)?;

        Ok(text.to_string())
    }
}
