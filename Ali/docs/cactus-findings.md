# Cactus integration findings

**Date:** 2026-04-18 (YC × Cactus Gemma-4 Voice Agents Hackathon)
**Scope:** One day of hands-on integration on an Apple Silicon Mac. Brew-installed Cactus 1.14. Hackathon project: a local-first voice agent with a browser-agent sub-tool.
**Audience:** hackathon team, judges, and whoever picks this project up next.

This document is a plain-spoken log of what we found, not a review. Where we had to work around something, we say what the workaround was. Where Cactus is genuinely strong, we say that too.

---

## TL;DR

- **Install + Python bindings work** after one path workaround (Homebrew puts the dylib at a different path than the Python shim expects).
- **Python SDK takes JSON strings, not kwarg dicts.** The integration guide floating around has the wrong call signature — we lost an hour to it. Real API: `cactus_complete(model, messages_json, options_json, tools_json, callback)`.
- **Short-prompt performance is excellent.** gemma-3-1b returned "Four" for "What is 2+2?" in 160 ms. `gemma-4-E2B-it` returned `navigate({url})` as a structured `function_call` on a 1.3 K-token prompt in 22 s (190 tok/s prefill, 10 tok/s decode).
- **Long-prompt performance falls off a cliff on CPU.** gemma-4-E2B @ 6.7 K-token prompt → 35–63 s/step. @ 23 K tokens (LinkedIn rendered DOM) → 120 s+ timeout. gemma-4-E4B @ 6.7 K → **6 tok/s** — the `model.mlpackage` for Apple NPU isn't shipped yet in Cactus 1.14, so prefill stays on CPU.
- **Small models need heavy prompting to use the tool-call grammar.** Default gemma-4-E2B emitted `navigate({"url":"..."})` as plain text. A 4-line "structured-call only" preamble in the system prompt fixed it.
- **`cloud_handoff` is half-finished.** `auto_handoff: true` calls a hardcoded `104.198.76.3` GCP IP with self-signed TLS. We (and the integration guide) recommend `auto_handoff: false` and managing the fallback yourself.
- **For this project, Cactus fits in the intent layer, not the browser agent.** We switched the browser path to Gemini Flash after hitting the LinkedIn-DOM cliff. Cactus's right home here is short-text, privacy-critical operations on the critical path: intent classification + pre-cloud sanitisation.

---

## 1. Installation

### What works

```bash
brew install cactus-compute/cactus/cactus
```

Installs the CLI at `/opt/homebrew/bin/cactus`, the dylib at `/opt/homebrew/opt/cactus/lib/libcactus.dylib`, and the Python FFI wrapper into Homebrew Python 3.14 (`/opt/homebrew/lib/python3.14/site-packages/cactus.py`).

### What broke

`cactus.py` hardcodes the dylib path at `<site-packages-parent>/../../cactus/build/libcactus.dylib`, which **does not match** where Homebrew put the dylib. First `import cactus` raises:

```
RuntimeError: Cactus library not found at /opt/homebrew/lib/cactus/build/libcactus.dylib
Please build first: cactus build --python
```

The install-time README says "For other Python versions, point to the shared library: `export CACTUS_LIB_PATH=...`" — but the installed `cactus.py` **doesn't read `CACTUS_LIB_PATH`**. The env-var hint is wishful documentation.

### Workaround

```bash
mkdir -p /opt/homebrew/lib/cactus/build
ln -sf /opt/homebrew/opt/cactus/lib/libcactus.dylib \
       /opt/homebrew/lib/cactus/build/libcactus.dylib
```

One symlink. No code changes needed. This should be in the brew formula post-install step or the `cactus.py` shim should be taught to honour `CACTUS_LIB_PATH`.

---

## 2. Python API: what the bindings actually look like

The integration guide we were given showed this call pattern:

```python
# NOT how it actually works
cactus_complete(
    MODEL, req.messages,
    tools=tools_wrapped,
    max_tokens=req.max_tokens,
    confidence_threshold=0.7,
    auto_handoff=False,
    tool_rag_top_k=0,
    force_tools=False,
)
```

The real signature in `/opt/homebrew/lib/python3.14/site-packages/cactus.py`:

```python
def cactus_init(model_path, corpus_dir, cache_index):  # three args, not one
    ...

def cactus_complete(model, messages_json, options_json, tools_json,
                    callback, pcm_data=None):  # JSON STRINGS, not kwargs
    ...
```

