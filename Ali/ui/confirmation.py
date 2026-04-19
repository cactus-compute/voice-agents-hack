"""
Layer 5 — Confirmation Gate
Shows a native macOS dialog via osascript.
Thread-safe — no main-thread requirement unlike tkinter.
"""

import asyncio
import os
import subprocess


async def ask_confirmation(message: str) -> bool:
    """
    Show a native macOS confirmation dialog via osascript.
    Returns True if user clicks OK, False if Cancel or error.
    """
    # Default to non-interactive auto-approve for voice-first UX.
    # Set VOICE_AGENT_REQUIRE_CONFIRM=1 to re-enable native dialogs.
    require_confirm = os.environ.get("VOICE_AGENT_REQUIRE_CONFIRM", "").lower() in {"1", "true", "yes"}
    if not require_confirm:
        return True
    loop = asyncio.get_event_loop()
    return await loop.run_in_executor(None, _show_dialog, message)


def _show_dialog(message: str) -> bool:
    # Escape any double quotes in the message
    safe = message.replace('"', '\\"').replace("'", "\\'")
    script = (
        f'display dialog "{safe}" '
        f'buttons {{"Cancel", "Send it"}} '
        f'default button "Send it" '
        f'with title "Voice Agent"'
    )
    result = subprocess.run(
        ["osascript", "-e", script],
        capture_output=True,
        text=True,
    )
    return result.returncode == 0
