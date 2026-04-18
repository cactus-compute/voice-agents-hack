"""
Layer 1 — Voice Capture
Push-to-talk: hold Right Shift to record, release to stop.
(Option key avoided — conflicts with Omi which also uses it.)
Yields raw audio bytes for each completed utterance.
"""

import asyncio
import io
import threading
import wave
from typing import AsyncGenerator

import pyaudio
from pynput import keyboard

SAMPLE_RATE = 16000
CHANNELS = 1
CHUNK = 1024
FORMAT = pyaudio.paInt16

# The hotkey that triggers recording
# Right Shift — avoids conflict with Omi which also captures Option/alt
TRIGGER_KEY = keyboard.Key.shift_r


async def listen_for_command(overlay=None) -> AsyncGenerator[bytes, None]:
    """
    Async generator. Each iteration yields PCM audio bytes for one utterance.
    Blocks until push-to-talk key is held, records until released.

    Uses threading.Event (not asyncio.Event) because the keyboard listener
    runs in its own thread — threading.Event can be set/checked across threads
    without needing the asyncio event loop.

    overlay: optional TranscriptionOverlay — if provided, push("recording") is
             called from the keyboard thread the instant Right Shift is pressed.
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
    start_flag = threading.Event()
    stop_flag = threading.Event()
    is_recording = threading.Event()
    held_keys: set = set()

    def on_press(key):
        held_keys.add(key)
        # Space + Right Shift → dismiss overlay
        if key in (TRIGGER_KEY, keyboard.Key.space) and \
                TRIGGER_KEY in held_keys and keyboard.Key.space in held_keys:
            if overlay:
                overlay.push("hidden")
            if is_recording.is_set():
                stop_flag.set()
            return
        if key == TRIGGER_KEY and not is_recording.is_set():
            if overlay:
                overlay.push("recording")
            start_flag.set()

    def on_release(key):
        held_keys.discard(key)
        if key == TRIGGER_KEY and is_recording.is_set():
            stop_flag.set()

    listener = keyboard.Listener(on_press=on_press, on_release=on_release)
    listener.start()

    print("[voice] Ready — hold Right Shift to speak, release to send")

    loop = asyncio.get_event_loop()

    try:
        while True:
            # Wait for key press without blocking the event loop
            await loop.run_in_executor(None, start_flag.wait)
            start_flag.clear()
            stop_flag.clear()
            is_recording.set()

            print("[voice] Recording... (release Right Shift to stop)")
            frames = []

            stream = audio.open(
                format=FORMAT,
                channels=CHANNELS,
                rate=SAMPLE_RATE,
                input=True,
                frames_per_buffer=CHUNK,
            )

            # Record in a thread so blocking stream.read() doesn't stall the loop
            def _record():
                while not stop_flag.is_set():
                    data = stream.read(CHUNK, exception_on_overflow=False)
                    frames.append(data)

            await loop.run_in_executor(None, _record)

            stream.stop_stream()
            stream.close()
            is_recording.clear()

            duration = len(frames) * CHUNK / SAMPLE_RATE
            print(f"[voice] Captured {duration:.1f}s of audio ({len(frames)} chunks)")

            if len(frames) < 3:
                print("[voice] Too short — ignored")
                continue

            audio_bytes = _frames_to_wav(frames)
            yield audio_bytes

    finally:
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
