//! `masker` CLI — runs the four BACKLOG scenarios end-to-end.
//!
//! Examples:
//!     masker                          # stub backend, all scenarios, pretty
//!     masker --backend stub --json    # JSONL output for piping to jq
//!     masker --scenario healthcare    # only one scenario
//!     masker --backend gemini --policy hipaa_clinical

use std::process::ExitCode;

use anyhow::{anyhow, Result};
use clap::{Parser, ValueEnum};

use masker::backends::{GeminiCloudBackend, GemmaBackend, StubBackend};
#[cfg(feature = "cactus")]
use masker::backends::LocalCactusBackend;
use masker::{
    contracts::{PolicyName, Route},
    Router, Tracer, VoiceLoop,
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

#[derive(Parser, Debug)]
#[command(name = "masker", about = "Masker demo — PII/PHI filter for voice agents")]
struct Cli {
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
