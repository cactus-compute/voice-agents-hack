//! `masker` CLI — runs the four BACKLOG scenarios end-to-end.
//!
//! Examples:
//!     masker                          # stub backend, all scenarios, pretty
//!     masker --backend stub --json    # JSONL output for piping to jq
//!     masker --scenario healthcare    # only one scenario
//!     masker --backend gemini --policy hipaa_clinical

use std::io::{self, BufRead};
use std::process::ExitCode;
use std::time::Instant;

use anyhow::{anyhow, Result};
use clap::{Parser, Subcommand, ValueEnum};

#[cfg(feature = "cactus")]
use masker::backends::LocalCactusBackend;
use masker::backends::{GeminiCloudBackend, GemmaBackend, StubBackend};
use masker::{
    contracts::{DetectionResult, PolicyName, Route, TraceEvent, TraceStage},
    AudioChunk, MaskMode, Router, StreamingPipeline, Tracer, VoiceLoop,
};

#[derive(Copy, Clone, Debug, ValueEnum)]
enum Backend {
    Stub,
    Gemini,
    Cactus,
    Auto,
}

#[derive(Copy, Clone, Debug, ValueEnum)]
#[allow(clippy::enum_variant_names)]
enum CliPolicy {
    HipaaBase,
    HipaaLogging,
    HipaaClinical,
}

impl From<CliPolicy> for PolicyName {
    fn from(p: CliPolicy) -> Self {
        match p {
            CliPolicy::HipaaBase => PolicyName::HipaaBase,
            CliPolicy::HipaaLogging => PolicyName::HipaaLogging,
            CliPolicy::HipaaClinical => PolicyName::HipaaClinical,
        }
    }
}

#[derive(Copy, Clone, Debug, ValueEnum)]
enum CliMaskMode {
    Placeholder,
    Token,
}

impl From<CliMaskMode> for MaskMode {
    fn from(mode: CliMaskMode) -> Self {
        match mode {
            CliMaskMode::Placeholder => MaskMode::Placeholder,
            CliMaskMode::Token => MaskMode::Token,
        }
    }
}

#[derive(Subcommand, Debug)]
enum Command {
    /// Run detection + policy + masking and emit JSON for SDK integrations.
    FilterInput {
        #[arg(long)]
        text: String,

        #[arg(long, value_enum, default_value_t = CliPolicy::HipaaBase)]
        policy: CliPolicy,

        #[arg(long, value_enum, default_value_t = CliMaskMode::Placeholder)]
        mask_mode: CliMaskMode,
    },

    /// Re-scan model output and scrub any leaked sensitive values.
    FilterOutput {
        #[arg(long)]
        text: String,

        /// Optional DetectionResult JSON from a prior `filter-input` call.
        #[arg(long)]
        detection_json: Option<String>,
    },

    /// Run a single end-to-end turn and emit a TurnResult JSON payload.
    RunTurn {
        #[arg(long)]
        text: String,

        #[arg(long, value_enum, default_value_t = Backend::Auto)]
        backend: Backend,

        #[arg(long, value_enum, default_value_t = CliPolicy::HipaaBase)]
        policy: CliPolicy,
    },

    /// Stream text lines through the full audio pipeline (STT stub → detect →
    /// policy → mask → TTS stub → encrypted audit log).
    ///
    /// Reads one line of text per chunk from stdin (or --text for a single
    /// chunk). Emits one JSON object per chunk to stdout. Encrypted audit
    /// entries are printed to stderr as JSON lines.
    ///
    /// Example (interactive):
    ///   echo "My SSN is 482-55-1234." | masker stream --session ses_001
    ///
    /// Example (batch):
    ///   masker stream --text "Call John at 555-867-5309." --api-key msk_live_k9Xp_healthcare_prod
    Stream {
        /// Session identifier for audit grouping.
        #[arg(long, default_value = "ses_cli")]
        session: String,

        /// Optional API key to select client policy. Defaults to HIPAA-base.
        #[arg(long)]
        api_key: Option<String>,

        /// Process a single text chunk instead of reading from stdin.
        #[arg(long)]
        text: Option<String>,

        /// Emit full audit entries (encrypted) to stderr as JSON lines.
        #[arg(long, default_value_t = false)]
        audit: bool,
    },
}

