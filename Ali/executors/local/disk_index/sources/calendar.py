"""
Calendar data source.

macOS stores every Calendar event as an `.ics` text file under
`~/Library/Calendars/` (and nested `.caldav/<host>/<Calendar>/Events/` for
iCloud / Exchange accounts). We walk those files directly — bypasses the
`~/Library` deny-list in the generic filesystem walker — and parse out
SUMMARY / DTSTART / DTEND / LOCATION / DESCRIPTION / ATTENDEE fields into
a compact text block.

Requires Full Disk Access for the running terminal (System Settings →
Privacy & Security → Full Disk Access).
"""

from __future__ import annotations

import hashlib
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Iterator

from .base import DataSource, SyntheticDoc


_FIELDS = ("SUMMARY", "DTSTART", "DTEND", "LOCATION", "DESCRIPTION", "ORGANIZER")


@dataclass
class CalendarSource:
    name: str = "calendar"
    history_days: int = 365
    max_files: int = 5000

    def available(self) -> bool:
        root = _calendars_root()
        if not root.exists() or not root.is_dir():
            return False
        try:
            # Probe one `.ics` file — if we can't read anything, permissions
            # haven't been granted.
            for _ in root.rglob("*.ics"):
                return True
        except PermissionError:
            return False
        return False

    def iter_docs(self) -> Iterator[SyntheticDoc]:
        root = _calendars_root()
        if not root.exists():
            return
        cutoff = time.time() - self.history_days * 86400
        yielded = 0
        for ics_path in root.rglob("*.ics"):
            if yielded >= self.max_files:
                break
            try:
                stat = ics_path.stat()
            except OSError:
                continue
            # Skip events older than cutoff based on file mtime (cheap check).
            if stat.st_mtime < cutoff:
                continue
            try:
                raw = ics_path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                continue
            parsed = _parse_ics(raw)
            if not parsed:
                continue

            summary = parsed.get("SUMMARY") or "(no title)"
            content_lines: list[str] = [f"Event: {summary}"]
            if start := parsed.get("DTSTART"):
                content_lines.append(f"Starts: {_pretty_when(start)}")
            if end := parsed.get("DTEND"):
                content_lines.append(f"Ends: {_pretty_when(end)}")
            if loc := parsed.get("LOCATION"):
                content_lines.append(f"Location: {loc}")
            if organizer := parsed.get("ORGANIZER"):
                content_lines.append(f"Organizer: {organizer}")
            if attendees := parsed.get("ATTENDEES"):
                content_lines.append("Attendees: " + attendees)
            if description := parsed.get("DESCRIPTION"):
                content_lines.append("")
                content_lines.append(description[:4000])
            content = "\n".join(content_lines)

            uid = parsed.get("UID") or str(ics_path)
            stable_id = hashlib.sha1(uid.encode("utf-8")).hexdigest()[:16]

            yield SyntheticDoc(
                source=self.name,
                id=stable_id,
                display_name=summary[:120],
                content=content,
                mtime=float(stat.st_mtime),
                size=len(content),
                metadata={
                    "ics_path": str(ics_path),
                    "start": parsed.get("DTSTART"),
                    "location": parsed.get("LOCATION"),
                },
            )
            yielded += 1


def build(*, history_days: int = 365) -> CalendarSource:
    return CalendarSource(history_days=history_days)


def _calendars_root() -> Path:
    return Path(os.path.expanduser("~/Library/Calendars"))


_ICS_LINE_RE = re.compile(r"^([A-Z][A-Z0-9-]*)(?:;[^:]+)?:(.*)$")


def _parse_ics(raw: str) -> dict[str, str] | None:
    """Return a flat dict of the first VEVENT in the .ics text."""
    in_event = False
    fields: dict[str, str] = {}
    attendees: list[str] = []
    # Unfold continuation lines (ICS wraps at 75 chars with leading whitespace)
    lines: list[str] = []
    for line in raw.splitlines():
        if line.startswith((" ", "\t")) and lines:
            lines[-1] += line[1:]
        else:
            lines.append(line)
    for line in lines:
        if line == "BEGIN:VEVENT":
            in_event = True
            continue
        if line == "END:VEVENT":
            break
        if not in_event:
            continue
        match = _ICS_LINE_RE.match(line)
        if not match:
            continue
        name, value = match.group(1), match.group(2)
        value = _unescape_ics(value)
        if name == "ATTENDEE":
            attendees.append(_short_attendee(value))
        elif name in _FIELDS or name == "UID":
            if name not in fields:
                fields[name] = value
    if attendees:
        fields["ATTENDEES"] = ", ".join(attendees[:12])
    if not fields:
        return None
    return fields


def _unescape_ics(raw: str) -> str:
    return (
        raw.replace("\\n", "\n")
        .replace("\\N", "\n")
        .replace("\\,", ",")
        .replace("\\;", ";")
        .replace("\\\\", "\\")
    )


def _short_attendee(raw: str) -> str:
    # e.g. `mailto:alice@example.com` → `alice@example.com`
    if raw.lower().startswith("mailto:"):
        return raw[7:]
    return raw


def _pretty_when(raw: str) -> str:
    # Leave as-is; the ICS DT format is already human-readable (YYYYMMDDTHHMMSS).
    return raw.strip()
