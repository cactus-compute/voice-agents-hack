# `Masker-Library` — Python SDK

This is the friendliest adoption surface for other teams: a tiny Python API
that keeps existing Gemini / Cactus code mostly unchanged. The canonical
privacy engine lives in Rust under `platform/masker-core/`; when a compiled
`masker` binary is available this package delegates detection / policy /
masking to Rust automatically, and falls back to the pure-Python reference
implementation when it is not.

Component root:

```text
platform/masker-library/
├── masker/             # Python package import root
├── pyproject.toml      # installable package metadata
├── tests/              # unittest suite
├── .env.example        # sample cloud fallback configuration
└── requirements.txt    # optional Python deps
```

## Install

```bash
# Python SDK only
cd platform/masker-library
pip install -e .

# Optional Gemini cloud backend
pip install -e '.[gemini]'

# Optional: build the Rust engine the SDK will delegate to when present
cd ../masker-core
cargo build --release -p masker-cli
```

The SDK looks for the Rust binary in this order:

- `MASKER_RUST_BIN=/abs/path/to/masker`
- `masker` on `PATH`
- `platform/masker-core/target/{release,debug}/masker` inside this repo

Set `MASKER_NATIVE=0` to force the pure-Python fallback. Set
`MASKER_NATIVE=required` to fail fast if the Rust binary is unavailable.

## Layout

| File                 | Owner   | Purpose                                                       |
| -------------------- | ------- | ------------------------------------------------------------- |
| `masker/contracts.py`       | shared   | Typed dataclasses mirroring the JSON contracts in `AGENTS.md` |
| `masker/detection.py`       | Codex    | `detect(text) -> DetectionResult` — currently regex baseline  |
| `masker/policy.py`          | Codex    | `decide(detection) -> PolicyDecision` — HIPAA-first rules     |
| `masker/masking.py`         | Codex    | `mask` / `unmask` / `scrub_output`                            |
| `masker/gemma_wrapper.py`   | Cursor   | Backends: `StubBackend`, `LocalCactusBackend`, `GeminiCloudBackend`, `auto_attach()` |
| `masker/router.py`          | Cursor   | Executes a `PolicyDecision` against a backend                 |
| `masker/voice_loop.py`      | Cursor   | `VoiceLoop.run_text_turn()` and `.run_voice_turn()`           |
| `masker/trace.py`           | Ona-feed | `Tracer` + `TraceEvent` emitter consumed by the UI            |
| `masker/demo.py`            | Cursor   | `python -m masker.demo` runs the four BACKLOG scenarios       |
| `tests/test_integration.py` | shared   | smoke and API coverage                                        |

## Public API (3 calls + a class)

```python
from masker import filter_input, filter_output, auto_attach, default_loop

# 1. Drop-in helpers — what other teams will call first:
safe_prompt, meta = filter_input("My SSN is 123-45-6789.")
safe_response     = filter_output(model_reply)

# 2. Auto-attach to google-genai so existing Gemini code is masked transparently:
auto_attach()  # then the team's existing client.models.generate_content(...) is filtered

# 3. End-to-end loop for our own demo:
loop = default_loop()
result = loop.run_text_turn("I have chest pain, MRN 99812.")
print(result.policy.route)        # 'local-only'
print(result.safe_output)
```

## Running the demo

```bash
# Zero-setup, runs the four BACKLOG scenarios with the stub LLM (<1ms each):
cd platform/masker-library
python -m masker.demo

# or, once installed:
masker-demo

# Real Gemma 4 on Cactus (~1-2s per turn warm), after activating your Cactus env:
python -m masker.demo --backend cactus

# With a Gemini API key for cloud routes:
export GEMINI_API_KEY=...
python -m masker.demo --backend gemini

# Auto-pick the best backend available in the current env:
python -m masker.demo --backend auto
```

The Python integration layer still owns backends and `auto_attach()`, so
teams can keep using familiar Python code. The Rust bridge only replaces the
privacy core stages; route execution and backend plumbing stay in Python.

## Tests

```bash
cd platform/masker-library
python -m unittest discover -s tests -v
```

The test suite covers detection, policy, masking, the public API, the native
bridge fallback path, and an end-to-end `VoiceLoop` smoke test against the
stub backend. Tests do not require `cactus`, `google-genai`, or any model
weights.

## Contracts (for Codex / Ona)

All cross-agent boundaries are typed in `masker/contracts.py` and mirror the
JSON shapes in `AGENTS.md`:

```python
DetectionResult(entities=[...], risk_level="high")
PolicyDecision(route="masked-send", policy="hipaa_base", rationale="...")
TraceEvent(stage="masking", message="Masked SSN", elapsed_ms=1.2, payload={...})
TurnResult(...)  # the full per-turn artifact returned by VoiceLoop
```

Codex: Rust is now the canonical engine, but the Python reference modules stay
valuable for fast iteration and parity testing.
Ona: subscribe to `Tracer(on_event=...)` or read `TurnResult.trace` to render.
