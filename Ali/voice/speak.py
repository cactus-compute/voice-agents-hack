"""
Tiny TTS helper — non-blocking macOS `say` by default.

Callable from any thread. Returns immediately; speech plays in the background.
"""

from __future__ import annotations

import subprocess
import sys
import threading


# "Ava (Enhanced)" is a neural voice on macOS 13+; fallback to Samantha if missing.
_PREFERRED_VOICES = ["Ava (Enhanced)", "Nicky (Enhanced)", "Zoe (Enhanced)", "Samantha"]
DEFAULT_VOICE = _PREFERRED_VOICES[0]
DEFAULT_RATE = "160"
tts_active = threading.Event()


def _best_available_voice() -> str:
    """Return the first installed enhanced voice, or Samantha."""
    try:
        result = subprocess.run(
            ["/usr/bin/say", "-v", "?"],
            capture_output=True, text=True, timeout=3,
        )
        installed = result.stdout.lower()
        for v in _PREFERRED_VOICES:
            if v.lower().split(" (")[0] in installed:
                return v
    except Exception:
        pass
    return "Samantha"


_VOICE_CACHE: str | None = None


def _voice() -> str:
    global _VOICE_CACHE
    if _VOICE_CACHE is None:
        _VOICE_CACHE = _best_available_voice()
    return _VOICE_CACHE


def track_tts_process(proc: subprocess.Popen[bytes]) -> None:
    """Mark TTS as active until this process exits."""
    tts_active.set()

    def _wait() -> None:
        try:
            proc.wait(timeout=12)
        except Exception:
            pass
        finally:
            tts_active.clear()

    threading.Thread(target=_wait, daemon=True).start()


def speak(text: str, voice: str | None = None, rate: str = DEFAULT_RATE) -> None:
    """Speak `text` asynchronously. Safe no-op on non-macOS."""
    if not text or not text.strip():
        return
    if sys.platform != "darwin":
        return
    chosen_voice = voice or _voice()
    try:
        proc = subprocess.Popen(
            ["/usr/bin/say", "-v", chosen_voice, "-r", rate, text],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        track_tts_process(proc)
    except Exception:
        pass
