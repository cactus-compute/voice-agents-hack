use masker::contracts::{EntityType, PolicyName, RiskLevel, Route};
use masker::masking::MaskMode;
use masker::{detection, masking, policy, Router, StubBackend, Tracer, VoiceLoop};

#[test]
fn detect_finds_ssn_and_phone() {
    let det = detection::detect("SSN 123-45-6789, call me at 415-555-0123.");
    assert_eq!(det.risk_level, RiskLevel::High);
    let kinds: Vec<_> = det.entities.iter().map(|e| e.kind).collect();
    assert!(kinds.contains(&EntityType::Ssn));
    assert!(kinds.contains(&EntityType::Phone));
}

#[test]
fn detect_marks_clean_input_as_none() {
    let det = detection::detect("What's the weather tomorrow?");
    assert_eq!(det.risk_level, RiskLevel::None);
    assert!(det.entities.is_empty());
}

#[test]
fn detect_picks_up_health_context() {
    let det = detection::detect("I have chest pain since this morning.");
    let kinds: Vec<_> = det.entities.iter().map(|e| e.kind).collect();
    assert!(kinds.contains(&EntityType::HealthContext));
}

#[test]
fn policy_routes_ssn_to_local_only() {
    let det = detection::detect("My SSN is 123-45-6789.");
    let dec = policy::decide(&det, PolicyName::HipaaBase);
    assert_eq!(dec.route, Route::LocalOnly);
}

#[test]
fn policy_routes_clean_text_to_safe_to_send() {
    let det = detection::detect("Tell me a joke.");
    let dec = policy::decide(&det, PolicyName::HipaaBase);
    assert_eq!(dec.route, Route::SafeToSend);
}

#[test]
fn policy_routes_email_to_masked_send() {
    let det = detection::detect("Email me at ada@example.com please.");
    let dec = policy::decide(&det, PolicyName::HipaaBase);
    assert_eq!(dec.route, Route::MaskedSend);
}

#[test]
fn mask_replaces_with_placeholders_in_descending_order() {
    let text = "Email priya@example.com or call 415-555-0123.";
    let det = detection::detect(text);
    let masked = masking::mask(text, &det, MaskMode::Placeholder);
    assert!(masked.text.contains("[MASKED:email]"));
    assert!(masked.text.contains("[MASKED:phone]"));
    assert!(!masked.text.contains("priya@example.com"));
    assert!(!masked.text.contains("415-555-0123"));
    assert_eq!(masked.token_map.len(), 2);
}

#[test]
fn mask_token_mode_is_reversible() {
    let text = "My SSN is 123-45-6789.";
    let det = detection::detect(text);
    let masked = masking::mask(text, &det, MaskMode::Token);
    let restored = masking::unmask(&masked.text, &masked);
    assert_eq!(restored, text);
}

#[test]
fn scrub_output_remasks_leaked_values() {
    let text = "Patient SSN 123-45-6789 with chest pain.";
    let det = detection::detect(text);
    let leaked = "Per the SSN 123-45-6789 we found the chart.";
    let safe = masking::scrub_output(leaked, &det);
    assert!(!safe.contains("123-45-6789"));
    assert!(safe.contains("[MASKED:ssn]"));
}

#[test]
fn voice_loop_runs_end_to_end_with_stub_backend() {
    let loop_ = VoiceLoop::new(Router::new(Box::new(StubBackend)));
    let tracer = Tracer::new();
    let turn = loop_.run_text_turn(
        "I have chest pain and my insurance ID is BCBS-887421, MRN 99812.",
        &tracer,
    );

    assert_eq!(turn.policy.route, Route::LocalOnly);
    assert!(turn.detection.entities.iter().any(|e| matches!(e.kind, EntityType::Mrn)));
    assert!(!turn.safe_output.contains("BCBS-887421"));
    assert!(!turn.safe_output.contains("99812"));
    assert!(turn.total_ms >= 0.0);
    assert!(turn.trace.iter().any(|t| matches!(t.stage, masker::TraceStage::Detection)));
    assert!(turn.trace.iter().any(|t| matches!(t.stage, masker::TraceStage::Llm)));
}

#[test]
fn voice_loop_safe_path_passes_through() {
    let loop_ = VoiceLoop::new(Router::new(Box::new(StubBackend)));
    let tracer = Tracer::new();
    let turn = loop_.run_text_turn("Tell me about Rust async.", &tracer);
    assert_eq!(turn.policy.route, Route::SafeToSend);
    assert_eq!(turn.detection.risk_level, RiskLevel::None);
    assert!(turn.masked_input.token_map.is_empty());
}

#[test]
fn turn_result_serializes_to_json() {
    let loop_ = VoiceLoop::new(Router::new(Box::new(StubBackend)));
    let tracer = Tracer::new();
    let turn = loop_.run_text_turn("My SSN is 123-45-6789.", &tracer);
    let json = serde_json::to_string(&turn).expect("turn must serialize");
    assert!(json.contains("\"route\":\"local-only\""));
    assert!(json.contains("\"risk_level\":\"high\""));
}
