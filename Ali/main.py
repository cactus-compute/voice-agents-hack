"""
YC Voice Agent — entry point.
Ties all five layers together in a single push-to-talk loop.

Thread model
────────────
  Main thread : tkinter event loop  (macOS AppKit requires UI on main thread)
  Background  : asyncio event loop  (voice capture, STT, intent, orchestrator)

The TranscriptionOverlay bridges the two via queue.Queue.
"""

import asyncio
import threading
import tkinter as tk

from config.preflight import run_preflight_checks
from ui.overlay import TranscriptionOverlay


# ── Asyncio agent loop (runs in background thread) ────────────────────────────

async def _agent_main(overlay: TranscriptionOverlay) -> None:
    from voice.capture import listen_for_command
    from voice.transcribe import transcribe, warmup
    from intent.parser import parse_intent
    from orchestrator.orchestrator import Orchestrator
    from ui.menu_bar import MenuBar

    orchestrator = Orchestrator()
    menu_bar = MenuBar()

    warmup()   # pre-load Whisper so first transcription is instant
    menu_bar.set_status("ready")

    async for audio_bytes in listen_for_command(overlay=overlay):
        try:
            print("\n─── New command ───────────────────────────────")

            # 1 — Transcribe
            menu_bar.set_status("transcribing")
            overlay.push("transcribing")
            print("[1/3] Transcribing...")
            transcript = await transcribe(audio_bytes)
            print(f'      → "{transcript}"')

            if not transcript.strip():
                print("      (empty transcript — skipping)")
                overlay.push("hidden")
                continue

            overlay.push("transcript", f'"{transcript}"')

            # 2 — Parse intent
            menu_bar.set_status("parsing intent")
            print("[2/3] Parsing intent...")
            intent = await parse_intent(transcript)
            print(f"      → goal={intent.goal.value}  slots={intent.slots}")

            goal_label = intent.goal.value.replace("_", " ").title()
            overlay.push("intent", f"{goal_label}")

            # 3 — Execute
            print("[3/3] Executing...")
            menu_bar.set_status("running")
            overlay.push("action", f"Running: {goal_label}…")
            await orchestrator.run(intent)

            print("      ✓ Done")
            overlay.push("done")

        except Exception as e:
            import traceback
            print(f"[error] {e}")
            traceback.print_exc()
            menu_bar.set_status("error")
            overlay.push("error", str(e))
        finally:
            menu_bar.set_status("ready")


def _run_agent(overlay: TranscriptionOverlay) -> None:
    """Entry point for the background asyncio thread."""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(_agent_main(overlay))
    finally:
        loop.close()


# ── Main (tkinter on main thread) ─────────────────────────────────────────────

def main() -> None:
    run_preflight_checks()

    root = tk.Tk()
    root.withdraw()   # no bare root window — we only want the overlay

    overlay = TranscriptionOverlay(root)

    agent_thread = threading.Thread(target=_run_agent, args=(overlay,), daemon=True)
    agent_thread.start()

    # Block here on the main thread running tkinter's event loop
    root.mainloop()


if __name__ == "__main__":
    main()
