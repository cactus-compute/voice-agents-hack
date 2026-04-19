"""
Conversational fallback — when intent.goal == unknown and the RAG path has
nothing to say, produce a short spoken reply so Ali always answers.

Local-first: if Gemini is available we use it by default because it was the
original path for this file; the retrieval-augmented path in
`executors.local.disk_index.answer` keeps everything on device and is tried
first. If `ALI_ALLOW_CLOUD_FALLBACK=0`, this module becomes a no-op stub.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

from config.settings import ALI_ALLOW_CLOUD_FALLBACK, GEMINI_API_KEY

try:
    from google import genai as _genai  # type: ignore
    _AVAILABLE = bool(GEMINI_API_KEY)
except ImportError:
    _AVAILABLE = False


_BASE_SYSTEM = (
    "You are Ali, a sharp AI chief of staff. Respond like a real person talking — "
    "brief, natural, zero filler. One or two sentences max. No 'Certainly!', no 'Great question!', "
    "no lists, no markdown. If you don't know something, say so plainly and move on."
)


def _load_profile() -> dict[str, Any] | None:
    try:
        from executors.local.disk_index import get_user_profile

        return get_user_profile()
    except Exception:
        return None


def _profile_preamble(profile: dict[str, Any] | None) -> str:
    if not profile:
        return ""
    keep = {k: profile[k] for k in ("name", "git_email", "platform", "hostname") if k in profile}
    me = profile.get("contacts_me")
    if isinstance(me, dict):
        if me.get("emails"):
            keep["emails"] = me["emails"]
        if me.get("organization"):
            keep["organization"] = me["organization"]
    if not keep:
        return ""
    return "\nUser profile (use when relevant): " + json.dumps(keep, ensure_ascii=False)


async def chat_reply(
    transcript: str,
    context_snippets: list[str] | None = None,
) -> str:
    """Return a short spoken-style reply, or a safe fallback if LLM unavailable."""
    if not transcript.strip():
        return ""
    if not _AVAILABLE or not ALI_ALLOW_CLOUD_FALLBACK:
        # Keep identity-aware fallback even if no cloud LLM is reachable.
        profile = _load_profile()
        if profile:
            name = profile.get("name")
            if name and "who" in transcript.lower():
                return f"You're {name}."
        return "I heard you, but I'm set to local-only mode and couldn't answer that."

    profile = _load_profile()
    system = _BASE_SYSTEM + _profile_preamble(profile)
    context_block = ""
    if context_snippets:
        context_block = (
            "\nRelevant excerpts from the user's files (cite them if used):\n"
            + "\n---\n".join(context_snippets[:6])
        )

    loop = asyncio.get_event_loop()

    def _call() -> str:
        client = _genai.Client(api_key=GEMINI_API_KEY)
        prompt = f"{system}{context_block}\n\nUser said: {transcript}\n\nReply:"
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
