"""
Retrieval-augmented answering backed by Gemma 4 (Cactus).

Local-first: by default we only shell out to the Cactus CLI. Gemini is an
opt-in fallback guarded by ALI_ALLOW_CLOUD_FALLBACK so nothing leaves the
laptop unless the user explicitly permits it.
"""

from __future__ import annotations

import asyncio
import json
import os
import re
import shutil
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .retrieve import Hit

_CACTUS_CLI = shutil.which("cactus")


@dataclass(frozen=True)
class AnswerResult:
    text: str
    cited_paths: list[str]
    backend: str  # "cactus" | "gemini" | "stub"
    snippets_used: int


async def answer_question(
    transcript: str,
    *,
    profile: dict[str, Any] | None,
    hits: list[Hit],
    cactus_model: str,
    allow_cloud_fallback: bool,
    gemini_key: str | None,
) -> AnswerResult:
    """Produce a short spoken answer grounded in retrieved snippets."""
    transcript = (transcript or "").strip()
    if not transcript:
        return AnswerResult(
            text="I didn't catch that — could you say it again?",
            cited_paths=[],
            backend="stub",
            snippets_used=0,
        )

    prompt = _build_prompt(transcript=transcript, profile=profile, hits=hits)

    if _CACTUS_CLI:
        reply = await _call_cactus(prompt, cactus_model)
        if reply:
            return AnswerResult(
                text=reply,
                cited_paths=[h.path for h in hits],
                backend="cactus",
                snippets_used=len(hits),
            )

    if allow_cloud_fallback and gemini_key:
        reply = await _call_gemini(prompt, gemini_key)
        if reply:
            return AnswerResult(
                text=reply,
                cited_paths=[h.path for h in hits],
                backend="gemini",
                snippets_used=len(hits),
            )

    fallback = _fallback_answer(transcript, profile, hits)
    return AnswerResult(
        text=fallback,
        cited_paths=[h.path for h in hits],
        backend="stub",
        snippets_used=len(hits),
    )


# ─── Prompt shaping ───────────────────────────────────────────────────────────


_SYSTEM = (
    "You are Ali, the user's personal on-device assistant. You know the user "
    "through their profile (macOS account info, Contacts, resume snippets) "
    "and through snippets retrieved from their files / calendar / messages.\n"
    "\n"
    "Rules:\n"
    "• Answer in ONE or TWO natural spoken sentences — no lists, no markdown, "
    "  no preamble like \"based on the context\".\n"
    "• For identity questions (who am I, my name, my email, where I live, "
    "  where I work, my phone number): the USER PROFILE is authoritative. "
    "  Use it directly and confidently.\n"
    "• For questions about files, notes, events, conversations: use the "
    "  EXCERPTS. Cite information only if it's actually there.\n"
    "• Never say \"the context does not contain…\" or similar. If you truly "
    "  can't answer, say what you'd need (e.g. \"I don't see an answer in "
    "  your recent files — try giving me a filename\").\n"
    "• Prefer profile facts over excerpts when they conflict."
)


def _build_prompt(
    *,
    transcript: str,
    profile: dict[str, Any] | None,
    hits: list[Hit],
) -> str:
    parts: list[str] = [_SYSTEM, ""]

    parts.append("USER PROFILE")
    if profile:
        parts.append(_profile_block(profile))
    else:
        parts.append(
            "(profile not yet built — disk index is still building. Fall back "
            "to the excerpts for this one.)"
        )
    parts.append("")

    if hits:
        parts.append("EXCERPTS from the user's files / data (most relevant first):")
        for i, hit in enumerate(hits, 1):
            mtime = _fmt_mtime(hit.mtime)
            label = _hit_label(hit)
            parts.append(f"[{i}] {label}  (modified {mtime})")
            parts.append(hit.snippet.strip())
            parts.append("")
    else:
        parts.append("EXCERPTS: (no matching excerpts for this question)")
        parts.append("")

    parts.append(f"Question: {transcript}")
    parts.append("Answer:")
    return _sanitize_for_argv("\n".join(parts))


# Control chars we strip from prompts before they become argv. NUL is
# fatal (execve rejects argv containing \x00 → "embedded null byte"),
# and other C0 controls occasionally sneak in from PDF / binary-ish
# chunks and confuse the CLI. We keep \t and \n since the prompt is
# multi-line by design.
_CTRL_CHARS_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f]")


def _sanitize_for_argv(text: str) -> str:
    return _CTRL_CHARS_RE.sub("", text or "")


