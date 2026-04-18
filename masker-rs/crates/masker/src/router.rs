//! Route execution. Mirrors `masker/router.py`.

use crate::backends::{GemmaBackend, StubBackend};
use crate::contracts::{MaskedText, PolicyDecision, Route};
use crate::payload;
use crate::trace::Tracer;

pub struct Router {
    pub local_backend: Box<dyn GemmaBackend>,
    pub cloud_backend: Option<Box<dyn GemmaBackend>>,
}

impl Router {
    pub fn new(local: Box<dyn GemmaBackend>) -> Self {
        Self {
            local_backend: local,
            cloud_backend: None,
        }
    }

    pub fn with_cloud(mut self, cloud: Box<dyn GemmaBackend>) -> Self {
        self.cloud_backend = Some(cloud);
        self
    }

    pub fn execute(
        &self,
        original_text: &str,
        masked: &MaskedText,
        decision: &PolicyDecision,
        tracer: &Tracer,
    ) -> String {
        let (backend, prompt): (&dyn GemmaBackend, &str) = match decision.route {
            Route::LocalOnly => (self.local_backend.as_ref(), original_text),
            Route::MaskedSend => (
                self.cloud_backend
                    .as_deref()
                    .unwrap_or_else(|| self.local_backend.as_ref()),
                masked.text.as_str(),
            ),
            Route::SafeToSend => (
                self.cloud_backend
                    .as_deref()
                    .unwrap_or_else(|| self.local_backend.as_ref()),
                original_text,
            ),
        };

        let backend_name = backend.name();
        let span = tracer.span(
            crate::contracts::TraceStage::Llm,
            format!("{} via route={}", backend_name, decision.route.as_str()),
            payload! {
                "backend" => backend_name,
                "route"   => decision.route.as_str(),
                "prompt_chars" => prompt.len(),
            },
        );

        let result = backend.generate(prompt, 256);
        drop(span);

        match result {
            Ok(text) => text,
            Err(e) => {
                tracer.event(
                    crate::contracts::TraceStage::Llm,
                    format!("backend error, falling back to stub: {e}"),
                    payload! { "backend" => backend_name },
                );
                StubBackend
                    .generate(prompt, 256)
                    .unwrap_or_else(|_| "[stub-fallback failed]".to_string())
            }
        }
    }
}

/// Build a router that prefers cloud (Gemini) when its key is present, with
/// the on-device backend as the local-only fallback.
pub fn default_router() -> Router {
    let cloud: Option<Box<dyn GemmaBackend>> =
        if std::env::var("GEMINI_API_KEY").is_ok() {
            crate::backends::GeminiCloudBackend::from_env()
                .ok()
                .map(|b| Box::new(b) as Box<dyn GemmaBackend>)
        } else {
            None
        };

    let local = if cloud.is_some() {
        // When cloud is wired we want a separate local-only backend for
        // local-only routed turns. Fall back to stub when no cactus is built.
        crate::backends::default_backend()
    } else {
        crate::backends::default_backend()
    };

    let mut r = Router::new(local);
    if let Some(c) = cloud {
        r = r.with_cloud(c);
    }
    r
}
