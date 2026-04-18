

# AGENTS

This file defines how multiple coding agents collaborate to build Masker during the hackathon.

---

## 🎯 Objective

Build a demoable **on-device privacy layer for Cactus + Gemma voice agents** that:
- detects sensitive speech locally
- applies HIPAA-first policies
- routes requests (`local-only`, `masked-send`, `safe-to-send`)
- explains decisions in real-time

---

## 🧠 Core Principle

> Optimize for a **compelling demo in 24 hours**, not a perfect system.

---

## 🧩 Agents & Roles

### 1. 🧠 Codex — Privacy Intelligence Agent

**Focus:** Core logic

Owns:
- PII/PHI detection
- Policy engine
- Routing decisions
- Masking/tokenization

Should:
- Be deterministic
- Be testable
- Define clean input/output contracts

Avoid:
- UI work
- Integration plumbing

---

### 2. 🎨 Ona — Demo & UX Agent

**Focus:** Demo clarity

Owns:
- Trace UI
- Explanation layer
- Demo scenarios

Should:
- Make system understandable in seconds
- Focus on visual clarity

Avoid:
- Core logic changes

---

### 3. 🔌 Cursor — Integration Agent

**Focus:** Making Masker usable

Owns:
- Voice loop plumbing
- Routing execution
- Gemma wrapper (`auto_attach`)
- External integration path

Should:
- Minimize integration effort
- Keep APIs simple

Avoid:
- Rebuilding detection logic

---

### 4. 🧭 You — Orchestrator

**Focus:** Shipping

Owns:
- Prioritization
- Merging work
- Demo narrative
- External team integration

---

## 🔗 Contracts Between Agents

### Detection Output (Codex → Others)

```json
{
  "entities": [{ "type": "ssn", "value": "123-45-6789" }],
  "risk_level": "high"
}
```

---

### Policy Decision (Codex → Cursor)

```json
{
  "route": "masked-send",
  "policy": "hipaa_base"
}
```

---

### Trace Event (All → Ona)

```json
{
  "stage": "masking",
  "message": "Masked SSN"
}
```

---

## ⚙️ Working Model

Each agent works in **separate areas**:

- Codex → `privacy`, `policy`, `masking`
- Ona → `ui`, `demo`
- Cursor → `integration`, `routing`

Avoid editing same files.

---

## 🚀 Execution Flow

1. Codex builds detection + policy
2. Cursor wires routing + wrapper
3. Ona builds UI + demo
4. You integrate + test

---

## 📦 Branch Strategy

- `codex/privacy`
- `cursor/integration`
- `ona/ui`
- `main` for merge

---

## 📋 Handoff Template

Each agent should leave:

```md
### Status
- What works
- What is blocked
- What changed
- What next agent needs
```

---

## 🧠 Prompting Guide

Use:
- Codex → logic + tests
- Ona → UI + storytelling
- Cursor → integration + wrappers

---

## 🏁 Definition of Success

- Working voice demo
- HIPAA scenario works
- One external integration
- Demo explainable in <1 minute

---

## 💥 Key Reminder

> Keep it simple. Make it work. Make it obvious.
