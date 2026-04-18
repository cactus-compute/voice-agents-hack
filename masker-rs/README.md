# `masker-rs` — On-device PII/PHI middleware (Rust)

The Rust port of the Python `masker/` package. Same pipeline, same contracts,
~3 orders of magnitude faster per turn, and a single static binary you can
drop in front of any LLM client.

```
voice in ──► STT ──► detect ──► policy ──► mask ──► route ──► LLM ──► scrub ──► voice out
                       └────────────── trace ──────────────────┘
```

Pipeline runs in **~50 µs once warm** (vs ~30–100 ms in Python), so it fits
inside a sub-100 ms voice-agent budget with room to spare for STT and TTS.

---

## Why a Rust port?

The Python package was the right way to scaffold this in a hackathon — it let
detection / policy / masking / integration be developed in parallel against
typed contracts. But the actual product surface for Masker is a piece of
middleware that:

1. **Runs on-device**, in front of every LLM call, with sub-100 ms budget.
2. **Has no Python runtime to ship** — phones, edge boxes, embedded SDKs.
3. **Holds a persistent Cactus model handle** instead of fork-execing
   `cactus run` per turn (the Python version paid 1–2 s of cold-start per
   call until we wired the FFI).

Rust solves all three: native binary, in-process [Cactus FFI](#backends), and
drops trivially into any partner stack.

The Python package stays for ongoing detection/policy R&D — Codex / Ona keep
iterating there, then we port stable rules over here for production.

---

## Layout

```
masker-rs/
├── Cargo.toml                  # workspace
└── crates/
    ├── masker/                 # library — the public API
    │   ├── src/
    │   │   ├── lib.rs              # re-exports + filter_input/filter_output
    │   │   ├── contracts.rs        # Entity, DetectionResult, PolicyDecision …
    │   │   ├── trace.rs            # Tracer + Span (drop-records elapsed)
    │   │   ├── detection.rs        # regex baseline; swap for a Gemma classifier
    │   │   ├── policy.rs           # HIPAA-base / -logging / -clinical
    │   │   ├── masking.rs          # placeholder + token modes, output scrubbing
    │   │   ├── router.rs           # local-only / masked-send / safe-to-send
    │   │   ├── voice_loop.rs       # end-to-end orchestration
    │   │   └── backends/
    │   │       ├── stub.rs         # deterministic echo, no deps
    │   │       ├── gemini.rs       # Gemini cloud over pure-Rust HTTP
    │   │       └── cactus.rs       # in-process FFI (feature = "cactus")
    │   └── tests/integration.rs    # 12 tests, all green
    └── masker-cli/             # `masker` binary — runs the BACKLOG scenarios
```

---

## Quick start

```bash
# build + test (no native deps)
cd masker-rs
cargo test

# run the demo, all four BACKLOG scenarios, stub backend
cargo run --release -p masker-cli

# JSONL output for piping into a UI / jq
cargo run --release -p masker-cli -- --json

# one scenario, with the strict HIPAA policy
cargo run --release -p masker-cli -- \
    --scenario healthcare --policy hipaa-clinical
```

Sample output (trimmed):

```
[OK] B — Healthcare
  user      : I have chest pain and my insurance ID is BCBS-887421, MRN 99812.
  detected  : ["insurance_id", "mrn", "health_context"] (risk=high)
  policy    : local-only  (expected=local-only)
  rationale : High-risk identifiers detected: ["mrn"]
  masked    : I have [MASKED:health_context] and my insurance ID is [MASKED:insurance_id], MRN [MASKED:mrn].
  → model   : [stub-gemma] received 64 chars. Echo: I have chest pain and my insurance ID is BCBS-887421, MRN 99812.
  ← safe    : [stub-gemma] received 64 chars. Echo: I have [MASKED:health_context] and my insurance ID is [MASKED:insurance_id], MRN [MASKED:mrn].
  total     : 0.1 ms
```

Notice the LocalOnly route never sends the original SSN/MRN to a cloud
backend, and the output filter still scrubs anything the model echoed back.

---

## Public API

```rust
use masker::{default_loop, Tracer, MaskMode};

let loop_  = default_loop();              // picks Cactus → Gemini → Stub
let tracer = Tracer::new();
let turn   = loop_.run_text_turn("My SSN is 123-45-6789", &tracer);

println!("route       : {}", turn.policy.route.as_str());
println!("safe output : {}", turn.safe_output);
for ev in &turn.trace {
    println!("[{:>6.2}ms] {:?} {}", ev.elapsed_ms, ev.stage, ev.message);
}
```

For piecemeal use (matches the Python `filter_input` / `filter_output` helpers):

```rust
let (masked, decision, detection) = masker::filter_input(text);
let safe_reply = masker::filter_output(&model_output, &detection);
```

---

## Backends

Three backends ship in-tree, all behind the `GemmaBackend` trait:

| Backend                | Feature flag | Needs                         | Use for                      |
| ---------------------- | ------------ | ----------------------------- | ---------------------------- |
| `StubBackend`          | (default)    | nothing                       | tests, CI, screen-recordings |
| `GeminiCloudBackend`   | (default)    | `GEMINI_API_KEY`              | cloud fallback, comparisons  |
| `LocalCactusBackend`   | `cactus`     | `libcactus.dylib` + weights   | the real on-device path      |

The Cactus backend opens `libcactus` at runtime via `libloading`, so a fresh
checkout still builds with `cargo build` even on a machine with no Cactus
install. To enable it once you have Cactus built locally:

```bash
export CACTUS_LIB_DIR=/path/to/cactus/build      # contains libcactus.dylib
export CACTUS_MODEL_PATH=/path/to/functiongemma-270m-it.gguf
cargo run --release --features cactus -p masker-cli -- --backend cactus
```

It holds the model handle for the lifetime of the process, so subsequent
turns pay only the inference cost — no fork, no model load.

---

## Performance

Measured on Apple Silicon, release build, stub backend (the variable cost
is the LLM, not the pipeline):

| Stage                    |  per turn |
| ------------------------ | --------: |
| detection (regex)        |  ~4–40 µs |
| policy                   |    <1 µs  |
| masking                  |    <1 µs  |
| routing dispatch         |    <1 µs  |
| output scrub             |    <1 µs  |
| **end-to-end (warm)**    | **~50 µs**|

The full CLI — 4 scenarios + JSON serialization + process startup — finishes
in **340 ms wall-time**.

For comparison the Python version's per-turn pipeline ran ~30–100 ms warm and
needed a ~1–2 s cold start before the first turn even with the subprocess
optimisation.

---

## Testing

```bash
cargo test --all-features
cargo clippy --all-targets --all-features -- -D warnings
```

12 integration tests cover detection, policy, masking (placeholder + token
modes, output scrubbing), the voice-loop end-to-end, and `serde` round-trip
of `TurnResult` so the trace UI gets a stable JSON shape.

---

## Pairing with the Python package

Both implementations share the contracts in `AGENTS.md`:

```
{"entities": [{"type": "ssn", "value": "..."}], "risk_level": "high"}
{"route": "masked-send", "policy": "hipaa_base"}
{"stage": "masking", "message": "Masked SSN"}
```

So the Rust binary can be the production path while Codex / Ona iterate on
classifier and UI rules in Python — outputs drop into the same trace viewer
without code changes.
