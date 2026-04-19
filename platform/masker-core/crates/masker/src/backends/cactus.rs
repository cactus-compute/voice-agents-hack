//! In-process Cactus backend powered by the local `cactus-sys` Rust bindings.
//!
//! Required env vars:
//!   CACTUS_MODEL_PATH  — path to the Gemma / Cactus model weights

use serde_json::json;

use super::{BackendError, GemmaBackend};
use crate::cactus_sdk::CactusModel;

pub struct LocalCactusBackend {
    model: CactusModel,
    system_prompt: Option<String>,
}

impl LocalCactusBackend {
    pub fn from_env() -> Result<Self, BackendError> {
        let model_path = std::env::var("CACTUS_MODEL_PATH")
            .map_err(|_| BackendError::NotConfigured("CACTUS_MODEL_PATH missing".into()))?;
        Self::new(model_path, None)
    }

    pub fn new(
        model_path: impl Into<String>,
        system_prompt: Option<String>,
    ) -> Result<Self, BackendError> {
        let model_path = model_path.into();
        let model = CactusModel::new(&model_path)?;
        Ok(Self {
            model,
            system_prompt,
        })
    }

    pub fn generate_with_audio(
        &self,
        prompt: &str,
        audio_path: &str,
        max_tokens: usize,
    ) -> Result<String, BackendError> {
        let mut user_message = json!({
            "role": "user",
            "content": prompt,
        });
        user_message["audio"] = json!([audio_path]);
        self.generate_messages(vec![user_message], max_tokens)
    }

    fn generate_messages(
        &self,
        mut messages: Vec<serde_json::Value>,
        max_tokens: usize,
    ) -> Result<String, BackendError> {
        if let Some(sys) = &self.system_prompt {
            messages.insert(0, json!({"role": "system", "content": sys}));
        }

        let messages_json = serde_json::to_string(&messages)
            .map_err(|e| BackendError::Transport(format!("encode messages: {e}")))?;
        let options_json = json!({
            "max_tokens": max_tokens,
            "temperature": 0.2,
            "top_p": 0.9,
        })
        .to_string();

        let envelope = self.model.complete(&messages_json, Some(&options_json))?;
        if envelope.response.trim().is_empty() {
            return Err(BackendError::EmptyResponse);
        }
        Ok(envelope.response)
    }
}

impl GemmaBackend for LocalCactusBackend {
    fn name(&self) -> &'static str {
        "cactus-local"
    }

    fn generate(&self, prompt: &str, max_tokens: usize) -> Result<String, BackendError> {
        self.generate_messages(vec![json!({"role": "user", "content": prompt})], max_tokens)
    }
}
