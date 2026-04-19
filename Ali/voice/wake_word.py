"""
Wake-word listener: detects 'Ali' or 'Hey Ali' and fires a callback.
Uses SpeechRecognition + Google API in short bursts, pausing while the
main push-to-talk is recording (to avoid PyAudio mic conflicts).
Falls back gracefully if the library isn't installed.
"""
from __future__ import annotations

import threading
import time
from typing import Callable

# #region agent log
def _dlog(loc: str, msg: str, data: dict, hid: str = "H1") -> None:
    try:
        import json as _j, os as _o, time as _t
        _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
        _o.makedirs(_o.path.dirname(_p), exist_ok=True)
        with open(_p, "a") as _f:
            _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":hid,"location":loc,
                               "message":msg,"data":data,"timestamp":int(_t.time()*1000)})+"\n")
            _f.flush()
    except Exception:
        pass
# #endregion

# Set to True by voice/capture.py while Right Option is held.
recording_active = threading.Event()

# Avoid stacking multiple wake callbacks (parallel Google threads + repeated “ali”).
_WAKE_COOLDOWN_SEC = 4.0
_wake_lock = threading.Lock()
_last_wake_mono: float | None = None
_INLINE_COMMAND_PREFIXES = (
    "open ",
    "find ",
    "show ",
    "reveal ",
    "locate ",
    "send ",
    "text ",
    "message ",
    "email ",
    "what ",
    "who ",
    "where ",
    "when ",
    "how ",
    "why ",
)
_WAKE_ALIASES = {"ali", "al", "ally", "allie"}


def _rms16(frame_data: bytes) -> float:
    if not frame_data:
        return 0.0
    # 16-bit little-endian mono PCM from SpeechRecognition AudioData
    import array
    samples = array.array("h")
    samples.frombytes(frame_data[: (len(frame_data) // 2) * 2])
    if not samples:
        return 0.0
    return (sum(int(s) * int(s) for s in samples) / len(samples)) ** 0.5


def start_wake_word_listener(callback: Callable[[str], None]) -> None:
    """Start a background thread that calls callback() when 'Ali' is heard."""

    def _check(recognizer, audio, audio_end_mono: float) -> None:
        global _last_wake_mono
        try:
            frame_data = getattr(audio, "frame_data", b"") or b""
            rms = _rms16(frame_data)
            # #region agent log
            _dlog(
                "wake_word:_check:pre_recognize",
                "captured chunk before recognize_google",
                {"bytes": len(frame_data), "rms": round(rms, 2)},
                "H7",
            )
            # #endregion
            t0 = time.monotonic()
            text = recognizer.recognize_google(audio).lower()
            google_ms = int((time.monotonic() - t0) * 1000)
            print(f"[wake_word] Heard: \"{text}\" ({google_ms}ms)")
            words = {w.strip(".,!?").lower() for w in text.split()}
            has_wake = any(w in _WAKE_ALIASES for w in words)
            has_wake_like_prefix = any(w.startswith("al") for w in words if len(w) >= 2)
            has_wake = has_wake or has_wake_like_prefix
            inline_command = text.startswith(_INLINE_COMMAND_PREFIXES) and len(text.split()) >= 2
            if not has_wake and not inline_command:
                # #region agent log
                _dlog("wake_word:_check:no_ali", "google returned but no ali",
                      {"text": text, "google_ms": google_ms}, "H1")
                # #endregion
                return
            with _wake_lock:
                now = time.monotonic()
                if _last_wake_mono is not None and (now - _last_wake_mono) < _WAKE_COOLDOWN_SEC:
                    return
                _last_wake_mono = now
            post_speech_ms = int((time.monotonic() - audio_end_mono) * 1000)
            print(f"[wake_word] Heard: '{text}' → triggering")
            # #region agent log
            _dlog("wake_word:_check:trigger", "wake trigger firing callback",
                  {"text": text, "google_ms": google_ms,
                   "has_wake": has_wake, "inline_command": inline_command,
                   "wake_alias_hit": sorted(list(words & _WAKE_ALIASES)),
                   "ms_since_audio_end": post_speech_ms}, "H1")
            # #endregion
            callback(text)
        except Exception as e:
            err_type = type(e).__name__
            if "UnknownValueError" in err_type:
                print("[wake_word] Google: couldn't understand audio")
            elif "RequestError" in err_type:
                print(f"[wake_word] Google API error (no internet?): {e}")
            else:
                print(f"[wake_word] Recognition error: {err_type}: {e}")

    def _run() -> None:
        try:
            import speech_recognition as sr  # type: ignore[reportMissingImports]
        except ImportError:
            print("[wake_word] speech_recognition not installed — skipping voice wake word")
            return

        r = sr.Recognizer()
        r.energy_threshold = 300
        r.dynamic_energy_threshold = False   # don't let it drift too high in quiet rooms
        r.pause_threshold = 0.6
        r.non_speaking_duration = 0.35

        try:
            mic = sr.Microphone()
        except Exception as e:
            print(f"[wake_word] No microphone: {e}")
            return

        with mic as source:
            print("[wake_word] Calibrating ambient noise…")
            r.adjust_for_ambient_noise(source, duration=1.0)
            # Cap the calibrated threshold so quiet rooms don't kill detection
            if r.energy_threshold > 600:
                r.energy_threshold = 600
            print(f"[wake_word] Ready — threshold={r.energy_threshold:.0f}  say 'Ali' to wake")

        last_tts_log_mono = 0.0
        last_timeout_log_mono = 0.0
        timeout_count = 0
        last_error_log_mono = 0.0
        while True:
            # Don't open mic while push-to-talk is using it
            tts_busy = False
            try:
                from voice.speak import tts_active
                tts_busy = tts_active.is_set()
            except Exception:
                tts_busy = False
            if recording_active.is_set():
                recording_active.wait(timeout=5)
                continue
            if tts_busy:
                now_mono = time.monotonic()
                if now_mono - last_tts_log_mono > 0.8:
                    # #region agent log
                    _dlog("wake_word:tts_suppressed", "skipping wake listen during TTS", {}, "H5")
                    # #endregion
                    last_tts_log_mono = now_mono
                continue
            try:
                listen_started = time.monotonic()
                with mic as source:
                    audio = r.listen(source, timeout=2, phrase_time_limit=2.4)
                audio_end_mono = time.monotonic()
                timeout_count = 0
                frame_bytes = len(getattr(audio, "frame_data", b"") or b"")
                print(f"[wake_word] Audio captured ({frame_bytes} bytes) — sending to Google…")
                if not recording_active.is_set():
                    threading.Thread(target=_check, args=(r, audio, audio_end_mono), daemon=True).start()
            except Exception as e:
                err_type = type(e).__name__
                now_mono = time.monotonic()
                if err_type == "WaitTimeoutError":
                    timeout_count += 1
                    if now_mono - last_timeout_log_mono > 5.0:
                        print(f"[wake_word] Listening… (no speech in last 5s, threshold={r.energy_threshold:.0f})")
                        last_timeout_log_mono = now_mono
                        timeout_count = 0
                else:
                    if now_mono - last_error_log_mono > 2.0:
                        print(f"[wake_word] Listen error: {err_type}: {e}")
                        last_error_log_mono = now_mono

    threading.Thread(target=_run, daemon=True, name="wake-word").start()
