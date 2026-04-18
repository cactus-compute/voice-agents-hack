//! End-to-end voice / text loop. Mirrors
//! `platform/masker-library/masker/voice_loop.py`.

use std::time::Instant;

use crate::contracts::{PolicyName, TraceStage, TurnResult};
use crate::masking::MaskMode;
use crate::payload;
use crate::router::Router;
use crate::trace::Tracer;
use crate::{detection, masking, policy};

pub struct VoiceLoop {
    pub router: Router,
    pub policy_name: PolicyName,
    pub mask_mode: MaskMode,
}

impl VoiceLoop {
    pub fn new(router: Router) -> Self {
        Self {
            router,
            policy_name: PolicyName::HipaaBase,
            mask_mode: MaskMode::Placeholder,
        }
    }

    pub fn with_policy(mut self, p: PolicyName) -> Self {
        self.policy_name = p;
        self
    }

    pub fn with_mask_mode(mut self, m: MaskMode) -> Self {
        self.mask_mode = m;
        self
    }

    /// Run a full text turn — used by tests, CLI demo, and any integration
    /// that already has transcribed text.
    pub fn run_text_turn(&self, text: &str, tracer: &Tracer) -> TurnResult {
        let t0 = Instant::now();

        let detection = {
            let _s = tracer.span(
                TraceStage::Detection,
                "Scanning input for PII/PHI",
                payload! {},
            );
            detection::detect(text)
        };
        tracer.event(
            TraceStage::Detection,
            format!(
                "risk={}, entities={}",
                detection.risk_level.as_str(),
                detection.entities.len()
            ),
            payload! {
                "risk" => detection.risk_level.as_str(),
                "entity_types" => detection.entities.iter().map(|e| e.kind.as_str()).collect::<Vec<_>>(),
            },
        );

        let decision = {
            let _s = tracer.span(
                TraceStage::Policy,
                format!("Applying {}", self.policy_name.as_str()),
                payload! {},
            );
            policy::decide(&detection, self.policy_name)
        };
        tracer.event(
            TraceStage::Policy,
            format!("route={}", decision.route.as_str()),
            payload! {
                "route"     => decision.route.as_str(),
                "policy"    => decision.policy.as_str(),
                "rationale" => decision.rationale.clone(),
            },
        );

        let masked = {
            let _s = tracer.span(TraceStage::Masking, "Masking sensitive spans", payload! {});
            masking::mask(text, &detection, self.mask_mode)
        };
        if !masked.token_map.is_empty() {
            tracer.event(
                TraceStage::Masking,
                format!("masked {} span(s)", masked.token_map.len()),
                payload! { "masked_count" => masked.token_map.len() },
            );
        }

        let model_text = self.router.execute(text, &masked, &decision, tracer);

        let safe_out = {
            let _s = tracer.span(
                TraceStage::OutputFilter,
                "Re-scanning model output for leakage",
                payload! {},
            );
            masking::scrub_output(&model_text, &detection)
        };
        if safe_out != model_text {
            tracer.event(
                TraceStage::OutputFilter,
                "scrubbed leaked entity from output",
                payload! {},
            );
        }

        let total_ms = t0.elapsed().as_secs_f64() * 1000.0;

        TurnResult {
            user_text: text.to_string(),
            detection,
            policy: decision,
            masked_input: masked,
            model_output: model_text,
            safe_output: safe_out,
            trace: tracer.events(),
            total_ms,
        }
    }
}

pub fn default_loop() -> VoiceLoop {
    VoiceLoop::new(crate::router::default_router())
}