#[derive(Parser, Debug)]
#[command(
    name = "masker",
    about = "Masker demo — PII/PHI filter for voice agents"
)]
struct Cli {
    #[command(subcommand)]
    command: Option<Command>,

    #[arg(long, value_enum, default_value_t = Backend::Stub)]
    backend: Backend,

    #[arg(long, value_enum, default_value_t = CliPolicy::HipaaBase)]
    policy: CliPolicy,

    /// Emit one JSON object per scenario instead of the human-readable view.
    #[arg(long, default_value_t = false)]
    json: bool,

    /// Substring filter against scenario labels (case-insensitive).
    #[arg(long)]
    scenario: Option<String>,
}

struct Scenario {
    label: &'static str,
    text: &'static str,
    expected_route: Route,
}

const SCENARIOS: &[Scenario] = &[
    Scenario {
        label: "A — Personal info",
        text: "Text Sarah my address is 4821 Mission Street, my number is 415-555-0123.",
        expected_route: Route::MaskedSend,
    },
    Scenario {
        label: "B — Healthcare",
        text: "I have chest pain and my insurance ID is BCBS-887421, MRN 99812.",
        expected_route: Route::LocalOnly,
    },
    Scenario {
        label: "C — Safe query",
        text: "What's the weather tomorrow?",
        expected_route: Route::SafeToSend,
    },
    Scenario {
        label: "D — Work context",
        text: "Summarize the Apollo escalation for the Redwood account, contact priya@redwood.com.",
        expected_route: Route::MaskedSend,
    },
];

fn build_backend(b: Backend) -> Result<Box<dyn GemmaBackend>> {
    Ok(match b {
        Backend::Stub => Box::new(StubBackend),
        Backend::Gemini => Box::new(
            GeminiCloudBackend::from_env()
                .map_err(|e| anyhow!("gemini backend unavailable: {e}"))?,
        ),
        Backend::Cactus => {
            #[cfg(feature = "cactus")]
            {
                Box::new(
                    LocalCactusBackend::from_env()
                        .map_err(|e| anyhow!("cactus backend unavailable: {e}"))?,
                )
            }
            #[cfg(not(feature = "cactus"))]
            {
                return Err(anyhow!(
                    "binary built without `cactus` feature — rebuild with `cargo build --features cactus`"
                ));
            }
        }
        Backend::Auto => masker::default_backend(),
    })
}

fn run(cli: Cli) -> Result<i32> {
    if let Some(command) = cli.command {
        return run_command(command);
    }

    let backend = build_backend(cli.backend)?;
    let loop_ = VoiceLoop::new(Router::new(backend)).with_policy(cli.policy.into());

    let needle = cli.scenario.as_ref().map(|s| s.to_lowercase());
    let scenarios: Vec<&Scenario> = SCENARIOS
        .iter()
        .filter(|s| {
            needle
                .as_ref()
                .map(|n| s.label.to_lowercase().contains(n))
                .unwrap_or(true)
        })
        .collect();

    if scenarios.is_empty() {
        eprintln!("no scenario matched {:?}", cli.scenario);
        return Ok(2);
    }

    let mut failures = 0;

    for s in scenarios {
        let tracer = Tracer::new();
        let result = loop_.run_text_turn(s.text, &tracer);

        if cli.json {
            let envelope = serde_json::json!({
                "scenario": s.label,
                "expected": s.expected_route.as_str(),
                "result": result,
            });
            println!("{}", envelope);
            continue;
        }

        let ok = result.policy.route == s.expected_route;
        if !ok {
            failures += 1;
        }
        let bar = "─".repeat(78);
        println!("\n{bar}");
        println!("[{}] {}", if ok { "OK" } else { "MISMATCH" }, s.label);
        println!("  user      : {}", s.text);
        println!(
            "  detected  : {:?} (risk={})",
            result
                .detection
                .entities
                .iter()
                .map(|e| e.kind.as_str())
                .collect::<Vec<_>>(),
            result.detection.risk_level.as_str()
        );
        println!(
            "  policy    : {}  (expected={})",
            result.policy.route.as_str(),
            s.expected_route.as_str()
        );
        println!("  rationale : {}", result.policy.rationale);
        println!("  masked    : {}", truncate(&result.masked_input.text, 240));
        println!("  → model   : {}", truncate(&result.model_output, 160));
        println!("  ← safe    : {}", truncate(&result.safe_output, 160));
        println!("  total     : {:.1} ms", result.total_ms);
    }

    Ok(if failures > 0 { 1 } else { 0 })
}