So the actual usage is:

```python
model = cactus_init("/opt/homebrew/opt/cactus/libexec/weights/gemma-4-E2B-it",
                    None, False)

options = {
    "max_tokens": 2048,
    "temperature": 0.0,
    "tool_rag_top_k": 0,
    "force_tools": False,
    "confidence_threshold": 0.7,
    "auto_handoff": False,
}
tools = [{"type": "function", "function": {...}}]
messages = [{"role": "system", "content": "..."}, ...]

raw = cactus_complete(
    model,
    json.dumps(messages),
    json.dumps(options),
    json.dumps(tools),
    None,                # no streaming callback
)
result = json.loads(raw)
```

The response shape (from `docs/cactus_engine.md` and verified empirically) is:

```json
{
  "success": true,
  "error": null,
  "cloud_handoff": false,
  "response": "I am an AI assistant.",
  "function_calls": [{"name": "click", "arguments": {"ref": "42"}}],
  "segments": [],
  "confidence": 0.85,
  "time_to_first_token_ms": 150.5,
  "total_time_ms": 1250.3,
  "prefill_tps": 166.1,
  "decode_tps": 45.2,
  "ram_usage_mb": 245.67,
  "prefill_tokens": 25,
  "decode_tokens": 8,
  "total_tokens": 33
}
```

### Our sidecar wrapper

Because hitting the bare ctypes API is painful and we had a Node agent loop to integrate with, we built a small FastAPI sidecar at `scripts/cactus_server.py` that exposes:

- `GET /healthz` — `{"ok": true, "model": "..."}`
- `POST /v1/complete` — accepts `{messages, tools?, max_tokens?, confidence_threshold?, auto_handoff?}`, does the JSON encoding + lazy Cactus import + tempfile handling for images, returns the raw Cactus response dict.

Recommended as a pattern for anyone embedding Cactus into a multi-language stack. ~200 LOC.

---

## 3. Performance measurements (Apple Silicon Mac, CPU prefill)

All runs on the same machine, uvicorn + Cactus 1.14 + INT4 weights.

### Loading + trivial prompt

| Model | Weights on disk | Cold load | 11-tok prompt, 1-tok output |
|---|---|---|---|
| gemma-3-1b-it | 727 MB | 0.7 s | **160 ms** |
| gemma-4-E2B-it | 6.3 GB | ~30 s | **253 ms** (11 tok @ 50 tok/s prefill) |
| gemma-4-E4B-it | 8.2 GB | ~40 s | **1.84 s** (11 tok @ 6 tok/s prefill) |
| Qwen3.5-2B | ~3 GB | 0.7 s | 0.6 s |

### Agent-shaped prompt (~1,300 tokens system + 13 tool defs)

| Model | Prefill tok/s | Decode tok/s | Total | Tool call format? |
|---|---|---|---|---|
| gemma-4-E2B-it | **190** | 10 | **8 s** | ❌ emitted as text until prompt nudged |
| Qwen3.5-2B | 88 | 20 | 22 s | ✅ structured function_call, but wrong tool picked |

### Real-world prompt (~6,700 tokens — agent system + 13 tool defs, via our extension)

| Model | Turn duration | Tokens in | Notes |
|---|---|---|---|
| gemma-4-E2B-it | 58–65 s | 6.7 K | 3-step example.com task → **completed correctly** in 187 s. |
| gemma-4-E4B-it | **154 s** | 6.7 K | 6 tok/s CPU prefill — same task would need ~7 min/step. Unusable. |

### Pathological prompt (~23,000 tokens — LinkedIn rendered DOM in tool_result)

| Model | Result |
|---|---|
| gemma-4-E2B-it | **Extension 120 s timeout fired.** Prefill of 23 K @ 190 tok/s = ~120 s; model never got to generate. |

### Why E4B is much slower than E2B

`[WARN] [npu] [gemma4] model.mlpackage not found; using CPU prefill`

Cactus 1.14 ships `vision_encoder.mlpackage` + `audio_encoder.mlpackage` (Apple NPU-optimised) for the encoders, but **does not ship `model.mlpackage`** for the LLM body of the gemma-4 family. So even with `--weights-variant apple`, the text decoder runs on CPU. On CPU, E4B at ~6 tok/s prefill is ~32× slower than E2B at ~190 tok/s — the NPU is doing most of the advertised "apple-npu" speedup.

