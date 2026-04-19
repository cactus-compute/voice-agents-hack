"""
Build a cached user profile ("who am I" card).

Pulls identity from:
  * macOS `dscl . -read /Users/$USER RealName ...`
  * Contacts.app "me" card via AppleScript (best-effort)
  * git global config for the canonical work email
  * First pages of the resume alias if present in FILE_ALIASES
  * Hostname / macOS version

The file is tiny JSON (<2 KB) so the agent can load it on startup for zero
latency identity replies.
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import socket
import subprocess
from pathlib import Path
from typing import Any


def build_profile(
    *,
    resume_path: str | None,
    output_path: Path,
) -> dict[str, Any]:
    """Compute and persist the user profile. Returns the built dict."""
    profile: dict[str, Any] = {
        "username": os.environ.get("USER") or os.environ.get("LOGNAME") or "",
        "home": os.path.expanduser("~"),
        "hostname": _safe(socket.gethostname),
        "platform": f"{platform.system()} {platform.release()}",
    }

    dscl = _read_dscl()
    if dscl:
        profile.update(dscl)

    contact = _read_contacts_me_card()
    if contact:
        profile["contacts_me"] = contact

    git_email = _git_config("user.email")
    git_name = _git_config("user.name")
    if git_email:
        profile["git_email"] = git_email
    if git_name:
        profile.setdefault("name", git_name)

    if resume_path:
        snippet = _resume_snippet(Path(resume_path))
        if snippet:
            profile["resume_snippet"] = snippet
            profile["resume_path"] = resume_path

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(json.dumps(profile, indent=2, ensure_ascii=False), encoding="utf-8")
    return profile


def load_profile(path: Path) -> dict[str, Any] | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def _safe(fn) -> str:
    try:
        return str(fn())
    except Exception:
        return ""


def _read_dscl() -> dict[str, str]:
    dscl = shutil.which("dscl")
    user = os.environ.get("USER")
    if not dscl or not user:
        return {}
    try:
        proc = subprocess.run(
            [dscl, ".", "-read", f"/Users/{user}", "RealName", "NFSHomeDirectory"],
            capture_output=True,
            text=True,
            timeout=3,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {}
    if proc.returncode != 0:
        return {}
    out: dict[str, str] = {}
    # dscl uses multi-line output; RealName often sits on a continuation line.
    lines = proc.stdout.splitlines()
    for idx, line in enumerate(lines):
        if line.startswith("RealName:"):
            tail = line[len("RealName:") :].strip()
            if not tail and idx + 1 < len(lines):
                tail = lines[idx + 1].strip()
            if tail:
                out["name"] = tail
        elif line.startswith("NFSHomeDirectory:"):
            home = line[len("NFSHomeDirectory:") :].strip()
            if home:
                out["home"] = home
    return out


def _read_contacts_me_card() -> dict[str, Any]:
    osa = shutil.which("osascript")
    if not osa:
        return {}
    script = (
        'try\n'
        '  tell application "Contacts"\n'
        '    set me_card to my card\n'
        '    set the_name to name of me_card\n'
        '    set the_emails to {}\n'
        '    repeat with e in emails of me_card\n'
        '      set end of the_emails to value of e\n'
        '    end repeat\n'
        '    set the_phones to {}\n'
        '    repeat with p in phones of me_card\n'
        '      set end of the_phones to value of p\n'
        '    end repeat\n'
        '    set the_orgs to organization of me_card\n'
        '    return the_name & "\\t" & (the_emails as text) & "\\t" & '
        '(the_phones as text) & "\\t" & (the_orgs as text)\n'
        '  end tell\n'
        'on error\n'
        '  return ""\n'
        'end try\n'
    )
    try:
        proc = subprocess.run(
            [osa, "-e", script],
            capture_output=True,
            text=True,
            timeout=4,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return {}
    if proc.returncode != 0:
        return {}
    raw = proc.stdout.strip()
    if not raw:
        return {}
    parts = raw.split("\t")
    data: dict[str, Any] = {}
    if len(parts) >= 1 and parts[0]:
        data["name"] = parts[0]
    if len(parts) >= 2 and parts[1]:
        data["emails"] = [e.strip() for e in parts[1].split(",") if e.strip()]
    if len(parts) >= 3 and parts[2]:
        data["phones"] = [p.strip() for p in parts[2].split(",") if p.strip()]
    if len(parts) >= 4 and parts[3]:
        data["organization"] = parts[3]
    return data


def _git_config(key: str) -> str:
    git = shutil.which("git")
    if not git:
        return ""
    try:
        proc = subprocess.run(
            [git, "config", "--global", "--get", key],
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
    except (subprocess.TimeoutExpired, OSError):
        return ""
    return proc.stdout.strip()


def _resume_snippet(path: Path) -> str:
    if not path.exists() or not path.is_file():
        return ""
    # Reuse the extractor, but keep it cheap.
    try:
        from .extract import extract_text
    except ImportError:
        return ""
    text = extract_text(path)
    if not text:
        return ""
    # Keep the first ~1200 chars — the top of a resume has the identity block.
    return text[:1200].strip()
