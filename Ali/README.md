# YC Voice Agent

> "Tell your computer what to do."

A local-first voice agent that gives your computer hands — in your files *and* in your browser. Built for the [Cactus × YC Gemma 4 Voice Agents Hackathon](https://github.com/cactus-compute/cactus), April 18–19, 2026.

---

## What it does

You hold a key, speak a command, release. The agent:

1. Transcribes your voice on-device (Gemma 4 via Cactus, fallback: Whisper)
2. Parses your intent locally — your words never leave your laptop
3. Captures an initial on-device screen observation (screenshot + context), then routes the task to local tools (iMessage, Mail, Calendar, files) and/or the browser (LinkedIn, YC Apply, Gmail)
4. Iterates observe → decide → act → verify with Cactus-assisted action selection
5. Shows you exactly what it's about to do and waits for confirmation for irreversible actions
6. Executes — using your real browser session, your real resume, your real contacts

**Demo flow:** "Apply to a YC Fall 2026 batch company using my resume"
→ Finds `resume.pdf` on disk → Opens apply.yccompanyx.com → Fills the form → Pauses for your approval → Submits.

---

## Why local-first matters

The intent layer — the layer that sees your transcribed voice, your resume, your contacts — runs on-device via Cactus + Gemma 4. Your PII never hits a cloud server. 

---

## Architecture (Vision-First)

```
┌─────────────────────────────────────────────────────────────────┐
│                        User (voice)                             │
└───────────────────────────┬─────────────────────────────────────┘
                            │ hold Right Shift / menu bar button
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 1 — Voice Input                                          │
│  Push-to-talk audio capture → speech-to-text                    │
│  Primary: Gemma 4 voice via Cactus                              │
│  Fallback: whisper.cpp / faster-whisper (local)                 │
└───────────────────────────┬─────────────────────────────────────┘
                            │ raw transcript
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 2 — Intent Layer  [ON-DEVICE, Gemma 4 via Cactus]        │
│  Input:  raw transcript                                         │
│  Output: structured intent object                               │
│  { goal, target, uses_local_data, requires_browser, ... }       │
│  Jobs: classify goal | extract slots | flag required resources  │
│  Does NOT: write Playwright scripts, reason about DOM           │
└───────────────────────────┬─────────────────────────────────────┘
                            │ intent object
                            ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 3 — Orchestrator  [State Machine]                        │
│  0. Observe — always capture initial screenshot/context          │
│  1. Decide  — Cactus visual planner proposes next atomic action │
│  2. Act     — execute exactly one action                         │
│  3. Verify  — re-observe and continue until complete             │
│  4. Recover — retry | ask user | fallback | abort               │
└──────────────┬────────────────────────────────┬─────────────────┘
               │ local tasks                    │ browser tasks
               ▼                                ▼
┌──────────────────────────┐    ┌───────────────────────────────┐
│  Layer 4A — Local        │    │  Layer 4B — Browser           │
│  Executor                │    │  Executor (Playwright)        │
│  • AppleScript / JXA     │    │  • Persistent Chrome context  │
│    iMessage, Mail,       │    │    (user's real sessions)     │
│    Calendar, Contacts    │    │  • Site adapters: YC Apply,   │
│  • Filesystem (resume,   │    │    LinkedIn, Gmail, ...       │
│    cover letters, docs)  │    │  • General DOM agent fallback │
│  • Shell (gated)         │    │    (accessibility tree)       │
└──────────────┬───────────┘    └───────────────┬───────────────┘
               │                                │
               └────────────────┬───────────────┘
                                ▼
┌─────────────────────────────────────────────────────────────────┐
│  Layer 5 — Confirmation Gate                                    │
│  Surface pending action → voice or click approval → execute     │
│  "I'm about to submit your YC app with resume.pdf. Send it?"    │
└─────────────────────────────────────────────────────────────────┘
```

---

## Project Structure

```
YC_Voice_Agent/
├── voice/                  # Layer 1 — audio capture + STT
│   ├── capture.py          # Push-to-talk hotkey + mic recording
│   ├── transcribe.py       # Cactus/Gemma 4 STT, Whisper fallback
│   └── __init__.py
├── intent/                 # Layer 2 — on-device intent parsing
│   ├── parser.py           # Gemma 4 via Cactus → intent object
│   ├── schema.py           # IntentObject dataclass + known goals
│   └── __init__.py
├── orchestrator/           # Layer 3 — state machine + routing
│   ├── orchestrator.py     # Main orchestrator class
│   ├── plans.py            # Hardcoded plans for known flows
│   ├── state.py            # Task state object
│   ├── router.py           # local / browser / hybrid routing
│   └── __init__.py
├── executors/
│   ├── local/              # Layer 4A — macOS native tools
│   │   ├── applescript.py  # iMessage, Mail, Calendar, Contacts
│   │   ├── filesystem.py   # Resume/doc lookup by alias
│   │   ├── shell.py        # Gated shell executor
│   │   └── __init__.py
│   └── browser/            # Layer 4B — Playwright browser
│       ├── browser.py      # Persistent Chrome context setup
│       ├── adapters/       # Site-specific Playwright flows
│       │   ├── yc_apply.py
│       │   ├── linkedin.py
│       │   └── gmail.py
│       ├── dom_agent.py    # General DOM agent fallback
│       └── __init__.py
├── ui/                     # Layer 5 — confirmation gate + status
│   ├── menu_bar.py         # macOS menu bar button (push-to-talk)
│   ├── confirmation.py     # Pre-action confirmation dialog
│   └── __init__.py
├── config/
│   ├── settings.py         # Paths, hotkeys, Chrome profile, etc.
│   ├── resources.py        # Named file aliases (resume, cover letter)
│   └── known_intents.py    # Enumeration of supported goals
├── scripts/
│   ├── setup_macos_perms.sh  # Grant macOS permissions checklist
│   ├── debug_local_flow.py   # Parse/plan/execute from transcript or WAV
│   └── test_demo_flow.py     # End-to-end demo smoke test
├── main.py                 # Entry point — ties all layers together
├── requirements.txt
├── .gitignore
└── README.md
```

---

## Demo Flows (v1)

| Voice Command | Route | Tools Used |
|---|---|---|
| "Apply to YC Fall 2026 using my resume" | browser | yc_apply adapter + filesystem |
| "Text Hanzi I'll be 10 minutes late" | local | AppleScript → Messages |
| "Send my resume to the job I have open in Chrome" | browser | LinkedIn adapter |
| "Add a meeting with Ethan tomorrow at 3pm" | local | AppleScript → Calendar |
| "Draft a cover letter for the Stripe job and save it" | local | filesystem + shell |

---

## Setup

### 1. Install dependencies

```bash
pip install -r requirements.txt
playwright install chromium
```

### 2. Configure paths

Edit `config/settings.py`:
- `CHROME_PROFILE_PATH` — your real Chrome profile directory
- `RESUME_PATH` — path to your resume PDF
- `CACTUS_MODEL` — Gemma 4 model identifier

### 3. macOS permissions (do this Saturday afternoon before the demo)

```bash
bash scripts/setup_macos_perms.sh
```

Permissions required:
- Accessibility (for hotkey capture)
- Full Disk Access (for file reads)
- Automation: Messages, Mail, Calendar, Contacts

### 4. Run

```bash
python main.py
```

Hold **Option** (or click the menu bar button) and speak your command.

On **first launch**, Ali builds a focused content index. The default scope is:

- `~/Documents`, `~/Downloads`, `~/Desktop`
- `/Applications` (so "open Slack" works)
- **Contacts** (via Contacts.app — the running terminal needs Contacts
  permission)
- **Calendar** (reads `.ics` files under `~/Library/Calendars/` — needs Full
  Disk Access)
- **Messages** (reads `~/Library/Messages/chat.db` — needs Full Disk Access,
  last 365 days by default)

To widen the filesystem scope to the full home directory:

```bash
python main.py --full-disk
# or:
ALI_INDEX_FULL_DISK=1 python main.py
```

The index lives at `~/.cache/ali/index/` and is reused on subsequent runs
(incrementally — unchanged files are skipped, only new/modified files get
re-embedded). To force a clean rebuild:

```bash
python main.py --rebuild-index
```

…or click **Rebuild Index…** in the menu bar.

To tune which non-filesystem sources are pulled in:

```bash
# disable messages only
ALI_INDEX_SOURCES="contacts,calendar" python main.py

# index none of them
ALI_INDEX_SOURCES="" python main.py

# shorter history for Messages/Calendar
ALI_INDEX_SOURCE_HISTORY_DAYS=30 python main.py
```

With the index in place Ali can answer questions grounded in your files,
entirely on-device via Gemma 4 (Cactus):

- "Who am I?" → answered from your macOS user info + Contacts Me card.
- "What's my email?"
- "When did I last update my resume?"
- "What does my contract say about termination?"
- "Summarize my notes about OKRs."

Cloud fallback (Gemini) is opt-in:

```bash
export ALI_ALLOW_CLOUD_FALLBACK=1
```

---

## Safety / Dry Run

To rehearse the full flow without performing irreversible actions, run:

```bash
export VOICE_AGENT_DRY_RUN=1
python main.py
```

In dry-run mode, the agent still transcribes, parses, plans, and executes safe steps,
but skips final write actions like sending iMessages, creating calendar events, and
submitting YC applications.

---

## Debugging Without Hotkey

Use `scripts/debug_local_flow.py` to test transcription + intent parsing + visual
execution loop without running the menu bar listener.

```bash
# 1) Record from your mic, save WAV, then transcribe + parse
python scripts/debug_local_flow.py --audio --record-seconds 6

# 2) Reuse a saved WAV file later
python scripts/debug_local_flow.py --audio debug_recordings/debug_YYYYMMDD_HHMMSS.wav

# 3) Optionally run the orchestrator too (recommended with dry run)
VOICE_AGENT_DRY_RUN=1 python scripts/debug_local_flow.py --audio --execute --auto-approve

# 4) Save visual observation artifacts from each observe loop
python scripts/debug_local_flow.py --transcript "Apply to YC using my resume" --execute --observe-dir debug_observations
```

By default, microphone recordings are saved under `debug_recordings/`, so you can share
the exact file path when debugging STT/intent behavior.

---

## Local Troubleshooting

### 1) "This process is not trusted! Input event monitoring will not be possible"

`pynput` needs macOS Accessibility permission to listen for the push-to-talk key.

- Open System Settings → Privacy & Security → Accessibility
- Add and enable your terminal app (Terminal / iTerm / VS Code)
- Restart the terminal and rerun `python main.py`

If you want to debug without hotkey capture first, use:

```bash
python scripts/debug_local_flow.py --transcript "Text Hanzi I'll be 10 minutes late"
```

### 2) Very short captures ("Captured 0.0s", "Too short — ignored")

- Hold Right Shift a bit longer before speaking
- Verify the active mic line printed at startup, for example:
  `[voice] Active mic: #4 "MacBook Air Microphone" (48000 Hz)`
- Switch your macOS input device if the wrong mic is active

### 3) Cactus intent parse error (`unrecognized arguments: --max-tokens ...`)

This is a Cactus CLI version mismatch. The code now uses a compatible fallback
invocation, but if you still see this:

- update cactus to a recent version, or
- use the debug runner to isolate parser behavior:

```bash
python scripts/debug_local_flow.py --transcript "Apply to YC using my resume"
```

### 4) Missing local file alias warnings at startup

If preflight warns about missing files (resume, cover letter, linkedin export),
update alias paths in `config/resources.py` to real local files.

---

## Tech Stack

| Layer | Technology |
|---|---|
| Voice STT | Gemma 4 via [Cactus](https://github.com/cactus-compute/cactus) / whisper.cpp fallback |
| Intent Parsing | Gemma 4 on-device (Cactus) |
| Browser Automation | Playwright + persistent Chrome context |
| macOS Integration | AppleScript / JXA via osascript |
| UI | Rumps (macOS menu bar) + tkinter dialogs |
| Language | Python 3.11+ |

---

## Team

- **Alspencer Omondi**
- **Hanzi Li**
- **Korin Aldam-Tajima**

Built at the Cactus × YC Gemma 4 Voice Agents Hackathon, San Francisco, April 18–19 2026.

---

## Privacy

The intent layer runs entirely on-device. Your voice transcript, resume content, and personal data are processed locally by Gemma 4 via Cactus. Nothing leaves your laptop unless you explicitly trigger a browser action you have approved.
