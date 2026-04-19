"""
Real-time streaming transcription via Deepgram Nova-2 (SDK v6).

Streams 16kHz PCM-16 audio from PyAudio to Deepgram's WebSocket API.
Calls on_interim(text) for partial words and on_final(text) for committed utterances.

Requires: pip install deepgram-sdk
"""
from __future__ import annotations

import threading
from typing import Callable

import pyaudio

from config.settings import DEEPGRAM_API_KEY

SAMPLE_RATE = 16000
CHANNELS    = 1
CHUNK       = 1024
FORMAT      = pyaudio.paInt16

_meeting_active = threading.Event()


def start_meeting_audio() -> None:
    _meeting_active.set()


def stop_meeting_audio() -> None:
    _meeting_active.clear()


def is_meeting_active() -> bool:
    return _meeting_active.is_set()


def stream_transcription_sync(
    stop_event: threading.Event,
    on_interim: Callable[[str], None],
    on_final: Callable[[str], None],
) -> None:
    """
    Blocking — run inside a thread.
    Opens mic, streams to Deepgram until stop_event is set.
    """
    try:
        from deepgram import DeepgramClient  # type: ignore[reportMissingImports]
        from deepgram.listen.v1.socket_client import (  # type: ignore[reportMissingImports]
            ListenV1Results,
        )
        from deepgram.core.events import EventType  # type: ignore[reportMissingImports]
    except ImportError:
        raise RuntimeError("pip install deepgram-sdk")

    dg = DeepgramClient(access_token=DEEPGRAM_API_KEY)

    audio  = pyaudio.PyAudio()
    stream = audio.open(
        format=FORMAT,
        channels=CHANNELS,
        rate=SAMPLE_RATE,
        input=True,
        frames_per_buffer=CHUNK,
    )

    print("[deepgram] Streaming started")
    try:
        with dg.listen.v1.connect(
            model="nova-2",
            encoding="linear16",
            sample_rate=SAMPLE_RATE,
            interim_results=True,
            vad_events=True,
            utterance_end_ms=1200,
        ) as connection:

            def _on_message(msg) -> None:
                if not isinstance(msg, ListenV1Results):
                    return
                try:
                    text = msg.channel.alternatives[0].transcript.strip()
                    if not text:
                        return
                    if msg.is_final:
                        on_final(text)
                    else:
                        on_interim(text)
                except Exception:
                    pass

            connection.on(EventType.MESSAGE, _on_message)

            # Run the listener in a background thread so we can keep sending audio
            listener = threading.Thread(target=connection.start_listening, daemon=True)
            listener.start()

            while not stop_event.is_set():
                data = stream.read(CHUNK, exception_on_overflow=False)
                connection.send_media(data)

            connection.send_close_stream()
            listener.join(timeout=2.0)
    finally:
        stream.stop_stream()
        stream.close()
        audio.terminate()
        print("[deepgram] Streaming stopped")
