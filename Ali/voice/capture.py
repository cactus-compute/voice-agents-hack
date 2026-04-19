"""
Layer 1 — Voice Capture
Push-to-talk: hold Right Option to record, release to stop.
Yields raw audio bytes for each completed utterance.
"""

import asyncio
import io
import os
import struct
import threading
import time
import wave
from typing import AsyncGenerator, Callable

import pyaudio  # pyright: ignore[reportMissingModuleSource]
from pynput import keyboard  # pyright: ignore[reportMissingModuleSource]

# #region agent log
def _dlog(loc: str, msg: str, data: dict, hid: str = "H6") -> None:
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

SAMPLE_RATE = 16000
CHANNELS = 1
CHUNK = 1024
FORMAT = pyaudio.paInt16

# The hotkey that triggers recording
TRIGGER_KEY = keyboard.Key.alt_r

# Set while listen_for_command is active — wake word / demo hotkey call
# request_ptt_session_from_wake() to reuse the same path as Right Option.
_ptt_start_flag: threading.Event | None = None

# macOS: backtick is delivered via AppKit global monitor (ui/overlay.py) → Qt
# signal → this callback. Set by listen_for_command while the async loop runs.
_backtick_callback: Callable[[], None] | None = None
_right_option_down: Callable[[], None] | None = None
_right_option_up: Callable[[], None] | None = None


def register_backtick_callback(cb: Callable[[], None] | None) -> None:
    """Wire the same handler as pynput's on_backtick (macOS global ` key)."""
    global _backtick_callback
    _backtick_callback = cb


def invoke_backtick_callback() -> None:
    """Called from Qt main thread when global backtick fires."""
    cb = _backtick_callback
    if cb is None:
        print(
            "[voice] Backtick ignored — voice loop not ready yet (wait for "
            "\"ready — say 'Ali'…\").",
            flush=True,
        )
        return
    try:
        cb()
    except Exception as e:
        print(f"[voice] backtick callback error: {e}", flush=True)


def register_right_option_callbacks(
    down: Callable[[], None] | None,
    up: Callable[[], None] | None,
) -> None:
    """AppKit global monitor → same path as pynput Right Option."""
    global _right_option_down, _right_option_up
    _right_option_down, _right_option_up = down, up


def invoke_right_option_down() -> None:
    fn = _right_option_down
    if fn is not None:
        try:
            fn()
        except Exception as e:
            print(f"[voice] Right Option down error: {e}", flush=True)


def invoke_right_option_up() -> None:
    fn = _right_option_up
    if fn is not None:
        try:
            fn()
        except Exception as e:
            print(f"[voice] Right Option up error: {e}", flush=True)

# Next capture after start_flag is triggered via wake/backtick: end-of-utterance
# by silence (Option release still works to cut short).
_conversational_lock = threading.Lock()
_next_session_conversational = False

CONV_RMS_THRESHOLD = 180.0
CONV_SILENCE_SEC = 0.88
CONV_MIN_VOICE_SEC = 0.38
CONV_MAX_SEC = 10.0


def _pcm16_rms(data: bytes) -> float:
    n = len(data) // 2
    if n <= 0:
        return 0.0
    fmt = f"{n}h"
    samples = struct.unpack(fmt, data[: n * 2])
    return (sum(s * s for s in samples) / n) ** 0.5


def _record_conversational(
    stop_flag: threading.Event,
    stream,
    frames: list[bytes],
    chunk: int,
) -> None:
    t0 = time.monotonic()
    last_loud = t0
    voice_since: float | None = None
    peak_rms = 0.0
    end_reason = "stop_flag"

    while not stop_flag.is_set():
        data = stream.read(chunk, exception_on_overflow=False)
        frames.append(data)
        now = time.monotonic()
        rms = _pcm16_rms(data)
        if rms > peak_rms:
            peak_rms = rms
        if now - t0 > CONV_MAX_SEC:
            end_reason = "max_sec"
            break

        if rms >= CONV_RMS_THRESHOLD:
            last_loud = now
            if voice_since is None:
                voice_since = now

        if voice_since is not None:
            if (now - voice_since) >= CONV_MIN_VOICE_SEC and (now - last_loud) >= CONV_SILENCE_SEC:
                end_reason = "silence_after_voice"
                break
    # #region agent log
    _dlog(
        "capture:_record_conversational",
        "conversational capture ended",
        {
            "end_reason": end_reason,
            "seconds": round(time.monotonic() - t0, 2),
            "voice_started": voice_since is not None,
            "peak_rms": round(peak_rms, 2),
            "threshold": CONV_RMS_THRESHOLD,
        },
        "H6",
    )
    # #endregion