def _hit_label(hit: Hit) -> str:
    """Pretty label for a source row — useful so the LLM knows where the
    snippet came from (a contact vs a calendar event vs a PDF)."""
    if hit.path.startswith("ali://contacts/"):
        return f"Contact: {hit.name}"
    if hit.path.startswith("ali://calendar/"):
        return f"Calendar event: {hit.name}"
    if hit.path.startswith("ali://messages/"):
        return f"Chat transcript with {hit.name}"
    return hit.path


def _profile_block(profile: dict[str, Any]) -> str:
    lines: list[str] = []
    for key in ("name", "git_email", "hostname", "platform", "home"):
        value = profile.get(key)
        if value:
            lines.append(f"- {key}: {value}")
    me = profile.get("contacts_me")
    if isinstance(me, dict):
        if me.get("emails"):
            lines.append(f"- emails: {', '.join(me['emails'])}")
        if me.get("phones"):
            lines.append(f"- phones: {', '.join(me['phones'])}")
        if me.get("organization"):
            lines.append(f"- organization: {me['organization']}")
    snippet = profile.get("resume_snippet")
    if isinstance(snippet, str) and snippet:
        lines.append("- resume_excerpt:")
        lines.append(snippet[:800])
    return "\n".join(lines) if lines else "(no profile information cached)"


def _fmt_mtime(mtime: float | None) -> str:
    if not mtime:
        return "unknown"
    try:
        return time.strftime("%Y-%m-%d", time.localtime(float(mtime)))
    except (TypeError, ValueError):
        return "unknown"


# ─── Backends ─────────────────────────────────────────────────────────────────


