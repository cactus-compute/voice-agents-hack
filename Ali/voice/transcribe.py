"""
Layer 1 — Speech-to-Text

Priority order:
  1. faster-whisper  — loads in ~3s, transcribes in ~0.1s. Best for the demo.
  2. Cactus CLI      — `cactus transcribe` uses Parakeet (0.6B). 0.03s inference
                       but ~2.5 min cold-load. Use if pre-warmed at startup.

Demo note: faster-whisper is the default because its model loads quickly.
Cactus/Parakeet is faster per-call but the cold-start dominates in real use.
The audio never leaves the device in either case.
"""

import asyncio
import os
import shutil
import tempfile

try:
    from faster_whisper import WhisperModel  # type: ignore
    WHISPER_AVAILABLE = True
except ImportError:
    WHISPER_AVAILABLE = False

CACTUS_CLI = shutil.which("cactus")
CACTUS_AVAILABLE = CACTUS_CLI is not None

from config.settings import WHISPER_MODEL_SIZE

_whisper_model = None


def warmup():
    """
    Pre-load the Whisper model at startup so the first real transcription
    is instant. Call this once from main.py before entering the listen loop.
    """
    print("[stt] Warming up Whisper model...")
    _get_whisper()
    print("[stt] Ready.")


def _get_whisper():
    global _whisper_model
    if _whisper_model is None:
        _whisper_model = WhisperModel(WHISPER_MODEL_SIZE, device="cpu", compute_type="int8")
    return _whisper_model


async def transcribe(audio_bytes: bytes) -> str:
    """
    Transcribe raw WAV audio bytes → text string.
    Uses faster-whisper by default (fast cold-start).
    Falls back to Cactus if Whisper is unavailable.
    """
    if WHISPER_AVAILABLE:
        return await asyncio.get_event_loop().run_in_executor(
            None, _transcribe_whisper, audio_bytes
        )

    if CACTUS_AVAILABLE:
        return await _transcribe_cactus_cli(audio_bytes)

    raise RuntimeError(
        "No STT backend available. Run: pip install faster-whisper"
    )


def _transcribe_whisper(audio_bytes: bytes) -> str:
    model = _get_whisper()
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(audio_bytes)
        tmp_path = f.name
    try:
        segments, _ = model.transcribe(tmp_path, beam_size=5)
        return " ".join(seg.text for seg in segments).strip()
    finally:
        os.unlink(tmp_path)


async def _transcribe_cactus_cli(audio_bytes: bytes) -> str:
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
        f.write(audio_bytes)
        tmp_path = f.name
    try:
        proc = await asyncio.create_subprocess_exec(
            CACTUS_CLI, "transcribe", tmp_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, stderr = await proc.communicate()
        if proc.returncode != 0:
            raise RuntimeError(stderr.decode().strip())
        return stdout.decode().strip()
    finally:
        os.unlink(tmp_path)
