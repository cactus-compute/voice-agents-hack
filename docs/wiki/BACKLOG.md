

# Backlog

## 🎯 Goal
Build a demoable **on-device privacy layer for Cactus + Gemma voice agents** that:
- detects sensitive data locally
- applies HIPAA-first policies
- routes requests (`local-only`, `masked-send`, `safe-to-send`)
- can be plugged into another hackathon project

---

## 🧠 Product Principles
- Privacy decisions happen **on-device first**
- Demo must feel **real-time and conversational**
- Prioritize **HIPAA scenarios**
- Keep everything **simple and explainable in <30 sec**
- Build **thin vertical slices**, not broad infra

---

## 🌟 North Star Demo
User speaks into a Cactus + Gemma voice agent.

Masker:
1. detects PHI/PII locally
2. applies policy
3. chooses route
4. explains what happened

AND

👉 another hackathon team can plug into Masker in minutes

---

# 🔴 P0 — Demo Critical

## 1. Voice Loop
**Goal:** End-to-end working voice interaction

- [ ] Mic input
- [ ] STT (Cactus)
- [ ] Response (text or voice)
- [ ] Support 3 scripted scenarios

**Done when:**
- Voice → response works reliably

---

## 2. Sensitive Detection
**Goal:** Detect PHI/PII locally

- [ ] SSN
- [ ] phone
- [ ] email
- [ ] names / identifiers
- [ ] basic health context

**Output format:** structured spans

**Done when:**
- demo inputs correctly detect entities

---

## 3. Policy Engine
**Goal:** Decide how to handle data

Routes:
- `local-only`
- `masked-send`
- `safe-to-send`

Policies:
- [ ] Base
- [ ] Logging (strict)
- [ ] Clinical (context-aware)

**Done when:**
- each scenario maps to correct route

---

## 4. Masking / Tokenization
**Goal:** Transform sensitive data

- [ ] Mask `[MASKED]`
- [ ] Optional tokenization
- [ ] Preserve context for LLM

**Done when:**
- masked output works for all scenarios

---

## 5. Routing Layer
**Goal:** Execute decision

- [ ] local execution for sensitive
- [ ] masked forwarding
- [ ] safe forwarding

**Done when:**
- all 3 routes demonstrated

---

## 6. Trace UI (Demo Critical)
**Goal:** Show what happened

- [ ] transcript
- [ ] detected entities
- [ ] policy used
- [ ] route chosen
- [ ] masked output

**Done when:**
- judge understands flow visually

---

## 7. External Integration
**Goal:** Plug into another hackathon agent

- [ ] simple wrapper OR local proxy
- [ ] <5 lines integration
- [ ] quick demo

**Done when:**
- 1 external project integrated or simulated

---

# 🟡 P1 — High Value

## 8. Auto Attach Wrapper

- [ ] `auto_attach()`
- [ ] minimal code change

---

## 9. Explanation Layer

- [ ] “We masked your SSN…”
- [ ] “This stayed local…”

---

## 10. Latency Metrics

- [ ] STT time
- [ ] detection time
- [ ] routing time
- [ ] total latency

---

# 🟢 P2 — Nice to Have

## 11. Privacy Controls

- [ ] sensitivity slider
- [ ] strict mode toggle

---

## 12. Token Vault (Mock)

- [ ] store tokenized values
- [ ] show encryption modes

---

## 13. Packaging

- [ ] simple SDK
- [ ] example snippet

---

# 🎬 Demo Scenarios

## Scenario A — Personal Info
“Text Sarah my address is 4821 …”
→ expected: masked-send / local-only

---

## Scenario B — Healthcare
“I have chest pain and my insurance ID is …”
→ expected: local-only / masked-send

---

## Scenario C — Safe Query
“What’s the weather tomorrow?”
→ expected: safe-to-send

---

## Scenario D — Work Context
“Summarize Apollo escalation for Redwood account”
→ expected: masked-send

---

# 🤖 Agent Work Split

## Codex
- detection
- policy engine
- masking

## Ona
- UI
- demo
- explanations

## Cursor
- integration
- routing
- wrappers

## You
- merge + demo
- external integration

---

# 🏁 Definition of Done

- [ ] voice demo works end-to-end
- [ ] HIPAA scenario is compelling
- [ ] 1 external integration works
- [ ] demo is explainable in <1 min
