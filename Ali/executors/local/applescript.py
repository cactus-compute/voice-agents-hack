"""
Layer 4A — Local Executor: AppleScript / JXA
First-class macOS app integrations: iMessage, Mail, Calendar, Contacts.
"""

import subprocess
from datetime import datetime
from pathlib import Path

# --- Alspencer --- importing a lot of hardcoded shit here.
from config.resources import KNOWN_CONTACTS
from config.settings import VISION_ARTIFACT_DIR


class AppleScriptExecutionError(RuntimeError):
    """Raised when AppleScript execution fails with contextual guidance."""


def _run_applescript(script: str) -> str:
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        raw = result.stderr.strip()
        raise AppleScriptExecutionError(_humanize_applescript_error(raw))
    return result.stdout.strip()


def _humanize_applescript_error(raw_error: str) -> str:
    lowered = raw_error.lower()
    if "not authorized" in lowered or "not permitted" in lowered:
        return (
            "macOS denied app automation permission. Open System Settings → "
            "Privacy & Security → Automation and enable Terminal/IDE access for "
            "Messages, Mail, Calendar, and Contacts."
        )
    if "can't get 1st account" in lowered or "service type = imessage" in lowered:
        return (
            "No iMessage account is available in Messages. Open Messages.app and "
            "verify you are signed in to iMessage."
        )
    if "can't make" in lowered and "event" in lowered:
        return (
            "Calendar event creation failed. Verify the target calendar exists and "
            "the date/time format is valid."
        )
    return f"AppleScript error: {raw_error}"


class AppleScriptExecutor:
    def capture_observation(self, label: str = "desktop") -> dict:
        """Capture desktop state used by vision-first planner."""
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S_%f")
        artifacts_dir = Path(VISION_ARTIFACT_DIR).expanduser().resolve()
        artifacts_dir.mkdir(parents=True, exist_ok=True)
        screenshot_path = artifacts_dir / f"{label}_{timestamp}.png"

        frontmost_app = _run_applescript(
            """
            tell application "System Events"
                set frontApp to name of first process whose frontmost is true
                return frontApp
            end tell
            """
        )
        subprocess.run(
            ["screencapture", "-x", str(screenshot_path)],
            check=True,
            capture_output=True,
            text=True,
        )
        return {
            "scope": "desktop",
            "label": label,
            "timestamp": timestamp,
            "screenshot_path": str(screenshot_path),
            "frontmost_app": frontmost_app,
        }

    def resolve_contact(self, name: str) -> str:
        """
        Return a phone number or iMessage email for a contact name.
        Checks the hardcoded KNOWN_CONTACTS map first (fast, no app needed),
        then falls back to querying Contacts.app.
        """
        # Check hardcoded map first (case-insensitive)
        key = name.lower().strip()
        if key in KNOWN_CONTACTS:
            address = KNOWN_CONTACTS[key]
            print(f"[contacts] Resolved '{name}' → {address} (from known contacts)")
            return address

        # Fall back to Contacts.app — launch it if not running
        print(f"[contacts] Looking up '{name}' in Contacts.app...")
        script = f"""
        tell application "Contacts"
            activate
            set thePeople to people whose name contains "{name}"
            if (count of thePeople) > 0 then
                set p to item 1 of thePeople
                if (count of phones of p) > 0 then
                    return value of item 1 of phones of p
                end if
                if (count of emails of p) > 0 then
                    return value of item 1 of emails of p
                end if
            end if
            return ""
        end tell
        """
        result = _run_applescript(script)
        if not result:
            raise AppleScriptExecutionError(
                f"Contact '{name}' not found. "
                f"Add them to KNOWN_CONTACTS in config/resources.py."
            )
        return result

    def send_imessage(self, contact: str, body: str):
        """
        Send an iMessage to a phone number or email address.
        """
        # Escape quotes in body
        safe_body = body.replace('"', '\\"')
        script = f"""
        tell application "Messages"
            set targetService to 1st account whose service type = iMessage
            set targetBuddy to participant "{contact}" of targetService
            send "{safe_body}" to targetBuddy
        end tell
        """
        _run_applescript(script)
        print(f"[messages] Sent iMessage to {contact}: {body}")

    def compose_mail(
        self,
        to: str,
        subject: str,
        body: str,
        send: bool = False,
        attachments: list[str] | None = None,
    ):
        action = "send theMessage" if send else "activate"
        safe_body = body.replace('"', '\\"')
        safe_subject = subject.replace('"', '\\"')

        validated: list[str] = []
        for raw in attachments or []:
            if not isinstance(raw, str) or not raw:
                continue
            path = Path(raw).expanduser()
            if not path.is_absolute() or not path.exists():
                print(f"[mail] skipping attachment (not an absolute existing path): {raw!r}")
                continue
            if '"' in str(path):
                print(f"[mail] skipping attachment (unsafe quote in path): {raw!r}")
                continue
            validated.append(str(path))

        attachment_block = ""
        if validated:
            lines = []
            for abs_path in validated:
                lines.append(
                    "                tell content\n"
                    "                    make new attachment with properties "
                    f"{{file name:POSIX file \"{abs_path}\"}} at after last paragraph\n"
                    "                end tell"
                )
            attachment_block = "\n".join(lines) + "\n"

        script = f"""
        tell application "Mail"
            set theMessage to make new outgoing message with properties {{subject:"{safe_subject}", content:"{safe_body}", visible:true}}
            tell theMessage
                make new to recipient at end of to recipients with properties {{address:"{to}"}}
{attachment_block}            end tell
            {action}
        end tell
        """
        try:
            _run_applescript(script)
        except AppleScriptExecutionError as exc:
            if validated:
                print(f"[mail] attachment injection failed; retrying without attachments: {exc}")
                self.compose_mail(to=to, subject=subject, body=body, send=send, attachments=None)
            else:
                raise

    def create_calendar_event(self, title: str, date: str, time: str, attendees: list[str] = []):
        date_str = f"{date} {time}" if time else date
        safe_title = title.replace('"', '\\"')
        script = f"""
        tell application "Calendar"
            tell calendar "Home"
                set startDate to date "{date_str}"
                set endDate to startDate + (1 * hours)
                make new event at end of events with properties {{summary:"{safe_title}", start date:startDate, end date:endDate}}
            end tell
        end tell
        """
        _run_applescript(script)
