"""
Layer 5 — Confirmation Gate
Shows a native macOS dialog via osascript.
Thread-safe — no main-thread requirement unlike tkinter.
"""

import asyncio
import subprocess


async def ask_confirmation(message: str) -> bool:
    """
    Show a native macOS confirmation dialog via osascript.
    Returns True if user clicks OK, False if Cancel or error.
    """
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
