"""
Conversational fallback — when intent.goal == unknown, ask Gemini for a
short spoken reply so Ali always answers the user.
"""

from __future__ import annotations

import asyncio

from config.settings import GEMINI_API_KEY

try:
    from google import genai as _genai  # type: ignore
    _AVAILABLE = bool(GEMINI_API_KEY)
except ImportError:
    _AVAILABLE = False


_SYSTEM = (
    "You are Ali, a sharp AI chief of staff. Respond like a real person talking — "
    "brief, natural, zero filler. One or two sentences max. No 'Certainly!', no 'Great question!', "
    "no lists, no markdown. If you don't know something, say so plainly and move on."
)


async def chat_reply(transcript: str) -> str:
    """Return a short spoken-style reply, or a safe fallback if LLM unavailable."""
    if not transcript.strip():
        return ""
    if not _AVAILABLE:
        return "I heard you, but I'm not connected to my brain right now."

    loop = asyncio.get_event_loop()

    def _call() -> str:
        client = _genai.Client(api_key=GEMINI_API_KEY)
        prompt = f"{_SYSTEM}\n\nUser said: {transcript}\n\nReply:"
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt,
            config=_genai.types.GenerateContentConfig(
                temperature=0.4,
                max_output_tokens=160,
            ),
        )
        return (response.text or "").strip()

    try:
        text = await loop.run_in_executor(None, _call)
        return text or "I didn't catch that — could you say it again?"
    except Exception:
        return "I heard you, but I couldn't reach my brain right now."
