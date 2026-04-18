#!/usr/bin/env python3
"""
Debug runner for local testing without push-to-talk/hotkey capture.

Examples:
  python scripts/debug_local_flow.py --transcript "Text Hanzi I'll be 10 minutes late"
  python scripts/debug_local_flow.py --audio /tmp/sample.wav
  python scripts/debug_local_flow.py --audio --record-seconds 5
  VOICE_AGENT_DRY_RUN=1 python scripts/debug_local_flow.py --transcript "Apply to YC using my resume" --execute
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
import wave
from dataclasses import asdict
from pathlib import Path
from datetime import datetime

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from config.preflight import run_preflight_checks
from config.settings import DRY_RUN
from intent.parser import CACTUS_AVAILABLE, GEMINI_AVAILABLE, parse_intent
from orchestrator.orchestrator import Orchestrator
from orchestrator.router import route_intent
from voice.transcribe import CACTUS_AVAILABLE as STT_CACTUS_AVAILABLE
from voice.transcribe import WHISPER_AVAILABLE, transcribe, warmup


def _make_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Debug YC Voice Agent flow without hotkey listener")
    parser.add_argument("--transcript", type=str, help="Raw transcript text to parse/execute")
    parser.add_argument(
        "--audio",
        nargs="?",
        const="record",
        type=str,
        help=(
            "Path to WAV audio file for STT, or pass --audio with no value to record "
            "from your microphone and save it locally."
        ),
    )
    parser.add_argument(
        "--record-seconds",
        type=float,
        default=6.0,
        help="Recording duration when using --audio without a path (default: 6.0).",
    )
    parser.add_argument(
        "--record-dir",
        type=str,
        default=str(ROOT / "debug_recordings"),
        help="Directory to store recorded WAV files (default: ./debug_recordings).",
    )
    parser.add_argument(
        "--input-device-index",
        type=int,
        default=None,
        help="Optional PyAudio input device index override for --audio record mode.",
    )
    parser.add_argument(
        "--execute",
        action="store_true",
        help="Execute orchestrator plan after parsing (respecting VOICE_AGENT_DRY_RUN)",
    )
    parser.add_argument(
        "--auto-approve",
        action="store_true",
        help="Auto-approve confirmation gates during --execute for non-interactive debugging",
    )
    parser.add_argument(
        "--vision-loop",
        action="store_true",
        help="Enable vision-first orchestration loop (default: on)",
    )
    parser.add_argument(
        "--no-vision-loop",
        action="store_true",
        help="Disable vision-first orchestration loop and use static plans only.",
    )
    return parser


def _print_runtime_info() -> None:
    print("[debug] Runtime configuration")
    print(f"[debug] DRY_RUN={DRY_RUN}")
    print(f"[debug] STT backends: whisper={WHISPER_AVAILABLE}, cactus={STT_CACTUS_AVAILABLE}")
    print(f"[debug] Intent backends: gemini={GEMINI_AVAILABLE}, cactus={CACTUS_AVAILABLE}")


async def _get_transcript(args: argparse.Namespace) -> str:
    if args.transcript:
        return args.transcript

    if args.audio:
        if args.audio == "record":
            audio_path = _record_wav_file(
                record_seconds=args.record_seconds,
                record_dir=Path(args.record_dir).expanduser().resolve(),
                input_device_index=args.input_device_index,
            )
        else:
            audio_path = Path(args.audio).expanduser().resolve()
            if not audio_path.exists():
                raise FileNotFoundError(f"Audio file not found: {audio_path}")
        warmup()
        print(f"[debug] Transcribing audio file: {audio_path}")
        audio_bytes = audio_path.read_bytes()
        return await transcribe(audio_bytes)

    raise ValueError("Provide either --transcript or --audio")


def _record_wav_file(
    record_seconds: float,
    record_dir: Path,
    input_device_index: int | None = None,
) -> Path:
    if record_seconds <= 0:
        raise ValueError("--record-seconds must be greater than zero")
    try:
        import pyaudio
    except Exception as exc:
        raise RuntimeError(
            "Recording requires pyaudio. Install it, or pass --audio /path/to/file.wav instead."
        ) from exc

    record_dir.mkdir(parents=True, exist_ok=True)
    timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
    out_path = record_dir / f"debug_{timestamp}.wav"

    audio = pyaudio.PyAudio()
    sample_format = pyaudio.paInt16
    selected_index, selected_info = _resolve_input_device(audio, input_device_index)
    _print_input_device_debug(audio, selected_index)

    channels = 1
    sample_rate = int(selected_info.get("defaultSampleRate", 48000))
    chunk_size = 1024
    frame_count = int(sample_rate / chunk_size * record_seconds)
    stream = audio.open(
        format=sample_format,
        channels=channels,
        rate=sample_rate,
        input=True,
        frames_per_buffer=chunk_size,
        input_device_index=selected_index,
    )
    print(
        f"[debug] Recording mic input for {record_seconds:.1f}s "
        f"(device #{selected_index}, rate={sample_rate}) -> {out_path}"
    )
    frames: list[bytes] = []
    try:
        for _ in range(frame_count):
            frames.append(stream.read(chunk_size, exception_on_overflow=False))
    finally:
        stream.stop_stream()
        stream.close()
        sample_width = audio.get_sample_size(sample_format)
        audio.terminate()

    with wave.open(str(out_path), "wb") as wf:
        wf.setnchannels(channels)
        wf.setsampwidth(sample_width)
        wf.setframerate(sample_rate)
        audio_data = b"".join(frames)
        wf.writeframes(audio_data)

    rms, peak = _pcm16_levels(audio_data)
    print(f"[debug] Recording levels: rms={rms} peak={peak}")
    if peak == 0:
        raise RuntimeError(
            "Recorded audio is silent (all zero samples). "
            "Check macOS microphone permission for your terminal/IDE and try "
            "--input-device-index with a real mic device."
        )

    print(f"[debug] Saved recording: {out_path}")
    return out_path


def _print_input_device_debug(audio, selected_index: int) -> None:
    print(f"[debug] Recording input device: {selected_index}")
    try:
        default = audio.get_default_input_device_info()
        print(
            "[debug] Default input device: "
            f'#{int(default.get("index", -1))} "{default.get("name", "unknown")}" '
            f'channels={int(default.get("maxInputChannels", 0))} '
            f'rate={int(default.get("defaultSampleRate", 0.0))}'
        )
    except Exception as exc:
        print(f"[debug][warn] Could not read default input device: {exc}")

    print("[debug] Available input devices:")
    for idx in range(audio.get_device_count()):
        info = audio.get_device_info_by_index(idx)
        max_input = int(info.get("maxInputChannels", 0))
        if max_input <= 0:
            continue
        print(
            f'  - #{idx}: "{info.get("name", "unknown")}" '
            f"channels={max_input} rate={int(info.get('defaultSampleRate', 0.0))}"
        )


def _resolve_input_device(audio, input_device_index: int | None) -> tuple[int, dict]:
    if input_device_index is not None:
        info = audio.get_device_info_by_index(input_device_index)
        if int(info.get("maxInputChannels", 0)) <= 0:
            raise RuntimeError(f"Device #{input_device_index} is not an input device.")
        return input_device_index, info

    default = audio.get_default_input_device_info()
    default_index = int(default.get("index", -1))
    if default_index < 0:
        raise RuntimeError("No default input device found.")
    return default_index, default


def _pcm16_levels(audio_data: bytes) -> tuple[int, int]:
    if not audio_data:
        return 0, 0
    if len(audio_data) % 2 != 0:
        audio_data = audio_data[:-1]
    if not audio_data:
        return 0, 0

    # 16-bit little-endian signed PCM
    sample_count = len(audio_data) // 2
    import struct

    samples = struct.unpack(f"<{sample_count}h", audio_data)
    peak = max(abs(s) for s in samples)
    mean_square = sum(s * s for s in samples) / sample_count
    rms = int(mean_square ** 0.5)
    return rms, peak


async def main() -> int:
    args = _make_parser().parse_args()
    run_preflight_checks()
    _print_runtime_info()

    transcript = await _get_transcript(args)
    print(f"[debug] Transcript: {transcript!r}")

    intent = await parse_intent(transcript)
    print("[debug] Parsed intent:")
    print(json.dumps(asdict(intent), indent=2, default=str))

    plan = route_intent(intent)
    if intent.goal.value == "unknown":
        print("[debug] Intent is unknown; no execution plan.")
    else:
        print(f"[debug] Plan has {len(plan)} step(s):")
        for idx, step in enumerate(plan):
            print(
                f"  - step[{idx}] name={step.get('name')} "
                f"executor={step.get('executor')} action={step.get('action')}"
            )

    if args.execute:
        if args.vision_loop and args.no_vision_loop:
            raise ValueError("Pass only one of --vision-loop or --no-vision-loop")
        if args.auto_approve:
            # Patch the orchestrator's confirmation hook for headless debug runs.
            import orchestrator.orchestrator as orchestrator_module

            async def _always_approve(_: str) -> bool:
                return True

            orchestrator_module.ask_confirmation = _always_approve
            print("[debug] Confirmation gate: auto-approve enabled")
        print("[debug] Executing orchestrator...")
        orchestrator = Orchestrator(
            vision_loop_enabled=not args.no_vision_loop,
        )
        await orchestrator.run(intent)
    else:
        print("[debug] Skipping execution (pass --execute to run orchestrator).")

    return 0


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
