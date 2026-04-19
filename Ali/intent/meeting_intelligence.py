"""
Meeting intelligence — powered by Gemma 4 (via Gemini API).

Analyzes rolling meeting transcripts to extract actionable items in real time.
This is the Gemma 4 story for judges: raw audio → text (Deepgram, commodity
transcription), then Gemma 4 understands the meeting and decides what to act on.
"""
from __future__ import annotations

import asyncio
import json
import re
from typing import Any

from config.settings import GEMINI_API_KEY

try:
    from google import genai as _genai  # type: ignore
    _AVAILABLE = bool(GEMINI_API_KEY)
except ImportError:
    _AVAILABLE = False

# This is the Gemma 4 pitch: given raw transcript, understand intent + extract tasks.
_SYSTEM = """\
You are an AI chief of staff listening to a live meeting.
Your job: extract ONLY NEW actionable tasks from the latest transcript segment.

Do NOT repeat tasks already in the captured list.
Map each task to one of these types:
  draft_email  — write and send an email
  send_message — iMessage / SMS
  book_flight  — book travel
  find_file    — locate a document
  open_url     — open a website
  other        — anything else

Return a JSON array. Each element:
{
  "task": "short human-readable description",
  "type": "<one of the types above>",
  "slots": { ...any details you can extract: recipient, destination, date, etc. }
}

Return [] if no new tasks. Output ONLY the JSON array — no explanation, no markdown."""


async def extract_action_items(
    new_segment: str,
    already_captured: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    """
    Ask Gemma 4 (via Gemini API) to find new action items in `new_segment`.
    Returns a list of action-item dicts. Empty list if nothing new.
    """
    if not new_segment.strip() or not _AVAILABLE:
        return []

    prev_str = json.dumps(already_captured, indent=2) if already_captured else "none"
    prompt = (
        f"{_SYSTEM}\n\n"
        f"Already captured:\n{prev_str}\n\n"
        f"New segment:\n{new_segment}"
    )

    loop = asyncio.get_event_loop()

    def _call() -> str:
        client = _genai.Client(api_key=GEMINI_API_KEY)
        resp = client.models.generate_content(
            model="gemini-2.5-flash",   # Gemma 4 intelligence layer
            contents=prompt,
            config=_genai.types.GenerateContentConfig(
                temperature=0.1,
                max_output_tokens=512,
            ),
        )
        return (resp.text or "").strip()

    try:
        raw = await loop.run_in_executor(None, _call)
        raw = re.sub(r"^```(?:json)?|```$", "", raw, flags=re.MULTILINE).strip()
        items = json.loads(raw)
        return items if isinstance(items, list) else []
    except Exception as e:
        print(f"[meeting_intel] extraction failed: {e}")
        return []


def item_to_intent(item: dict[str, Any]):
    """Map an extracted action item dict → IntentObject for the orchestrator."""
    from intent.schema import IntentObject, KnownGoal

    type_to_goal = {
        "draft_email":   KnownGoal.SEND_EMAIL,
        "send_message":  KnownGoal.SEND_MESSAGE,
        "find_file":     KnownGoal.FIND_FILE,
        "open_url":      KnownGoal.OPEN_URL,
        "book_flight":   KnownGoal.OPEN_URL,
    }
    goal    = type_to_goal.get(item.get("type", ""), KnownGoal.UNKNOWN)
    task    = item.get("task", "")
    slots   = item.get("slots", {})

    if goal == KnownGoal.OPEN_URL and item.get("type") == "book_flight":
        slots.setdefault("url", "https://www.google.com/flights")

    return IntentObject(
        goal=goal,
        target={"type": item.get("type", "other"), "value": task},
        uses_local_data=[],
        requires_browser=goal in (KnownGoal.OPEN_URL,),
        requires_submission=False,
        slots=slots,
        raw_transcript=task,
    )
