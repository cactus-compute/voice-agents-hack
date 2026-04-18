# `masker/` — Integration Layer

This is the **Cursor / Integration Agent** workstream from `AGENTS.md`. It owns
voice loop plumbing, route execution, and the Gemma wrapper. Detection,
policy, and masking ship with regex-based stubs so the loop runs end-to-end
today; Codex replaces those bodies without touching this package's surface.

## Layout

| File                 | Owner   | Purpose                                                       |
| -------------------- | ------- | ------------------------------------------------------------- |
| `contracts.py`       | shared  | Typed dataclasses mirroring the JSON contracts in `AGENTS.md` |
| `detection.py`       | Codex   | `detect(text) -> DetectionResult` — currently regex baseline  |
| `policy.py`          | Codex   | `decide(detection) -> PolicyDecision` — HIPAA-first rules     |
| `masking.py`         | Codex   | `mask` / `unmask` / `scrub_output`                            |
| `gemma_wrapper.py`   | Cursor  | Backends: `StubBackend`, `LocalCactusBackend`, `GeminiCloudBackend`, `auto_attach()` |
| `router.py`          | Cursor  | Executes a `PolicyDecision` against a backend                 |
| `voice_loop.py`      | Cursor  | `VoiceLoop.run_text_turn()` and `.run_voice_turn()`           |
| `trace.py`           | Ona-feed| `Tracer` + `TraceEvent` emitter consumed by the UI            |
| `demo.py`            | Cursor  | `python -m masker.demo` runs the four BACKLOG scenarios       |

## Public API (3 calls + a class)

```python
from masker import filter_input, filter_output, auto_attach, default_loop

# 1. Drop-in helpers — what other hackathon teams will call:
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
python -m masker.demo

# Real Gemma 4 on Cactus (~1-2s per turn warm):
source ../cactus/venv/bin/activate
python -m masker.demo --backend cactus

# With a Gemini API key for cloud routes:
export GEMINI_API_KEY=...
python -m masker.demo --backend gemini

# Auto-pick the best backend available in the current env:
python -m masker.demo --backend auto
```

The Cactus backend shells out to `cactus run <model> --prompt <text>`, sends
an empty stdin line to satisfy the optional Cactus Cloud key prompt, and
parses the model's reply out of the chat binary's mixed stdout. No
persistent session — each turn pays the model-load cost (~0.5s warm).

## Tests

```bash
python -m unittest discover -s tests -v
```

The test suite covers detection, policy, masking, the public API, and an
end-to-end `VoiceLoop` smoke test against the stub backend. Tests do not
require `cactus`, `google-genai`, or any model weights.

## Contracts (for Codex / Ona)

All cross-agent boundaries are typed in `contracts.py` and mirror the JSON
shapes in `AGENTS.md`:

```python
DetectionResult(entities=[...], risk_level="high")
PolicyDecision(route="masked-send", policy="hipaa_base", rationale="...")
TraceEvent(stage="masking", message="Masked SSN", elapsed_ms=1.2, payload={...})
TurnResult(...)  # the full per-turn artifact returned by VoiceLoop
```

Codex: replace the bodies of `detect`, `decide`, `mask` — keep the signatures.
Ona: subscribe to `Tracer(on_event=...)` or read `TurnResult.trace` to render.