async def _call_cactus(prompt: str, model: str) -> str:
    if not _CACTUS_CLI:
        return ""
    # The first `cactus run` of a session has to load Gemma 4 (~2B params,
    # a few hundred MB) from disk before it can generate. On an M-series
    # laptop this can take 30-60s cold; after that it usually falls under
    # ~3s. Use a generous timeout so the first voice query doesn't fall
    # straight through to the stub fallback.
    # `cactus run --prompt` answers the prompt, then drops into an interactive
    # chat REPL. We pipe "exit" on stdin so the process terminates after one
    # turn instead of hanging on the "You:" prompt.
    proc: asyncio.subprocess.Process | None = None
    try:
        proc = await asyncio.create_subprocess_exec(
            _CACTUS_CLI,
            "run",
            model,
            "--prompt",
            prompt,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await asyncio.wait_for(
            proc.communicate(input=b"exit\n"), timeout=90
        )
    except asyncio.TimeoutError:
        print("[answer][warn] cactus timed out after 90s")
        if proc is not None:
            try:
                proc.kill()
            except Exception:
                pass
        return ""
    except (OSError, asyncio.CancelledError) as exc:
        print(f"[answer][warn] cactus subprocess failed: {exc}")
        return ""
    if proc.returncode != 0:
        print(
            "[answer][warn] cactus rc=%d stderr=%s"
            % (proc.returncode, stderr.decode("utf-8", errors="ignore").strip()[:200])
        )
        return ""
    return _extract_cactus_reply(stdout.decode("utf-8", errors="ignore"))


def _extract_cactus_reply(output: str) -> str:
    """Pull the 'Assistant:' block out of cactus's chat-style stdout."""
    if not output:
        return ""
    marker = "Assistant:"
    idx = output.find(marker)
    if idx < 0:
        return _clean_reply(output)
    tail = output[idx + len(marker):]
    lines: list[str] = []
    for raw in tail.splitlines():
        stripped = raw.strip()
        # Stop at the token-stats line, e.g. "[66 tokens | latency: 0.019s | …]".
        if stripped.startswith("[") and "tok" in stripped and stripped.endswith("]"):
            break
        # Stop at the REPL's "You:" separator or divider lines.
        if stripped.startswith("You:") or (stripped and set(stripped) <= {"-", "=", "─", "━"}):
            break
        if stripped.startswith("👋"):
            break
        lines.append(stripped)
    # Trim leading/trailing blanks, then collapse into a single spoken block.
    while lines and not lines[0]:
        lines.pop(0)
    while lines and not lines[-1]:
        lines.pop()
    return _clean_reply(" ".join(line for line in lines if line))


async def _call_gemini(prompt: str, api_key: str) -> str:
    try:
        from google import genai as _genai  # type: ignore
    except ImportError:
        return ""

    loop = asyncio.get_event_loop()

    def _sync() -> str:
        client = _genai.Client(api_key=api_key)
        response = client.models.generate_content(
            model="gemini-2.5-flash",
            contents=prompt,
            config=_genai.types.GenerateContentConfig(
                temperature=0.2,
                max_output_tokens=200,
            ),
        )
        return (response.text or "").strip()

    try:
        raw = await loop.run_in_executor(None, _sync)
    except Exception:
        return ""
    return _clean_reply(raw)


# ANSI escape sequences Cactus uses to colour its CLI output (telemetry,
# separators, next-turn prompt). We strip them wholesale.
_ANSI_ESCAPE_RE = re.compile(
    r"\x1b\[[0-9;?]*[A-Za-z]"
    r"|\x1b\][^\x07]*\x07"  # OSC sequences ending in BEL
)

# Everything after the first of these markers is CLI chrome for the next
# interactive turn — not part of the model's reply. The telemetry markers
# don't require a preceding newline because Cactus sometimes appends them
# on the same line as the answer (`… audio resume. [14 tokens | …]`).
_CLI_END_MARKERS_RE = re.compile(
    r"(?:"
    r"\s*\[\s*\d+\s+tokens?\s*\|"          # telemetry block "[14 tokens | …]"
    r"|\s+\d+\s+tokens?\s*\|\s*latency"    # same, no bracket
    r"|\n[-─=]{3,}"                         # separator line
    r"|\nYou\s*:"                           # next-turn prompt
    r"|\nlatency:\s*\d"                     # standalone latency line
    r")",
    re.IGNORECASE,
)


def _clean_reply(raw: str) -> str:
    """Turn a raw `cactus run` stdout blob into a clean spoken answer.

    Cactus emits, in order:
        <ANSI colour> <the actual answer> <ANSI reset>
        [<N> tokens | latency: … | … tok/s | RAM: … MB]
        -------------------------------------------------
        <ANSI colour> You: <next prompt>

    We strip the colour codes, cut at the first CLI end-marker, and then
    apply the same scaffolding-strip that was already there.
    """
    text = raw or ""
    # 1) Drop ANSI colour/CSI/OSC sequences.
    text = _ANSI_ESCAPE_RE.sub("", text)
    # 2) Cut at the first Cactus CLI end-marker (telemetry / separator /
    #    next-turn prompt). Anything after the answer is noise.
    m = _CLI_END_MARKERS_RE.search(text)
    if m:
        text = text[: m.start()]
    text = text.strip()
    # 3) Strip markdown code fences the model sometimes adds.
    text = re.sub(r"^```(?:json|text)?|```$", "", text, flags=re.MULTILINE).strip()
    # 4) Some Cactus builds prepend the prompt — drop up to "Answer:".
    if "Answer:" in text:
        text = text.split("Answer:", 1)[1].strip()
    # 5) Spoken: first two sentences only.
    sentences = re.split(r"(?<=[.!?])\s+", text)
    if len(sentences) > 2:
        text = " ".join(sentences[:2])
    return text.strip()


# ─── Fallback when every backend fails ────────────────────────────────────────


def _fallback_answer(
    transcript: str,
    profile: dict[str, Any] | None,
    hits: list[Hit],
) -> str:
    """Last-resort template-based answerer used only when every LLM backend
    failed. Covers the most common identity questions so "who am I" still
    works offline.
    """
    lowered = (transcript or "").lower()
    me = (profile or {}).get("contacts_me") or {}

    def _name() -> str | None:
        return (profile or {}).get("name") or me.get("name")

    def _email() -> str | None:
        emails = me.get("emails") or []
        return (profile or {}).get("git_email") or (emails[0] if emails else None)

    def _phone() -> str | None:
        phones = me.get("phones") or []
        return phones[0] if phones else None

    def _org() -> str | None:
        return me.get("organization") or None

    if profile:
        if any(kw in lowered for kw in ("who am i", "my name", "what's my name", "whats my name")):
            n = _name()
            if n:
                return f"You're {n}."
        if "email" in lowered:
            e = _email()
            if e:
                return f"Your email is {e}."
        if any(kw in lowered for kw in ("phone", "number")):
            p = _phone()
            if p:
                return f"Your phone is {p}."
        if any(kw in lowered for kw in ("company", "work", "employer", "where do i work")):
            o = _org()
            if o:
                return f"You work at {o}."
        if any(kw in lowered for kw in ("computer", "mac", "hostname", "machine")):
            host = (profile or {}).get("hostname")
            if host:
                return f"You're on {host}."

    if hits:
        top = hits[0]
        return f"I can't reach the model right now, but {top.name} looks most relevant."
    return (
        "I can't reach the model right now, and nothing in the index matches "
        "that yet."
    )
