"""
Layer 2 — Intent Parser

Priority order:
  1. Gemini API (via google-generativeai) — fast, reliable, sub-second
  2. Cactus CLI (on-device Gemma 4) — private, but slow on CPU without ANE
  3. Rule-based fallback — covers the 3 core demo flows with no network

The demo story: audio STT runs on-device (Cactus/Gemma 4 audio tower).
Intent parsing uses Gemini because text generation needs a GPU/ANE to be
fast enough for real-time use. Privacy note: the transcript (text) goes to
Gemini, but the raw audio never leaves the device.
"""

import asyncio
import json
import os
import re
import shutil
from urllib.parse import quote_plus

from intent.schema import IntentObject, KnownGoal
from config.settings import CACTUS_GEMMA4_MODEL, GEMINI_API_KEY


# #region agent log
def _dlog(loc: str, msg: str, data: dict, hid: str = "H12") -> None:
    try:
        import json as _j, os as _o, time as _t
        _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
        _o.makedirs(_o.path.dirname(_p), exist_ok=True)
        with open(_p, "a") as _f:
            _f.write(_j.dumps({
                "sessionId": "4ea166",
                "hypothesisId": hid,
                "location": loc,
                "message": msg,
                "data": data,
                "timestamp": int(_t.time() * 1000),
            }) + "\n")
            _f.flush()
    except Exception:
        pass
# #endregion

# ── Backend availability checks ───────────────────────────────────────────────
try:
    from google import genai as _genai  # type: ignore
    GEMINI_AVAILABLE = bool(GEMINI_API_KEY)
except ImportError:
    GEMINI_AVAILABLE = False

CACTUS_CLI = shutil.which("cactus")
CACTUS_AVAILABLE = CACTUS_CLI is not None

# ── Prompt ────────────────────────────────────────────────────────────────────
SYSTEM_PROMPT = """You are an intent classifier for a voice agent.
Given a voice transcript, output a JSON object with EXACTLY these fields:
{
  "goal": one of [apply_to_job, send_message, send_email, add_calendar_event, open_url, find_file, unknown],
  "target": {"type": "url_or_search|contact|file", "value": "..."},
  "uses_local_data": ["resume" | "cover_letter" | "attachment" | "document" | "deck" | "contacts" | "calendar" | ...],
  "requires_browser": true|false,
  "requires_submission": true|false,
  "slots": { ...goal-specific key-value pairs extracted from the transcript, including "file_query" when the user references a file... }
}
Use "find_file" for requests like "find my resume", "where is X", "open my deck".
Include "attachment" / "document" / "deck" in uses_local_data whenever the
user asks to attach, send, or email a file.
Output ONLY the JSON. No explanation."""


async def parse_intent(transcript: str) -> IntentObject:
    """
    Parse a raw transcript into an IntentObject.

    Priority:
      1. Rule-based  — instant, 100% reliable for the 3 demo flows
      2. Gemini      — handles anything the rules don't recognise
      3. Cactus      — on-device fallback if Gemini is unavailable
    """
    # Rule-based covers the demo flows instantly — don't burn a network call for those
    rule = _rule_based_parse(transcript)
    # #region agent log
    _dlog(
        "intent:parse_intent:rule",
        "rule-based candidate evaluated",
        {"transcript": transcript, "rule_goal": rule.goal.value},
        "H12",
    )
    # #endregion
    if rule.goal.value != "unknown":
        # #region agent log
        _dlog(
            "intent:parse_intent:final",
            "rule-based intent selected",
            {"transcript": transcript, "final_goal": rule.goal.value, "source": "rule"},
            "H12",
        )
        # #endregion
        return rule

    # Unknown intent — ask Gemini
    if GEMINI_AVAILABLE:
        try:
            gem = await _parse_with_gemini(transcript)
            # #region agent log
            _dlog(
                "intent:parse_intent:final",
                "gemini intent selected",
                {"transcript": transcript, "final_goal": gem.goal.value, "source": "gemini"},
                "H12",
            )
            # #endregion
            return gem
        except Exception as e:
            print(f"[intent] Gemini failed ({e}), trying Cactus")
            # #region agent log
            _dlog(
                "intent:parse_intent:gemini_error",
                "gemini parse failed",
                {"transcript": transcript, "err": str(e)[:180]},
                "H12",
            )
            # #endregion

    if CACTUS_AVAILABLE:
        try:
            cat = await _parse_with_cactus(transcript)
            # #region agent log
            _dlog(
                "intent:parse_intent:final",
                "cactus intent selected",
                {"transcript": transcript, "final_goal": cat.goal.value, "source": "cactus"},
                "H12",
            )
            # #endregion
            return cat
        except Exception as e:
            print(f"[intent] Cactus failed ({e}), returning unknown intent")
            # #region agent log
            _dlog(
                "intent:parse_intent:cactus_error",
                "cactus parse failed",
                {"transcript": transcript, "err": str(e)[:180]},
                "H12",
            )
            # #endregion

    # #region agent log
    _dlog(
        "intent:parse_intent:final",
        "fallback unknown intent selected",
        {"transcript": transcript, "final_goal": rule.goal.value, "source": "fallback_unknown"},
        "H12",
    )
    # #endregion
    return rule  # already unknown