The integration guide's 660 tok/s M5+ANE number is accurate for when the mlpackage ships; it just isn't shipped yet for E4B. When it does, E4B should be the right default.

---

## 4. Tool-call format failures on small models

Our first gemma-4-E2B agent run on example.com produced this in the saved log:

```json
{
  "stop_reason": "end_turn",
  "textContent": "navigate({\"url\": \"https://www.example.com\"})",
  "toolCalls": []
}
```

The model knew what to do. It just emitted the tool call as plain text in the response field instead of as a structured `function_calls[]`. Cactus's grammar didn't pick it up. `confidence: 0.98` — the model was confident; the protocol was wrong.

### Fix

Four lines at the top of the system prompt:

> **HOW TO INVOKE TOOLS — READ THIS FIRST**
> When you decide to use a tool, you MUST emit it through the structured function-calling mechanism. NEVER write a tool invocation as plain text — text like `navigate({"url": "..."})` is treated as your final answer and the tool will not execute.

After this nudge, the same task ran in 187 s and correctly called `navigate → read_page → finish`. Output: "The page title is Example Domain." 3 turns, 3 structured tool calls, 0 format errors.

### Takeaway

Small (~2B) generalist models like gemma-4-E2B know what to do but don't reliably follow the tool-call grammar without explicit prompt-level pressure. Specialist models (FunctionGemma, Qwen3.5) emit structured calls more reliably but are less intelligent about which tool to pick. For this project we went with gemma-4-E2B + the prompt nudge.

---

## 5. "Hybrid Router" / `cloud_handoff` — what it actually is

From the integration guide:

> Passing `auto_handoff: true` to `cactus_complete` makes the engine **itself** call Cactus's cloud endpoint when it decides to hand off. That endpoint:
> - Default URL: `https://104.198.76.3/api/v1` (hardcoded in `ffi/cactus_cloud.cpp:297`).
> - GCP VM. TLS cert is self-signed.
> - Backend model: hardcoded `gemini-2.5-flash`.

We did not exercise the built-in handoff. We followed the guide's "Option B" — run with `auto_handoff: false`, catch `cloud_handoff: true` in our wrapper, throw a sentinel error, and route the caller to whichever cloud provider it wants (Gemini via AI Studio, Anthropic, Vertex, etc.).

Also: the handoff trigger is purely **token-distribution confidence**. Default threshold 0.7. It doesn't measure "did the model solve the user's problem." A confidently hallucinating small model cruises past the threshold. In our tests gemma-4-E2B returned `confidence: 0.98+` on every single call including the ones where it emitted plain-text tool calls. Handoff never would have fired.

**Recommendation:** treat `cloud_handoff` as "model isn't sure about its next token," not "model isn't sure about the answer." It's useful for catching obvious failures (gibberish, generation stuck), not for quality routing. Real quality routing is an application-level decision.

---

## 6. Where Cactus actually fits in *this* project

We tried Cactus in two places:

### 6a. Browser agent LLM (the hard mode) — *doesn't fit*

- System prompt alone is 6.7 K tokens (agent behavior + 13 tool defs).
- A single `read_page` on a real site (LinkedIn, Gmail) adds 15–25 K tokens to the conversation.
- At 190 tok/s prefill, each agent step is 35–60 s; hitting 120 s timeout on big-DOM turns is routine.
- Extension's `api.js` has a 120 s per-call timeout; we can't raise it without risk.

We switched the browser path to Gemini 2.5 Flash via AI Studio. Same pipeline, ~4 s per task. Confirmed working.

### 6b. Intent layer + voice STT (the natural fit) — *fits, but not load-bearing today*

Current state: Cactus is a *cold fallback* on both legs. It only runs if Whisper or Gemini errors out.

Better state for the hackathon narrative: **Cactus primary on both, cloud only as escalation.**

- **Voice STT**: flip `voice/transcribe.py` — Cactus Parakeet primary, Whisper fallback. Parakeet's per-call inference is 0.03 s; the cold-start dominates if you don't pre-warm at startup (`warmup()` is already the pattern for Whisper).
- **Intent parser**: flip `intent/parser.py` — Cactus primary via sidecar (keeps model warm, ~200 ms/call), Gemini only when `confidence < 0.7` or JSON parse fails. This is the Hybrid Router pattern the integration guide pitched, done application-side.

### 6c. PII / privacy gate (the killer app) — *fits best, not built*

