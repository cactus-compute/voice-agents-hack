"""
Meeting capture mode.

Streams mic audio via Deepgram for real-time word display, then
periodically sends the rolling transcript to Gemma 4 to extract
action items, and executes them via the orchestrator.
"""
from __future__ import annotations

import asyncio
import threading
import time
from typing import Any, Callable

# How often (seconds) to send new transcript to Gemma 4 for action extraction.
EXTRACT_INTERVAL = 12.0

# Stop-words in Deepgram final transcript that end the meeting.
STOP_PHRASES = {"stop", "stop meeting", "end meeting", "stop capture", "ali stop"}


class MeetingCapture:
    """
    Lifecycle: create → await run() to stream; call stop() to end.

    Callbacks (all called from asyncio loop):
      on_interim(text)           — partial words, update overlay live
      on_final(text)             — committed utterance, append to transcript
      on_action_found(item)      — new action item dict from Gemma 4
      on_action_done(task, status) — execution result ("done" | "error")
    """

    def __init__(
        self,
        on_interim: Callable[[str], None],
        on_final: Callable[[str], None],
        on_action_found: Callable[[dict[str, Any]], None],
        on_action_done: Callable[[str, str], None],
    ) -> None:
        self._on_interim      = on_interim
        self._on_final        = on_final
        self._on_action_found = on_action_found
        self._on_action_done  = on_action_done

        self._stop_event     = threading.Event()
        self._final_segments: list[str] = []          # all committed text
        self._unsent_finals:  list[str] = []          # not yet sent to Gemma 4
        self._captured_items: list[dict[str, Any]] = []
        self._lock = threading.Lock()
        self._loop: asyncio.AbstractEventLoop | None = None

    # ── Public ────────────────────────────────────────────────────────────────

    def stop(self) -> None:
        self._stop_event.set()

    async def run(self) -> None:
        from voice.deepgram_stream import stream_transcription_sync, start_meeting_audio, stop_meeting_audio
        from intent.meeting_intelligence import extract_action_items, item_to_intent
        from orchestrator.orchestrator import Orchestrator

        self._loop = asyncio.get_event_loop()
        orchestrator = Orchestrator()

        start_meeting_audio()

        def _interim(text: str) -> None:
            if self._loop:
                self._loop.call_soon_threadsafe(self._on_interim, text)

        def _final(text: str) -> None:
            # Check for stop command inside the stream
            if text.lower().strip().rstrip(".!?") in STOP_PHRASES:
                self._stop_event.set()
                return
            with self._lock:
                self._final_segments.append(text)
                self._unsent_finals.append(text)
            if self._loop:
                self._loop.call_soon_threadsafe(self._on_final, text)

        # Start Deepgram in a background thread
        stream_thread = threading.Thread(
            target=stream_transcription_sync,
            args=(self._stop_event, _interim, _final),
            daemon=True,
        )
        stream_thread.start()

        last_extract = time.monotonic()

        try:
            while not self._stop_event.is_set():
                await asyncio.sleep(1.0)

                if time.monotonic() - last_extract < EXTRACT_INTERVAL:
                    continue

                with self._lock:
                    segment = " ".join(self._unsent_finals).strip()
                    self._unsent_finals.clear()

                last_extract = time.monotonic()

                if not segment:
                    continue

                print(f"[meeting] Analyzing segment: {segment[:80]}…")

                try:
                    new_items = await extract_action_items(segment, self._captured_items)
                except Exception as e:
                    print(f"[meeting] Extraction error: {e}")
                    continue

                for item in new_items:
                    self._captured_items.append(item)
                    self._on_action_found(item)
                    print(f"[meeting] Action found: {item.get('task')}")

                    # Execute asynchronously — don't block the stream
                    asyncio.create_task(
                        self._execute_item(item, orchestrator)
                    )
        finally:
            self._stop_event.set()
            stop_meeting_audio()
            stream_thread.join(timeout=3.0)

    async def _execute_item(self, item: dict[str, Any], orchestrator) -> None:
        from intent.meeting_intelligence import item_to_intent
        task = item.get("task", "")
        try:
            intent = item_to_intent(item)
            if intent.goal.value != "unknown":
                await orchestrator.run(intent)
            self._on_action_done(task, "done")
        except Exception as e:
            print(f"[meeting] Execution failed for '{task}': {e}")
            self._on_action_done(task, "error")
