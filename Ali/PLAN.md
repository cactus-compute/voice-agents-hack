# Build Plan — YC Voice Agent
Hackathon: April 18–19, 2026 | Submissions close: 11am Sunday

---

## Timeline

### Saturday (Day 1)
| Time | What |
|---|---|
| 10am–1pm | Setup, permissions, Cactus orientation, skeleton |
| 1pm–6pm | Core loop: voice → intent → orchestrator → executor |
| 6pm–10pm | Site adapters (YC Apply first), confirmation gate |
| 10pm–2am | Polish demo flow, error handling, recovery |

### Sunday (Day 2)
| Time | What |
|---|---|
| 9am–11am | Full demo run-throughs, fix blockers |
| 11am | Submissions close |
| 1pm–2pm | Demo presentation |

---

## Build Sequence

### Phase 0 — Saturday morning (before lunch)
- [ ] All 4 teammates clone repo, confirm Python env works
- [ ] Run `bash scripts/setup_macos_perms.sh` on the demo machine
- [ ] Get Cactus installed, confirm Gemma 4 loads
- [ ] Confirm Chrome persistent context opens to a logged-in session
- [ ] Confirm `osascript` can send a test iMessage

### Phase 1 — Voice capture (Layer 1)
- [ ] `voice/capture.py` — hold Option key → start recording, release → stop
- [ ] Raw audio bytes written to temp file
- [ ] `voice/transcribe.py` — pipe audio to Cactus/Gemma 4 STT
- [ ] Fallback path: if Cactus STT fails, use `faster-whisper` locally
- [ ] Test: speak "apply to YC" → get transcript string

### Phase 2 — Intent parsing (Layer 2)
- [ ] `intent/schema.py` — define `IntentObject` dataclass and `KnownGoal` enum
- [ ] `intent/parser.py` — prompt Gemma 4 with transcript, parse JSON response
- [ ] Prompt design: classify goal, extract slots, flag resource needs
- [ ] Test: transcript "apply to YC Fall 2026 using my resume" → correct intent object
- [ ] Fallback: if parse fails, ask user to rephrase (don't crash)

### Phase 3 — Orchestrator (Layer 3)
- [ ] `orchestrator/state.py` — TaskState object: goal, plan, step_index, collected_data, status
- [ ] `orchestrator/plans.py` — hardcoded plan for `apply_to_job`, `send_message`, `add_calendar_event`
- [ ] `orchestrator/router.py` — given intent, return ordered list of executor calls
- [ ] `orchestrator/orchestrator.py` — run plan, handle step failures, emit state updates
- [ ] Test: intent object → correct plan selected → first step executed

### Phase 4A — Local executor (Layer 4A)
- [ ] `executors/local/filesystem.py` — named alias lookup (resume, cover letter, etc.)
- [ ] `executors/local/applescript.py` — send iMessage, send Mail, create Calendar event
- [ ] `executors/local/shell.py` — gated shell with allowlist
- [ ] Test: "text Hanzi I'll be late" → iMessage sends (to test number first!)

### Phase 4B — Browser executor (Layer 4B)
- [ ] `executors/browser/browser.py` — Playwright persistent context, Chrome profile path
- [ ] `executors/browser/adapters/yc_apply.py` — **primary demo adapter**
  - Navigate to apply.ycombinator.com
  - Map intent slots to form fields
  - Upload resume PDF
  - Pause before submit → confirmation gate
- [ ] `executors/browser/adapters/linkedin.py` — Easy Apply flow (stretch)
- [ ] `executors/browser/dom_agent.py` — general fallback (stretch/v2)
- [ ] Test: run YC adapter on staging/personal account, confirm form fills correctly

### Phase 5 — Confirmation gate (Layer 5)
- [ ] `ui/confirmation.py` — modal dialog: show pending action text + Yes/No buttons
- [ ] Voice confirmation: "yes" or "send it" → approve; "no" or "cancel" → abort
- [ ] Wire into orchestrator: all write actions pause here before executing
- [ ] `ui/menu_bar.py` — macOS menu bar icon, push-to-talk button, status indicator

### Phase 6 — Integration + demo polish
- [ ] `main.py` wires all layers in a loop
- [ ] Full demo flow works end-to-end: voice → YC form filled → confirmation → submit
- [ ] Second demo flow: voice → iMessage sent
- [ ] Error states handled gracefully (no crashes on stage)
- [ ] Status display shows current step in orchestrator

---

## Demo Script (rehearse this)

1. "Watch — I'm going to apply to YC using just my voice."
2. Hold Option key. Say: *"Apply to the YC Fall 2026 batch using my resume."* Release.
3. Show transcript appears. Show intent object parsed locally.
4. Browser opens, navigates to apply.ycombinator.com, fields start filling.
5. Confirmation dialog: "I'm about to submit your YC application with resume.pdf. Send it?"
6. Say "yes" → submits (or cancel on stage to not actually submit).
7. "Everything that just happened — the parsing, the intent extraction — ran on my laptop. Nothing left my machine."

---

## Risk Register

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cactus STT unstable | Medium | Whisper fallback ready Day 1 |
| Gemma 4 intent parsing unreliable | Medium | Hardcode 3 demo intents with fallback JSON |
| YC Apply form changes | Low | Test adapter Saturday afternoon |
| Chrome profile path wrong | Low | Config file, test Sunday 9am |
| macOS permission dialogs during demo | High | Grant all permissions Saturday, test reboot |
| Orchestrator infinite loop | Medium | Max steps limit + hard timeout |
| Demo machine ≠ dev machine | Low | All run on single MacBook, no server deps |

---

## Division of Labor (suggestion)

| Person | Layer |
|---|---|
| Alspencer | Orchestrator + main loop |
| Hanzi | Browser executor + YC Apply adapter |
| Ethan | Voice capture + Cactus/Gemma 4 integration |
| Korin | UI (menu bar, confirmation gate) + demo polish |

Overlap: everyone can touch intent/schema.py and plans.py — they're the connective tissue.

---

## Key Decisions

**Push-to-talk over wake word** — wake word is flaky and will die on stage. Option key hold is legible, demonstrable, and debuggable.

**State machine over agent loop** — every step is inspectable and interruptible. No runaway agents on stage.

**Site adapters over general DOM agent** — 50-100 lines of Playwright per site is unbeatable for demo reliability. General agent is v2.

**Hardcoded plans for known flows** — the LLM fills in slots, not the whole recipe. This is what makes v1 reliable.

**Persistent Chrome context** — no re-login, no cookie setup, no OAuth dance. You drive the browser you're already logged into.

**Confirmation gate on all writes** — this is not a limitation. It's the feature that makes the agent trustable and makes the demo pauseable.