async def _parse_with_gemini(transcript: str) -> IntentObject:
    prompt = f"{SYSTEM_PROMPT}\n\nTranscript: {transcript}"
    loop = asyncio.get_event_loop()

    def _call():
        client = _genai.Client(api_key=GEMINI_API_KEY)
        response = client.models.generate_content(
            model="gemini-2.5-flash-lite",
            contents=prompt,
            config=_genai.types.GenerateContentConfig(
                temperature=0.0,
                max_output_tokens=256,
            ),
        )
        return response.text

    raw = await loop.run_in_executor(None, _call)
    return _parse_json_response(raw, transcript)


async def _parse_with_cactus(transcript: str) -> IntentObject:
    prompt = f"{SYSTEM_PROMPT}\n\nTranscript: {transcript}"
    # Keep CLI args minimal for broad cactus version compatibility.
    # Some installs reject "--max-tokens"/"--temperature" for `cactus run`.
    proc = await asyncio.create_subprocess_exec(
        CACTUS_CLI, "run", CACTUS_GEMMA4_MODEL, "--prompt", prompt,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(stderr.decode().strip())
    return _parse_json_response(stdout.decode(), transcript)


def _parse_json_response(raw: str, transcript: str) -> IntentObject:
    raw = raw.strip()
    raw = re.sub(r"^```(?:json)?|```$", "", raw, flags=re.MULTILINE).strip()
    data = json.loads(raw)
    return IntentObject(
        goal=KnownGoal(data.get("goal", "unknown")),
        target=data.get("target", {}),
        uses_local_data=data.get("uses_local_data", []),
        requires_browser=data.get("requires_browser", False),
        requires_submission=data.get("requires_submission", False),
        slots=data.get("slots", {}),
        raw_transcript=transcript,
    )


def _extract_contact_and_body(transcript: str) -> tuple[str, str]:
    """
    Extract contact name and message body from natural language like:
      "Text Hanzi I'll be late"
      "Can you text Corinne and tell her what's up"
      "Send a message to Ethan saying I'm on my way"
    """
    # Skip noise words before we look for a name
    SKIP = {
        "text", "message", "imessage", "send", "a", "an", "the", "to",
        "can", "you", "please", "hey", "hi", "and", "saying", "say",
        "tell", "him", "her", "them", "that", "i", "me", "my",
    }
    words = transcript.split()

    # Find the first word after a trigger keyword that looks like a name
    trigger_indices = [
        i for i, w in enumerate(words)
        if w.lower() in ("text", "message", "imessage")
    ]

    contact = "unknown"
    contact_idx = -1

    if trigger_indices:
        # Look at words immediately after the trigger
        start = trigger_indices[-1] + 1
        for i in range(start, min(start + 5, len(words))):
            w = words[i]
            if w.lower() not in SKIP and len(w) > 1:
                contact = w.rstrip(".,!?")
                contact_idx = i
                break

    # Body = everything after the contact name
    if contact_idx >= 0 and contact_idx + 1 < len(words):
        body_words = words[contact_idx + 1:]
        # Strip connector words at the start of the body ("and tell him", "saying", etc.)
        while body_words and body_words[0].lower() in ("and", "saying", "that", "to"):
            body_words = body_words[1:]
        body = " ".join(body_words).strip()
    else:
        body = transcript

    return contact, body


_FIND_FILE_TRIGGERS = (
    "find my ",
    "find the ",
    "where is my ",
    "where's my ",
    "show me my ",
    "open my ",
    "reveal my ",
    "locate my ",
)

_ATTACHMENT_TRIGGERS = (
    "attach ",
    "attachment",
    "send me the ",
    "email me the ",
    "email me my ",
    "send the file",
)

_FILE_HINT_WORDS = {
    "resume", "cv", "cover", "letter", "deck", "slides", "document", "doc",
    "docx", "pdf", "file", "folder", "finder", "download", "downloads",
}
_FILE_EXT_HINTS = (".pdf", ".doc", ".docx", ".txt", ".md", ".rtf", ".pages", ".ppt", ".pptx")


def _infer_open_url_target(transcript: str) -> str | None:
    """
    Infer a web destination from phrases like:
      - "open my linkedin"
      - "open gmail"
      - "go to docs.google.com"
    Returns None if this sounds like a local file/folder request.
    """
    t = transcript.lower().strip()
    cue = None
    for c in ("open my ", "open ", "go to ", "visit ", "launch "):
        if t.startswith(c):
            cue = c
            break
    if cue is None:
        return None

    query = transcript[len(cue):].strip().rstrip(".?!")
    if not query:
        return None
    ql = query.lower()
    tokens = [tok for tok in re.findall(r"[a-z0-9._-]+", ql) if tok]
    if not tokens:
        return None

    # If this looks file-like, let FIND_FILE handle it.
    if any(w in tokens for w in _FILE_HINT_WORDS):
        return None
    if any(ext in ql for ext in _FILE_EXT_HINTS):
        return None

    # Explicit URL/domain
    if ql.startswith("http://") or ql.startswith("https://"):
        return query
    if "." in tokens[0] and " " not in query:
        return f"https://{tokens[0]}" if not ql.startswith("http") else query

    # Single service token (linkedin, github, notion, etc.) -> direct domain.
    if len(tokens) == 1 and len(tokens[0]) >= 3:
        return f"https://www.{tokens[0]}.com"

    # Fallback to web search for multi-word destinations.
    return f"https://www.google.com/search?q={quote_plus(query)}"


def _extract_file_query(transcript: str, trigger: str) -> str:
    lower = transcript.lower()
    idx = lower.find(trigger)
    if idx < 0:
        return transcript.strip()
    tail = transcript[idx + len(trigger) :].strip()
    # Trim trailing punctuation.
    return tail.rstrip(".?! ").strip() or transcript.strip()


def _rule_based_parse(transcript: str) -> IntentObject:
    """Keyword fallback covering the three core demo flows."""
    t = transcript.lower()

    url_target = _infer_open_url_target(transcript)
    if url_target is not None:
        return IntentObject(
            goal=KnownGoal.OPEN_URL,
            target={"type": "url", "value": url_target},
            uses_local_data=[],
            requires_browser=False,
            requires_submission=False,
            slots={"url": url_target},
            raw_transcript=transcript,
        )

    if any(kw in t for kw in [
        "start meeting", "capture meeting", "meeting capture",
        "listen to meeting", "take notes", "record meeting",
        "start capture", "capture this",
    ]):
        return IntentObject(
            goal=KnownGoal.CAPTURE_MEETING,
            target={},
            uses_local_data=[],
            requires_browser=False,
            requires_submission=False,
            slots={},
            raw_transcript=transcript,
        )

    if any(kw in t for kw in ["apply", "yc", "y combinator", "application"]):
        return IntentObject(
            goal=KnownGoal.APPLY_TO_JOB,
            target={"type": "url", "value": "apply.ycombinator.com"},
            uses_local_data=["resume"],
            requires_browser=True,
            requires_submission=True,
            slots={"company": "YC", "batch": "Fall 2026"},
            raw_transcript=transcript,
        )

    for trigger in _FIND_FILE_TRIGGERS:
        if trigger in t:
            query = _extract_file_query(transcript, trigger)
            return IntentObject(
                goal=KnownGoal.FIND_FILE,
                target={"type": "file", "value": query},
                uses_local_data=[],
                requires_browser=False,
                requires_submission=False,
                slots={"file_query": query},
                raw_transcript=transcript,
            )

    if any(kw in t for kw in ["text", "message", "imessage"]):
        contact, body = _extract_contact_and_body(transcript)
        return IntentObject(
            goal=KnownGoal.SEND_MESSAGE,
            target={"type": "contact", "value": contact},
            uses_local_data=["contacts"],
            requires_browser=False,
            requires_submission=True,
            slots={"contact": contact, "body": body},
            raw_transcript=transcript,
        )

    if any(kw in t for kw in ["meeting", "calendar", "schedule", "event"]):
        return IntentObject(
            goal=KnownGoal.ADD_CALENDAR_EVENT,
            target={"type": "calendar", "value": ""},
            uses_local_data=["calendar"],
            requires_browser=False,
            requires_submission=True,
            slots={"title": transcript},
            raw_transcript=transcript,
        )

    if any(kw in t for kw in ["email", "mail"]) and any(trig in t for trig in _ATTACHMENT_TRIGGERS):
        file_query = transcript.strip()
        for trig in _ATTACHMENT_TRIGGERS:
            if trig in t:
                file_query = _extract_file_query(transcript, trig)
                break
        return IntentObject(
            goal=KnownGoal.SEND_EMAIL,
            target={"type": "contact", "value": ""},
            uses_local_data=["attachment"],
            requires_browser=False,
            requires_submission=True,
            slots={"file_query": file_query},
            raw_transcript=transcript,
        )

    return IntentObject.unknown(transcript)