fn run_command(command: Command) -> Result<i32> {
    match command {
        Command::FilterInput {
            text,
            policy,
            mask_mode,
        } => {
            let detection_started = Instant::now();
            let detection = masker::detection::detect(&text);
            let detection_ms = detection_started.elapsed().as_secs_f64() * 1000.0;

            let policy_started = Instant::now();
            let decision = masker::policy::decide(&detection, policy.into());
            let policy_ms = policy_started.elapsed().as_secs_f64() * 1000.0;

            let masking_started = Instant::now();
            let masked = masker::masking::mask(&text, &detection, mask_mode.into());
            let masking_ms = masking_started.elapsed().as_secs_f64() * 1000.0;

            let entity_types: Vec<&str> = detection
                .entities
                .iter()
                .map(|entity| entity.kind.as_str())
                .collect();
            let masked_count = masked.token_map.len();
            let mut trace = vec![
                TraceEvent {
                    stage: TraceStage::Detection,
                    message: "Scanning input for PII/PHI".to_string(),
                    elapsed_ms: detection_ms,
                    payload: masker::payload! {
                        "risk" => detection.risk_level.as_str(),
                        "entity_types" => entity_types,
                    },
                },
                TraceEvent {
                    stage: TraceStage::Detection,
                    message: format!(
                        "risk={}, entities={}",
                        detection.risk_level.as_str(),
                        detection.entities.len()
                    ),
                    elapsed_ms: 0.0,
                    payload: masker::payload! {
                        "risk" => detection.risk_level.as_str(),
                        "entity_types" => detection
                            .entities
                            .iter()
                            .map(|entity| entity.kind.as_str())
                            .collect::<Vec<_>>(),
                    },
                },
                TraceEvent {
                    stage: TraceStage::Policy,
                    message: format!("Applying {}", decision.policy.as_str()),
                    elapsed_ms: policy_ms,
                    payload: masker::payload! {
                        "policy" => decision.policy.as_str(),
                    },
                },
                TraceEvent {
                    stage: TraceStage::Policy,
                    message: format!("route={}", decision.route.as_str()),
                    elapsed_ms: 0.0,
                    payload: masker::payload! {
                        "route" => decision.route.as_str(),
                        "policy" => decision.policy.as_str(),
                        "rationale" => decision.rationale.as_str(),
                    },
                },
                TraceEvent {
                    stage: TraceStage::Masking,
                    message: "Masking sensitive spans".to_string(),
                    elapsed_ms: masking_ms,
                    payload: masker::payload! {},
                },
            ];
            if masked_count > 0 {
                trace.push(TraceEvent {
                    stage: TraceStage::Masking,
                    message: format!("masked {} span(s)", masked_count),
                    elapsed_ms: 0.0,
                    payload: masker::payload! {
                        "masked_count" => masked_count,
                    },
                });
            }

            let payload = serde_json::json!({
                "masked_input": masked,
                "policy": decision,
                "detection": detection,
                "trace": trace,
            });
            println!("{}", serde_json::to_string(&payload)?);
            Ok(0)
        }
        Command::FilterOutput {
            text,
            detection_json,
        } => {
            let detection = match detection_json {
                Some(raw) => serde_json::from_str::<DetectionResult>(&raw)
                    .map_err(|e| anyhow!("invalid detection JSON: {e}"))?,
                None => masker::detection::detect(&text),
            };

            let started = Instant::now();
            let safe_text = masker::filter_output(&text, &detection);
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;

            let mut trace = vec![TraceEvent {
                stage: TraceStage::OutputFilter,
                message: "Re-scanning model output for leakage".to_string(),
                elapsed_ms,
                payload: masker::payload! {},
            }];
            if safe_text != text {
                trace.push(TraceEvent {
                    stage: TraceStage::OutputFilter,
                    message: "scrubbed leaked entity from output".to_string(),
                    elapsed_ms: 0.0,
                    payload: masker::payload! {},
                });
            }

            let payload = serde_json::json!({
                "safe_text": safe_text,
                "trace": trace,
            });
            println!("{}", serde_json::to_string(&payload)?);
            Ok(0)
        }
        Command::RunTurn {
            text,
            backend,
            policy,
        } => {
            let backend = build_backend(backend)?;
            let loop_ = VoiceLoop::new(Router::new(backend)).with_policy(policy.into());
            let tracer = Tracer::new();
            let result = loop_.run_text_turn(&text, &tracer);
            println!("{}", serde_json::to_string(&result)?);
            Ok(0)
        }

        Command::Stream {
            session,
            api_key,
            text,
            audit,
        } => {
            let pipeline = StreamingPipeline::new_with_defaults();
            let api_key_ref = api_key.as_deref();

            // Collect lines: either the single --text arg or stdin lines.
            let lines: Vec<String> = if let Some(t) = text {
                vec![t]
            } else {
                let stdin = io::stdin();
                stdin.lock().lines().collect::<Result<_, _>>()?
            };

            let mut failures = 0;
            for (seq, line) in lines.iter().enumerate() {
                let line = line.trim();
                if line.is_empty() {
                    continue;
                }
                let chunk = AudioChunk {
                    seq: seq as u64,
                    data: line.as_bytes().to_vec(),
                    sample_rate: 16_000,
                    duration_ms: 500,
                };
                match pipeline.process(&session, api_key_ref, &chunk) {
                    Ok(result) => {
                        let out = serde_json::json!({
                            "seq": result.seq,
                            "route": result.route.as_str(),
                            "policy": result.policy.policy.as_str(),
                            "entity_count": result.detection.entities.len(),
                            "entity_types": result.detection.entities.iter()
                                .map(|e| e.kind.as_str())
                                .collect::<Vec<_>>(),
                            "risk_level": result.detection.risk_level.as_str(),
                            "masked_transcript": result.masked_transcript,
                            "processing_ms": result.processing_ms,
                            "trace": result.trace.iter().map(|e| serde_json::json!({
                                "stage": e.stage.as_str(),
                                "message": e.message,
                                "elapsed_ms": e.elapsed_ms,
                            })).collect::<Vec<_>>(),
                        });
                        println!("{}", out);

                        if audit {
                            // Audit entries are emitted to stderr so stdout
                            // stays clean for piping to jq.
                            eprintln!(
                                "audit: seq={} route={} entities={} policy={}",
                                result.seq,
                                result.route.as_str(),
                                result.detection.entities.len(),
                                result.policy.policy.as_str(),
                            );
                        }
                    }
                    Err(e) => {
                        eprintln!("stream error (seq={}): {e:#}", seq);
                        failures += 1;
                    }
                }
            }

            Ok(if failures > 0 { 1 } else { 0 })
        }
    }
}

fn truncate(s: &str, n: usize) -> String {
    if s.chars().count() <= n {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(n).collect();
        out.push('…');
        out
    }
}

fn main() -> ExitCode {
    let cli = Cli::parse();
    match run(cli) {
        Ok(0) => ExitCode::SUCCESS,
        Ok(code) => ExitCode::from(code as u8),
        Err(e) => {
            eprintln!("masker: {e:#}");
            ExitCode::from(2)
        }
    }
}
