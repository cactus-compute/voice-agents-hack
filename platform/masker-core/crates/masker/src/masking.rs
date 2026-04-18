//! Masking & tokenization. Mirrors
//! `platform/masker-library/masker/masking.py`.

use std::collections::BTreeMap;

use sha2::{Digest, Sha256};

use crate::contracts::{DetectionResult, MaskedText};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MaskMode {
    /// `[MASKED:type]` — readable for the LLM.
    Placeholder,
    /// `<TOKEN:abcd1234>` — stable handle so the LLM can refer back.
    Token,
}

fn token_for(value: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(value.as_bytes());
    let digest = hasher.finalize();
    let hex = hex::encode(digest);
    format!("<TOKEN:{}>", &hex[..8])
}

/// Replace each detected entity span in `text`.
pub fn mask(text: &str, detection: &DetectionResult, mode: MaskMode) -> MaskedText {
    let mut spans: Vec<(usize, usize, String, &'static str)> = detection
        .entities
        .iter()
        .filter(|e| e.end > e.start && e.start < text.len() && e.end <= text.len())
        .map(|e| (e.start, e.end, e.value.clone(), e.kind.as_str()))
        .collect();
    spans.sort_by_key(|(s, _, _, _)| std::cmp::Reverse(*s));

    let mut out = text.to_string();
    let mut token_map: BTreeMap<String, String> = BTreeMap::new();

    for (start, end, value, kind) in spans {
        let replacement = match mode {
            MaskMode::Token => token_for(&value),
            MaskMode::Placeholder => format!("[MASKED:{}]", kind),
        };
        token_map.insert(replacement.clone(), value);

        if !out.is_char_boundary(start) || !out.is_char_boundary(end) {
            continue;
        }
        out.replace_range(start..end, &replacement);
    }

    MaskedText {
        text: out,
        token_map,
    }
}

/// Inverse of [`mask`] — substitute placeholders/tokens back to originals.
pub fn unmask(text: &str, masked: &MaskedText) -> String {
    let mut out = text.to_string();
    for (placeholder, value) in &masked.token_map {
        out = out.replace(placeholder.as_str(), value);
    }
    out
}

/// Re-mask any detected entity values that leaked verbatim into model output.
pub fn scrub_output(text: &str, detection: &DetectionResult) -> String {
    let mut out = text.to_string();
    for e in &detection.entities {
        if e.value.is_empty() {
            continue;
        }
        let replacement = format!("[MASKED:{}]", e.kind.as_str());
        out = out.replace(e.value.as_str(), &replacement);
    }
    out
}