def request_ptt_session_from_wake(overlay=None) -> None:
    """
    Start a capture session from wake word or `` ` ``: recording UI + mic.
    Uses silence-based end-of-utterance (hands-free); releasing Right Option
    still stops early.
    """
    global _next_session_conversational
    with _conversational_lock:
        _next_session_conversational = True
    try:
        from voice.wake_word import recording_active

        recording_active.set()
    except Exception:
        pass
    if overlay:
        overlay.push("recording")
    if _ptt_start_flag is not None:
        _ptt_start_flag.set()


async def listen_for_command(
    overlay=None,
    *,
    after_ptt_armed: Callable[[], None] | None = None,
    on_backtick: Callable[[], None] | None = None,
) -> AsyncGenerator[bytes, None]:
    """
    Async generator. Each iteration yields PCM audio bytes for one utterance.
    Blocks until push-to-talk key is held, records until released.

    Uses threading.Event (not asyncio.Event) because the keyboard listener
    runs in its own thread — threading.Event can be set/checked across threads
    without needing the asyncio event loop.

    overlay: optional TranscriptionOverlay — if provided, push("recording") is
             called from the keyboard thread the instant Right Option is pressed.

    after_ptt_armed: invoked once the PTT bridge is live (after _ptt_start_flag
             is set). Used to start wake-word listening only after wake can
             trigger the same capture path as Right Option.

    on_backtick: if set, `` ` `` (backtick) invokes this instead of starting a
             second pynput listener (macOS often SIGTRAPs with two listeners).
    """
    audio = pyaudio.PyAudio()
    input_device = _get_active_input_device(audio)
    if input_device:
        print(
            "[voice] Active mic: "
            f'#{input_device["index"]} "{input_device["name"]}" '
            f'({int(input_device["defaultSampleRate"])} Hz)'
        )
    else:
        print("[voice] Active mic: unknown (could not read PyAudio default input device)")

    # threading.Events work across threads; asyncio.Events don't
    global _ptt_start_flag
    start_flag = threading.Event()
    _ptt_start_flag = start_flag
    stop_flag = threading.Event()
    is_recording = threading.Event()
    held_keys: set = set()

    def on_press(key):
        held_keys.add(key)
        try:
            if on_backtick is not None and key.char == "`":
                on_backtick()
                return
        except AttributeError:
            pass
        # Space + Right Option → dismiss overlay
        if key in (TRIGGER_KEY, keyboard.Key.space) and \
                TRIGGER_KEY in held_keys and keyboard.Key.space in held_keys:
            if overlay:
                overlay.push("hidden")
            if is_recording.is_set():
                stop_flag.set()
            return
        if key == TRIGGER_KEY and not is_recording.is_set():
            try:
                from voice.wake_word import recording_active
                recording_active.set()
            except Exception:
                pass
            if overlay:
                overlay.push("recording")
            start_flag.set()

    def on_release(key):
        held_keys.discard(key)
        if key == TRIGGER_KEY and is_recording.is_set():
            stop_flag.set()
            try:
                from voice.wake_word import recording_active
                recording_active.clear()
            except Exception:
                pass

    # macOS: pynput's Listener can SIGTRAP under Qt; disabled by default. Backtick
    # is handled by AppKit global monitor in ui/overlay.py (see
    # invoke_backtick_callback). Set ALI_ENABLE_HOTKEY=1 to use pynput instead.
    _hotkey_enabled = os.environ.get("ALI_ENABLE_HOTKEY") == "1"
    listener = None
    if _hotkey_enabled:
        listener = keyboard.Listener(on_press=on_press, on_release=on_release)
        listener.start()

    print(
        "[voice] Ready — say “Ali”, press ` (backtick), or hold Right Option to record",
        flush=True,
    )
    loop = asyncio.get_event_loop()
    # macOS: starting speech_recognition / a second mic consumer in the same
    # process immediately after PyAudio+pynput init can SIGTRAP ("trace trap").
    # Arm wake-word only after the asyncio loop is waiting on PTT (idle path).
    if after_ptt_armed is not None:
        delay = float(os.environ.get("ALI_WAKE_ARM_DELAY", "0.9"))

        async def _arm_wake_when_safe() -> None:
            await asyncio.sleep(delay)
            try:
                after_ptt_armed()
            except Exception as e:
                print(f"[voice] Failed to start wake listener: {e}", flush=True)

        loop.create_task(_arm_wake_when_safe())

    def _ro_down() -> None:
        if is_recording.is_set():
            return
        try:
            from voice.wake_word import recording_active

            recording_active.set()
        except Exception:
            pass
        if overlay:
            overlay.push("recording")
        start_flag.set()

    def _ro_up() -> None:
        if is_recording.is_set():
            stop_flag.set()
            try:
                from voice.wake_word import recording_active

                recording_active.clear()
            except Exception:
                pass

    register_backtick_callback(on_backtick)
    register_right_option_callbacks(_ro_down, _ro_up)

    global _next_session_conversational

    try:
        while True:
            # Wait for key press without blocking the event loop
            await loop.run_in_executor(None, start_flag.wait)
            start_flag.clear()
            stop_flag.clear()
            is_recording.set()

            with _conversational_lock:
                conversational = _next_session_conversational
                _next_session_conversational = False

            if conversational:
                print(
                    "[voice] Recording... hands-free — pause when done, "
                    "or tap Right Option to stop early"
                )
            else:
                print("[voice] Recording... (release Right Option to stop)")
            frames = []

            stream = audio.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=SAMPLE_RATE,
                input=True,
                frames_per_buffer=CHUNK,
            )

            # Record in a thread so blocking stream.read() doesn't stall the loop
            if conversational:

                def _record() -> None:
                    _record_conversational(stop_flag, stream, frames, CHUNK)

            else:

                def _record() -> None:
                    while not stop_flag.is_set():
                        data = stream.read(CHUNK, exception_on_overflow=False)
                        frames.append(data)

            await loop.run_in_executor(None, _record)

            stream.stop_stream()
            stream.close()
            is_recording.clear()
            try:
                from voice.wake_word import recording_active

                recording_active.clear()
            except Exception:
                pass

            duration = len(frames) * CHUNK / SAMPLE_RATE
            print(f"[voice] Captured {duration:.1f}s of audio ({len(frames)} chunks)")

            if len(frames) < 3:
                print("[voice] Too short — ignored")
                continue

            audio_bytes = _frames_to_wav(frames)
            yield audio_bytes

    finally:
        _ptt_start_flag = None
        register_backtick_callback(None)
        register_right_option_callbacks(None, None)
        if listener is not None:
            listener.stop()
        audio.terminate()


def _frames_to_wav(frames: list[bytes]) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as wf:
        wf.setnchannels(CHANNELS)
        wf.setsampwidth(2)  # 16-bit
        wf.setframerate(SAMPLE_RATE)
        wf.writeframes(b"".join(frames))
    return buf.getvalue()


def _get_active_input_device(audio: pyaudio.PyAudio) -> dict | None:
    """
    Return the current default input device reported by PortAudio.
    This mirrors the mic the app will use when opening input=True stream
    without an explicit device index.
    """
    try:
        info = audio.get_default_input_device_info()
        return {
            "index": int(info.get("index", -1)),
            "name": str(info.get("name", "unknown")),
            "defaultSampleRate": float(info.get("defaultSampleRate", 0.0)),
        }
    except Exception:
        return None
