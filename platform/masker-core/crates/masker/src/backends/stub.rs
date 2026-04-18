//! Deterministic echo backend — keeps the demo runnable with zero deps.

use super::{BackendError, GemmaBackend};

#[derive(Debug, Clone)]
pub struct StubBackend;

impl GemmaBackend for StubBackend {
    fn name(&self) -> &'static str {
        "stub"
    }

    fn generate(&self, prompt: &str, max_tokens: usize) -> Result<String, BackendError> {
        let truncated: String = prompt.chars().take(max_tokens.min(280)).collect();
        Ok(format!(
            "[stub-gemma] received {} chars. Echo: {}",
            prompt.len(),
            truncated
        ))
    }
}