Before the browser task string leaves the laptop for a cloud LLM, run it through Cactus: classify whether it contains PII (salary, SSN-ish, credentials), and either redact or surface approval. This is:

- Short prompt (a few hundred tokens).
- Pure classification — gemma-4-E2B wheelhouse.
- **Cannot be done in cloud** — the cloud is what we're protecting the data from.
- Demo-legible: "only sanitised task descriptions reach Gemini; your resume contents, contact names, and salary numbers stay on the laptop."

Scope: ~90 min. Would make Cactus load-bearing on every command.

---

## 7. Cactus strengths and weaknesses, one-liners

### Good at

- Short-context (<2 K tokens) text classification and structured extraction.
- Function calling when tools fit in one-shot prompts and the model is big enough.
- On-device voice (Parakeet via `cactus transcribe`).
- Mobile-first (their React Native / Swift / Kotlin SDKs are first-class).
- Tight control over decoding (tool RAG filtering, force_tools, stop_sequences) for protocol-sensitive tasks.

### Bad at

- Prefill on big prompts without the NPU mlpackage. CPU at ~190 tok/s on E2B, ~6 tok/s on E4B.
- Quality ceiling at 2B params for multi-step planning (confident hallucinations).
- Developer ergonomics: bare ctypes Python API, JSON-string arguments, schemas documented only in the engine repo.
- The hybrid handoff promise in its current form (`auto_handoff: true`) — hardcoded GCP IP, self-signed TLS, not production-usable.
- Competing with OS-baked models (Apple Intelligence, Gemini Nano in Chrome) on "zero-integration-cost on-device LLM" — those are coming.

---

## 8. Recommendations

### For Cactus

1. **Ship the `model.mlpackage` for the full gemma-4 family.** Without it, the "Apple NPU" pitch is encoder-only. With it, E4B becomes the reasonable default.
2. **Teach `cactus.py` to honour `CACTUS_LIB_PATH`.** Or have the brew formula symlink to where the shim looks. The current mismatch is the first pothole new developers hit.
3. **Update or retract the integration guide in circulation** — the `cactus_complete` kwargs example doesn't match the shipping Python API. Reached by more than one team today.
4. **Document `options_json` schema in the Python SDK docstring**, not only in `docs/cactus_engine.md`. Python devs expect the signature to be on the function.
5. **Reframe `cloud_handoff`**. In the pitch it sounds like quality routing; in reality it's token-distribution uncertainty. That's a useful signal for stuck-generation detection, not quality control. Different docs.
6. **Publish OpenAI-compatible endpoints from the Python SDK** — a `chat.completions.create`-shaped wrapper would let most existing agent code drop Cactus in with no changes.

### For this project (post-hackathon, if continued)

1. **Move intent parsing and voice STT to Cactus-primary.** They're the natural fits and they're almost-already wired.
2. **Build the PII gate (§6c).** This is where Cactus does work no cloud model can do for this product.
3. **Leave the browser agent on Gemini** until `gemma-4-E4B-it` with NPU prefill is available. Then re-evaluate.
4. **Keep the sidecar pattern.** The FastAPI wrapper solved the JSON-API / bindings / tempfile / lazy-import problem cleanly and is portable across languages.
5. **Wire the `await_confirmation` tool in the extension.** It's currently unwired, so the "pauses for your approval" line in the README is aspirational. Without it the confirmation gate never fires.

---

## 9. Files to read, in this branch

- `scripts/cactus_server.py` — sidecar wrapping the bare Python FFI.
- `executors/browser/agent/src/background/modules/providers/cactus-provider.js` — extension-side translator (Anthropic content blocks ↔ Cactus wire format with sentinel-token tool calls).
- `executors/browser/agent/server/src/llm/cactus.ts` — Node-side provider (used by the server-side agent loop; only the side-channel `mcp_get_info` / `mcp_escalate` path).
- `executors/browser/agent/src/background/modules/system-prompt.js` — the "HOW TO INVOKE TOOLS" preamble that fixed gemma's format failures.
- `~/Downloads/browser-agent/2026-04-19T*/log.json` — turn-by-turn logs from every real run, including the ones that failed. Useful for comparing gemma vs gemini behaviour on the same task.

---

Written at the end of day-1 of the hackathon, in good faith, from an engineer who wanted Cactus to work harder than it did today and still thinks there are genuine wins here — just narrower than the first pass suggested.
