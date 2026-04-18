<img src="assets/banner.png" alt="Masker banner" style="border-radius: 30px; width: 60%;">

# Masker Voice Agents Hack

Masker Voice Agents Hack explores a simple hypothesis: voice AI becomes more trustworthy when sensitive context can be detected, classified, and handled before it leaves the device.

The goal of this project is to prototype an on-device privacy layer for voice interactions on mobile devices and wearables, using local intelligence to decide what should stay local, what should be masked, and what is safe to route onward.

## Project Thesis

If Masker can detect sensitive speech locally before it is forwarded upstream, voice AI becomes safer, faster, and easier to trust.

That creates a compelling extension to the main product:

- Mask PII before it reaches the LLM.
- Decide locally whether a request should stay on-device, be masked, or be safely routed.
- Build a voice-native privacy experience that feels real-time instead of bolted on.

## Scope

This repo is scoped as a prototype, not the full Masker platform.

### In Scope

- A voice-first demo built with Gemma 4 on Cactus.
- On-device speech understanding for short live requests.
- Detection of sensitive content in spoken input.
- Local privacy policy decisions such as `local-only`, `masked-send`, and `safe-to-send`.
- A clear demonstration of how on-device privacy logic complements the main Masker proxy product.

### Out of Scope

- Rebuilding the full `navi25/masker` platform in this repo.
- Production-grade compliance guarantees.
- Broad portal, dashboard, or customer management features.
- Large integration surface area.
- General-purpose assistant behavior.

## Relationship To The Main Product

The public `masker` repo answers:
"How do we protect sensitive data before a voice agent sends it to an LLM?"

This repo answers:
"How early can we make that privacy decision, and can we make it directly on-device?"

Together, the story becomes stronger:

- `masker` is the production-facing masking and compliance layer.
- `masker-voice-agents-hack` is the experimental edge intelligence layer.

## Why Cactus + Gemma 4

This prototype is built around Gemma 4 on Cactus because the stack supports the exact product question we want to test:

- Can we do meaningful privacy-aware reasoning on-device?
- Can a voice interaction still feel low-latency?
- Can local classification improve trust before the request ever touches the network?

## Prototype Flow

1. A user speaks into the device.
2. The request is transcribed and analyzed locally.
3. Sensitive entities or risky context are detected.
4. A local policy layer decides whether the request is `local-only`, `masked-send`, or `safe-to-send`.
5. The result is either handled locally or forwarded as a masked / approved request into the broader Masker pipeline.

## Why This Matters

The current Masker product is already valuable because it protects voice-agent traffic before it reaches an LLM.

This repo explores a sharper product wedge:
privacy decisions that happen before sensitive speech even leaves the device.

That matters for:

- healthcare and compliance-sensitive workflows,
- enterprise users speaking about internal projects or customer details,
- and everyday users who want voice convenience without over-sharing by default.

## Success Criteria

This repo succeeds if it proves three things:

1. On-device privacy detection is feasible in a voice workflow.
2. The latency still feels conversational.
3. The prototype expands the Masker story from "PII-safe voice agents" to "privacy-first voice AI from the edge inward."

## Roadmap

### Phase 1

- Stand up the local voice loop
- Detect basic PII classes
- Implement route decisions
- Show a working end-to-end demo

### Phase 2

- Improve sensitivity classification
- Add user-visible privacy explanations
- Measure latency and masking quality
- Connect the prototype cleanly to the main Masker flow

### Phase 3

- Explore mobile and wearable packaging
- Expand local policy customization
- Use learnings to inform the core Masker platform roadmap

## Repository Intent

This repo should publicly read as:

"The experimental on-device voice privacy layer for Masker."

It exists to document the idea, prove the technical wedge, and show how edge reasoning can strengthen the broader Masker product.

<img src="assets/banner.png" alt="Masker banner" style="border-radius: 30px; width: 60%;">

# 🛡️ Masker  
### Programmable Compliance Layer for Cactus + Gemma Voice Agents

> **Masker is a real-time privacy layer that makes local voice AI safe to ship.**  
It detects, transforms, and controls sensitive data before it reaches Gemma—and filters what comes out.

---

## 🚨 Why Masker (for THIS hackathon)

Everyone here is building:
- voice agents  
- using Cactus + Gemma  

But:

- Users speak **PHI/PII** (SSN, medical info, phone numbers)
- That data flows into:
  - prompts  
  - logs  
  - responses  

> Even local AI is **not automatically private**

- Logs leak  
- Responses leak  
- Agents mishandle sensitive data  

---

## 💡 What Masker Does

