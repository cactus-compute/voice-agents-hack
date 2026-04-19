"""
Contacts data source.

Shells out to `osascript` once to dump every person in Contacts.app as a
newline-delimited record. Chose AppleScript over the private AddressBook
SQLite because the DB schema changes between macOS versions and
`CNContactStore` requires a signed, entitled binary.

Requires the user to have granted the running Terminal (or VS Code /
iTerm) Contacts access in System Settings → Privacy & Security → Contacts.
"""

from __future__ import annotations

import hashlib
import shutil
import subprocess
import sys
import time
from dataclasses import dataclass
from typing import Iterator

from .base import DataSource, SyntheticDoc


_SEP_FIELD = "\u241f"   # ASCII unit separator as a safe field delimiter
_SEP_LIST = "\u241e"    # record separator
_END_MARK = "<<ALI_CONTACTS_END>>"


_APPLESCRIPT = r"""
on textify(lst, sep)
    set AppleScript's text item delimiters to sep
    set out to lst as text
    set AppleScript's text item delimiters to ""
    return out
end textify

on record_for(p)
    set nm to ""
    try
        set nm to (name of p) as text
    end try
    set org to ""
    try
        set org to (organization of p) as text
    end try
    set jt to ""
    try
        set jt to (job title of p) as text
    end try
    set nt to ""
    try
        set nt to (note of p) as text
    end try

    set emails to {}
    try
        repeat with e in emails of p
            set end of emails to (value of e) as text
        end repeat
    end try

    set phones to {}
    try
        repeat with ph in phones of p
            set end of phones to (value of ph) as text
        end repeat
    end try

    set theId to ""
    try
        set theId to (id of p) as text
    end try

    set mdate to ""
    try
        set mdate to ((modification date of p) as «class isot» as string)
    end try

    set parts to {theId, nm, org, jt, my textify(emails, ","), my textify(phones, ","), mdate, nt}
    return my textify(parts, "§FIELD§")
end record_for

tell application "Contacts"
    set out to ""
    repeat with p in people
        set out to out & my record_for(p) & "§REC§"
    end repeat
    return out & "§END§"
end tell
"""


@dataclass
class ContactsSource:
    name: str = "contacts"

    def available(self) -> bool:
        if sys.platform != "darwin":
            return False
        if shutil.which("osascript") is None:
            return False
        return True

    def iter_docs(self) -> Iterator[SyntheticDoc]:
        raw = _run_applescript()
        if not raw:
            return
        records = [
            rec.strip()
            for rec in raw.split("§REC§")
            if rec.strip() and rec.strip() != "§END§"
        ]
        for rec in records:
            if rec.endswith("§END§"):
                rec = rec[: -len("§END§")]
            parts = rec.split("§FIELD§")
            if len(parts) < 8:
                continue
            (
                contact_id,
                name,
                organization,
                job_title,
                emails_raw,
                phones_raw,
                mdate_raw,
                note,
            ) = [p.strip() for p in parts[:8]]

            display_name = name or emails_raw.split(",")[0].strip() or "(unknown contact)"
            emails = [e.strip() for e in emails_raw.split(",") if e.strip()]
            phones = [p.strip() for p in phones_raw.split(",") if p.strip()]
            content_lines: list[str] = [f"Contact: {display_name}"]
            if organization:
                content_lines.append(f"Organization: {organization}")
            if job_title:
                content_lines.append(f"Title: {job_title}")
            if emails:
                content_lines.append("Emails: " + ", ".join(emails))
            if phones:
                content_lines.append("Phones: " + ", ".join(phones))
            if note:
                content_lines.append("Notes: " + note)
            content = "\n".join(content_lines)

            stable_id = _hash_id(contact_id or display_name)
            mtime = _parse_apple_iso(mdate_raw) or time.time()

            yield SyntheticDoc(
                source=self.name,
                id=stable_id,
                display_name=display_name,
                content=content,
                mtime=mtime,
                size=len(content),
                metadata={
                    "emails": emails,
                    "phones": phones,
                    "organization": organization,
                    "title": job_title,
                },
            )


def build() -> ContactsSource:
    return ContactsSource()


def _run_applescript() -> str:
    osa = shutil.which("osascript")
    if osa is None:
        return ""
    try:
        proc = subprocess.run(
            [osa, "-e", _APPLESCRIPT],
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError) as exc:
        print(f"[disk-index][contacts] osascript failed: {exc}")
        return ""
    if proc.returncode != 0:
        # Most common cause: Contacts permission not granted yet.
        print(
            "[disk-index][contacts] osascript rc=%d — grant the running "
            "terminal Contacts access in System Settings → Privacy & "
            "Security → Contacts.\n  stderr: %s" % (proc.returncode, proc.stderr.strip()[:200])
        )
        return ""
    return proc.stdout


def _hash_id(raw: str) -> str:
    return hashlib.sha1(raw.encode("utf-8", errors="ignore")).hexdigest()[:16]


def _parse_apple_iso(raw: str) -> float | None:
    """AppleScript returns modification dates as ISO 8601 strings."""
    if not raw:
        return None
    try:
        import datetime as _dt

        # e.g. "2024-10-14T17:22:11+0000"
        for fmt in ("%Y-%m-%dT%H:%M:%S%z", "%Y-%m-%dT%H:%M:%S"):
            try:
                return _dt.datetime.strptime(raw, fmt).timestamp()
            except ValueError:
                continue
    except Exception:
        pass
    return None
