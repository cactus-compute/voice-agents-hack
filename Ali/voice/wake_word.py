"""
Wake-word listener: detects 'Ali' or 'Hey Ali' and fires a callback.
Uses SpeechRecognition + Google API for reliable short-phrase detection.
Falls back gracefully if the library isn't installed.
"""
from __future__ import annotations

import threading
from typing import Callable


def start_wake_word_listener(callback: Callable[[], None]) -> None:
    """Start a background thread that calls callback() when 'Ali' is heard."""

    def _check(recognizer, audio) -> None:
        try:
            text = recognizer.recognize_google(audio).lower()
            words = set(text.split())
            if "ali" in words:
                print(f"[wake_word] Heard: '{text}' → triggering")
                callback()
        except Exception:
            pass

    def _run() -> None:
        try:
            import speech_recognition as sr  # type: ignore[reportMissingImports]
        except ImportError:
            print("[wake_word] speech_recognition not installed — skipping voice wake word")
            print("[wake_word] Install with: pip install SpeechRecognition")
            return

        r = sr.Recognizer()
        r.energy_threshold = 400
        r.dynamic_energy_threshold = True
        r.pause_threshold = 0.5

        try:
            mic = sr.Microphone()
        except Exception as e:
            print(f"[wake_word] No microphone: {e}")
            return

        with mic as source:
            print("[wake_word] Calibrating... say 'Ali' to wake")
            r.adjust_for_ambient_noise(source, duration=1.0)

        while True:
            try:
                with mic as source:
                    audio = r.listen(source, timeout=None, phrase_time_limit=3)
                threading.Thread(target=_check, args=(r, audio), daemon=True).start()
            except Exception as e:
                print(f"[wake_word] listen error: {e}")

    threading.Thread(target=_run, daemon=True, name="wake-word").start()