Masker sits **inside your Cactus + Gemma pipeline**:

```
User → Microphone → Cactus STT → Masker → Gemma → Masker → Cactus TTS → Speaker
```

---

## 🔧 Core Capabilities

- 🔍 Detect PHI/PII (SSN, phone, email, patient info)
- 🔁 Transform (mask, tokenize, block)
- 🧠 Apply policies (HIPAA-first)
- 🧾 Audit (trace what was filtered)
- ⚡ Runs locally (low latency, Rust-friendly)

---

## 🧠 Smart Privacy (No Compliance Toggles)

> Don’t configure HIPAA vs GDPR. Masker figures it out.

- Context-aware detection  
- Auto-applies safeguards  
- Works across healthcare + general PII  

---

## 🏥 HIPAA-First (Hackathon Scope)

Masker ships with **3 simple policies**:

### 1. Base Policy
- Detect identifiers (SSN, phone, email)  
- Mask or tokenize  
- Allow symptoms  

---

### 2. Logging Policy (Strict)
- No PHI in logs  
- Store only masked or tokenized data  

---

### 3. Clinical Policy (Context-aware)
- Allow medical descriptions  
- Block direct identifiers  

---

## ⚙️ Integration (Cactus + Gemma)

### 🟢 Option 1 — Auto Attach (recommended)

```python
from masker import auto_attach

auto_attach()

response = gemma.generate(user_input)
```

- No major code changes  
- Feels automatic  

---

### 🔵 Option 2 — Explicit Wrapper

```python
from masker import filter_input, filter_output

safe_input = filter_input(user_input)
response = gemma.generate(safe_input)
safe_output = filter_output(response)
```

---

### 🟡 Option 3 — Local Interceptor (advanced)

```
App → Masker (local) → Gemma
```

---

## 🎬 Demo

### Demo 1 — Cactus + Gemma Healthcare Agent

- Run voice interaction  
- User speaks sensitive data  
- Show:
  - detection  
  - transformation  
  - safe input to model  
  - safe output  

---

### Demo 2 — Another Hackathon Agent

- Plug Masker into another team’s agent  
- Show same protection layer  

> **Goal:** prove Masker works across agents  

---

## 🔐 Trust Models

### Masker Managed (Default)
- Fast setup  
- Masker handles encryption  

---

### Customer Managed (AWS KMS)
- Customer controls keys  
- Strong enterprise story  

---

## 🧩 Architecture

```
Text Input
   ↓
Detection (PII / PHI)
   ↓
Policy Engine
   ↓
Transformation
   ↓
Gemma
   ↓
Output Filter
```

---

# 🚀 24-Hour Hackathon Plan

## 🎯 Final Goal

- Masker integrated into:
  - 1 primary Cactus + Gemma agent  
  - 1 external hackathon agent  
- Real-time masking working  
- HIPAA policies applied  
- Clear demo + story  

---

## ⏱️ Execution Plan

### 🟢 Stage 1 (Hours 0–4) — Core Engine

**Goal:** working masking pipeline

- [ ] Detect:
  - SSN  
  - phone  
  - email  
- [ ] Transform:
  - `[MASKED]`  
  - simple tokenization  
- [ ] Build:
  - `filter_input()`  
  - `filter_output()`  

---

### 🔵 Stage 2 (Hours 4–8) — Gemma Wrapper

**Goal:** attach to model

- [ ] Build wrapper:
  - `auto_attach()` OR `wrap(generate)`  
- [ ] Intercept input + output  
- [ ] Test with Gemma locally  

---

### 🟡 Stage 3 (Hours 8–14) — Policies + Trace UI

- [ ] Define policies:
  - Base  
  - Logging  
  - Clinical  
- [ ] Build minimal UI:
  - input  
  - output  
  - trace  

---

### 🔴 Stage 4 (Hours 14–20) — Primary Agent Integration

- [ ] Integrate with your main Cactus + Gemma agent  
- [ ] Run voice flow  
- [ ] Show real-time masking  

---

### 🟣 Stage 5 (Hours 20–24) — External Agent Integration

- [ ] Find 1 healthcare agent  
- [ ] Integrate Masker  
- [ ] Record fallback demo  

---

## 🧠 Success Criteria

- [ ] Real-time masking works  
- [ ] HIPAA policies applied  
- [ ] Demo polished  
- [ ] 1 external integration  
- [ ] Clear story  

---

## 🏁 Final Pitch

> “Everyone here is building voice agents with Cactus and Gemma.  
Masker is the layer you add before you ship—to make them safe.”

---

## 💥 One-liner

> **Masker is a real-time privacy layer for local voice agents.**