//! Pluggable model backends. Mirrors
//! `platform/masker-library/masker/gemma_wrapper.py`.

use thiserror::Error;

mod stub;
pub use stub::StubBackend;

mod gemini;
pub use gemini::GeminiCloudBackend;

#[cfg(feature = "cactus")]
mod cactus;
#[cfg(feature = "cactus")]
pub use cactus::LocalCactusBackend;

#[derive(Debug, Error)]
pub enum BackendError {
    #[error("backend not configured: {0}")]
    NotConfigured(String),

    #[error("backend transport error: {0}")]
    Transport(String),

    #[error("backend returned no content")]
    EmptyResponse,
}

pub trait GemmaBackend: Send + Sync {
    fn name(&self) -> &'static str;

    fn generate(&self, prompt: &str, max_tokens: usize) -> Result<String, BackendError>;
}

/// Pick the best available backend at runtime.
///
/// Order: a real Cactus install (if the `cactus` feature is enabled and
/// `CACTUS_MODEL_PATH` is set) → Gemini cloud (if `GEMINI_API_KEY` is set)
/// → deterministic stub (always works, used by CI).
pub fn default_backend() -> Box<dyn GemmaBackend> {
    #[cfg(feature = "cactus")]
    {
        if std::env::var("CACTUS_MODEL_PATH").is_ok() {
            if let Ok(b) = LocalCactusBackend::from_env() {
                return Box::new(b);
            }
        }
    }

    if std::env::var("GEMINI_API_KEY").is_ok() {
        if let Ok(b) = GeminiCloudBackend::from_env() {
            return Box::new(b);
        }
    }

    Box::new(StubBackend)
}
