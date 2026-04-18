"""Masking & tokenization. CODEX OWNS THIS FILE.

Replaces sensitive entity spans with either a placeholder (`[MASKED:type]`)
or a stable token (`<TOKEN:abcd1234>`). Returns a MaskedText that includes
a token map so output filtering can re-mask leaked values on the way back.

Contract:
    mask(text: str, detection: DetectionResult, *, mode: str) -> MaskedText
    unmask(text: str, masked: MaskedText) -> str
"""

from __future__ import annotations

import hashlib
from typing import Literal

from .contracts import DetectionResult, EntityType, MaskedText

MaskMode = Literal["placeholder", "token"]


def _token_for(value: str) -> str:
    digest = hashlib.sha256(value.encode("utf-8")).hexdigest()[:8]
    return f"<TOKEN:{digest}>"


def mask(
    text: str,
    detection: DetectionResult,
    *,
    mode: MaskMode = "placeholder",
) -> MaskedText:
    """Replace each detected entity span in `text`.

    `placeholder` is more readable for the LLM (`[MASKED:ssn]`).
    `token` is reversible and useful when the LLM needs to refer back
    to the same redacted entity multiple times.
    """
    spans = sorted(
        [
            e
            for e in detection.entities
            if e.start >= 0 and e.end > e.start and e.type != EntityType.HEALTH_CONTEXT
        ],
        key=lambda e: e.start,
        reverse=True,
    )

    out = text
    token_map: dict[str, str] = {}
    replacements: list[dict[str, str | int]] = []
    occupied: list[tuple[int, int]] = []
    for e in spans:
        if any(not (e.end <= start or e.start >= end) for start, end in occupied):
            continue
        if mode == "token":
            replacement = _token_for(e.value)
            token_map[replacement] = e.value
        else:
            replacement = "[MASKED]"
        out = out[: e.start] + replacement + out[e.end :]
        replacements.append(
            {
                "type": e.type.value,
                "original": e.value,
                "replacement": replacement,
                "start": e.start,
                "end": e.end,
            }
        )
        occupied.append((e.start, e.end))

    replacements.reverse()
    return MaskedText(text=out, token_map=token_map, replacements=replacements)


def unmask(text: str, masked: MaskedText) -> str:
    """Inverse of `mask` for `token` mode. For `placeholder` mode the original
    values are restored as well, but readers should be aware that placeholders
    in LLM output may not exactly match the originals.
    """
    out = text
    for placeholder, value in masked.token_map.items():
        out = out.replace(placeholder, value)
    return out


def scrub_output(text: str, detection: DetectionResult) -> str:
    """Re-run masking on a model output to catch any leaked sensitive
    values the LLM might have echoed back in unredacted form.
    """
    out = text
    for e in detection.entities:
        if not e.value:
            continue
        out = out.replace(e.value, "[MASKED]")
    return out
