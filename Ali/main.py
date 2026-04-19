"""
YC Voice Agent — entry point.
Ties all five layers together in a single push-to-talk loop.

Thread model
────────────
  Main thread : Qt event loop       (macOS AppKit requires UI on main thread)
  Background  : asyncio event loop  (voice capture, STT, intent, orchestrator)

The TranscriptionOverlay bridges the two via queue.Queue.
"""

from __future__ import annotations

import asyncio
import faulthandler
import os
import signal
import sys
import threading
from typing import Callable, Protocol

# Dump Python + native stack on fatal signals. `enable()` already hooks SIGSEGV/SIGBUS/etc.
# on POSIX; do not call `register()` for the same signals — Python raises RuntimeError.
faulthandler.enable(file=sys.stderr, all_threads=True)

# Force line-buffered stdout/stderr so we never lose the last few prints before a crash.
try:
    sys.stdout.reconfigure(line_buffering=True)  # type: ignore[attr-defined]
    sys.stderr.reconfigure(line_buffering=True)  # type: ignore[attr-defined]
except Exception:
    pass

from config.preflight import run_preflight_checks


class TranscriptionOverlay(Protocol):
    def push(self, state: str, text: str = "") -> None: ...


def _build_overlay() -> tuple["TranscriptionOverlay", Callable[[], None]]:
    backend = os.getenv("ALI_UI_BACKEND", "qt").strip().lower()
    if backend == "qt":
        from PySide6.QtWidgets import QApplication  # pyright: ignore[reportMissingImports]
        from ui.overlay import TranscriptionOverlay

        app = QApplication(sys.argv)
        overlay = TranscriptionOverlay(app)

        # av + cv2 both bundle libavdevice with the same ObjC class names.
        # Python's normal teardown kills daemon threads mid-AVFoundation call,
        # causing a SIGTRAP. os._exit() skips teardown entirely.
        def _hard_exit(*_) -> None:
            os._exit(0)

        signal.signal(signal.SIGINT, _hard_exit)
        try:
            signal.signal(signal.SIGTERM, _hard_exit)
        except (ValueError, OSError):
            pass

        def _run_qt() -> None:
            try:
                app.exec()
            finally:
                os._exit(0)

        return overlay, _run_qt

    from ui.web_overlay import TranscriptionOverlay

    overlay = TranscriptionOverlay()
    return overlay, overlay.run_forever


# ── Asyncio agent loop (runs in background thread) ────────────────────────────

async def _agent_main(overlay: TranscriptionOverlay) -> None:
    # Import order on macOS: warm up STT first, then import capture; wake-word
    # starts in after_ptt_armed() only after the PTT bridge exists (see capture.py).
    from voice.transcribe import transcribe, warmup
    from intent.parser import parse_intent
    from orchestrator.orchestrator import Orchestrator
    from ui.menu_bar import MenuBar

    orchestrator = Orchestrator()
    menu_bar = MenuBar()
    agent_loop = asyncio.get_running_loop()
    command_lock = asyncio.Lock()

    warmup()   # pre-load Whisper so first transcription is instant

    from voice.capture import listen_for_command, request_ptt_session_from_wake
    from voice.wake_word import start_wake_word_listener

    async def _handle_transcript(transcript: str) -> None:
        async with command_lock:
            try:
                print("\n─── New command ───────────────────────────────")
                overlay.push("transcript", f'"{transcript}"')

                # 2 — Parse intent
                menu_bar.set_status("parsing intent")
                print("[2/3] Parsing intent...")
                intent = await parse_intent(transcript)
                intent = _normalize_voice_intent(intent, transcript)
                print(f"      → goal={intent.goal.value}  slots={intent.slots}")
                # #region agent log
                try:
                    import json as _j, os as _o, time as _t
                    _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
                    _o.makedirs(_o.path.dirname(_p), exist_ok=True)
                    with open(_p, "a") as _f:
                        _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H4",
                            "location":"main:intent_parsed",
                            "message":"intent classification result",
                            "data":{"transcript": transcript, "goal": intent.goal.value,
                                    "has_slots": bool(intent.slots)},
                            "timestamp": int(_t.time()*1000)})+"\n")
                        _f.flush()
                except Exception:
                    pass
                # #endregion

                goal_label = intent.goal.value.replace("_", " ").title()
                if intent.goal.value not in ("unknown", "capture_meeting"):
                    overlay.push("intent", f"{goal_label}")

                # ── Meeting capture mode ──────────────────────────────────────
                if intent.goal.value == "capture_meeting":
                    from voice.speak import speak
                    speak("Got it, I'm capturing the meeting.")
                    agent_loop.create_task(_run_meeting_capture(overlay, menu_bar))
                    return

                if intent.goal.value == "unknown":
                    from intent.chat import chat_reply
                    from voice.speak import speak
                    print("[2.5/3] Unknown intent → conversational reply...")
                    reply = await chat_reply(transcript)
                    print(f'      ← "{reply}"')
                    # #region agent log
                    try:
                        import json as _j, os as _o, time as _t
                        _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
                        _o.makedirs(_o.path.dirname(_p), exist_ok=True)
                        with open(_p, "a") as _f:
                            _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H4",
                                "location":"main:chat_reply",
                                "message":"conversational reply generated",
                                "data":{"reply": reply[:200], "len": len(reply)},
                                "timestamp": int(_t.time()*1000)})+"\n")
                            _f.flush()
                    except Exception:
                        pass
                    # #endregion
                    overlay.push("assistant", reply or "I didn't catch that.")
                    speak(reply or "I didn't catch that.")
                    return

                # 3 — Execute (known intent)
                print("[3/3] Executing...")
                menu_bar.set_status("running")
                overlay.push("action", f"Running: {goal_label}…")

                if intent.goal.value == "open_url":
                    from voice.speak import speak
                    url = _intent_url(intent) or "https://mail.google.com"
                    _open_url_local(url)
                    # #region agent log
                    try:
                        import json as _j, os as _o, time as _t
                        _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
                        _o.makedirs(_o.path.dirname(_p), exist_ok=True)
                        with open(_p, "a") as _f:
                            _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H11",
                                "location":"main:open_url_local",
                                "message":"opened URL locally (no vision planner)",
                                "data":{"url": url},
                                "timestamp": int(_t.time()*1000)})+"\n")
                            _f.flush()
                    except Exception:
                        pass
                    # #endregion
                    print(f"      ✓ Opened {url}")
                    overlay.push("done")
                    speak("Opened.")
                    return

                revealed_name: str | None = None
                if intent.goal.value == "find_file":
                    from intent.file_resolve import enrich_intent_with_resolved_files
                    from voice.speak import speak
                    await enrich_intent_with_resolved_files(intent, transcript)
                    revealed_name = _revealed_basename(intent)
                    found_path = _revealed_path(intent)
                    if revealed_name is not None:
                        overlay.push("revealed", revealed_name)
                    if found_path is not None:
                        _reveal_in_finder(found_path)
                        print("      ✓ Done")
                        overlay.push("done")
                        return
                    # Do not fall back to vision planner for unresolved local file lookups.
                    # It causes unrelated screenshot/confirmation prompts.
                    msg = "I couldn't find that file yet. Try saying the exact filename, like 'open my resume pdf'."
                    print("      (find_file unresolved — skipping vision planner)")
                    # #region agent log
                    try:
                        import json as _j, os as _o, time as _t
                        _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
                        _o.makedirs(_o.path.dirname(_p), exist_ok=True)
                        with open(_p, "a") as _f:
                            _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H8",
                                "location":"main:find_file_unresolved",
                                "message":"skipping orchestrator vision fallback for find_file",
                                "data":{"transcript": transcript, "slots": intent.slots},
                                "timestamp": int(_t.time()*1000)})+"\n")
                            _f.flush()
                    except Exception:
                        pass
                    # #endregion
                    overlay.push("error", msg)
                    speak(msg)
                    return

                await orchestrator.run(intent)

                print("      ✓ Done")
                if revealed_name is None:
                    revealed_name = _revealed_basename(intent)
                    if revealed_name is not None:
                        overlay.push("revealed", revealed_name)
                    else:
                        overlay.push("done")
            except Exception as e:
                import traceback
                print(f"[error] {e}")
                traceback.print_exc()
                menu_bar.set_status("error")
                overlay.push("error", str(e))
            finally:
                menu_bar.set_status("ready")

    def _on_ptt_armed() -> None:
        def _wake_heard(raw_text: str) -> None:
            tail = _extract_wake_tail(raw_text)
            if tail and _should_inline_wake_tail(tail):
                # Direct wake-command path: "Ali open my resume" skips second capture.
                # #region agent log
                try:
                    import json as _j, os as _o, time as _t
                    _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
                    _o.makedirs(_o.path.dirname(_p), exist_ok=True)
                    with open(_p, "a") as _f:
                        _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H6",
                            "location":"main:wake_inline_dispatch",
                            "message":"dispatching command directly from wake phrase",
                            "data":{"wake_text": raw_text, "tail": tail},
                            "timestamp": int(_t.time()*1000)})+"\n")
                        _f.flush()
                except Exception:
                    pass
                # #endregion
                asyncio.run_coroutine_threadsafe(_handle_transcript(tail), agent_loop)
                return
            if tail:
                # Tail is too short/ambiguous (e.g. "open my"), so switch to
                # conversational capture to collect the full command.
                # #region agent log
                try:
                    import json as _j, os as _o, time as _t
                    _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
                    _o.makedirs(_o.path.dirname(_p), exist_ok=True)
                    with open(_p, "a") as _f:
                        _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H9",
                            "location":"main:wake_tail_deferred",
                            "message":"wake tail too short; deferring to live capture",
                            "data":{"wake_text": raw_text, "tail": tail},
                            "timestamp": int(_t.time()*1000)})+"\n")
                        _f.flush()
                except Exception:
                    pass
                # #endregion

            sched = getattr(overlay, "schedule_wake_prompt", None)
            if sched is not None:
                sched(lambda: request_ptt_session_from_wake(overlay))  # type: ignore[misc]
            else:
                request_ptt_session_from_wake(overlay)

        start_wake_word_listener(_wake_heard)  # type: ignore[arg-type]

    def _on_backtick() -> None:
        # Backtick stops meeting if one is running, otherwise starts wake
        if _active_meeting is not None:
            _active_meeting.stop()
            return
        sched = getattr(overlay, "schedule_wake_prompt", None)
        if sched is not None:
            sched(lambda: request_ptt_session_from_wake(overlay))  # type: ignore[misc]
        else:
            request_ptt_session_from_wake(overlay)

    menu_bar.set_status("ready")

    async for audio_bytes in listen_for_command(
        overlay=overlay,
        after_ptt_armed=_on_ptt_armed,
        on_backtick=_on_backtick,
    ):
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
        await _handle_transcript(transcript)


_active_meeting: "MeetingCapture | None" = None  # type: ignore[name-defined]


async def _run_meeting_capture(overlay, menu_bar) -> None:
    global _active_meeting
    from voice.meeting_capture import MeetingCapture

    menu_bar.set_status("meeting")
    overlay.push("meeting_start")

    def _on_interim(text: str) -> None:
        overlay.push("meeting_interim", text)

    def _on_final(text: str) -> None:
        overlay.push("meeting_final", text)

    def _on_action_found(item: dict) -> None:
        task = item.get("task", "")
        print(f"[meeting] Action: {task}")
        overlay.push("meeting_action", task)

    def _on_action_done(task: str, status: str) -> None:
        overlay.push("meeting_action_update", f"{task}|{status}")

    capture = MeetingCapture(_on_interim, _on_final, _on_action_found, _on_action_done)
    _active_meeting = capture
    try:
        await capture.run()
    finally:
        _active_meeting = None
        overlay.push("meeting_stop")
        menu_bar.set_status("ready")
        print("[meeting] Session ended")


def _revealed_basename(intent) -> str | None:
    """Return the basename of a FIND_FILE that resolved to an existing path, else None."""
    if intent.goal.value != "find_file":
        return None
    resolved = intent.slots.get("resolved_local_files") if isinstance(intent.slots, dict) else None
    if not isinstance(resolved, dict):
        return None
    path = resolved.get("found")
    if not isinstance(path, str) or not path:
        return None
    return os.path.basename(path)


def _revealed_path(intent) -> str | None:
    if intent.goal.value != "find_file":
        return None
    resolved = intent.slots.get("resolved_local_files") if isinstance(intent.slots, dict) else None
    if not isinstance(resolved, dict):
        return None
    path = resolved.get("found")
    if not isinstance(path, str) or not path:
        return None
    return path


def _intent_url(intent) -> str | None:
    target = getattr(intent, "target", None)
    if isinstance(target, dict):
        value = target.get("value")
        if isinstance(value, str) and value.strip():
            return value.strip()
    slots = getattr(intent, "slots", None)
    if isinstance(slots, dict):
        url = slots.get("url")
        if isinstance(url, str) and url.strip():
            return url.strip()
    return None


def _reveal_in_finder(path: str) -> None:
    if sys.platform != "darwin":
        return
    try:
        import subprocess
        subprocess.run(["open", "-R", path], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception:
        pass


def _open_url_local(url: str) -> None:
    if not url:
        return
    try:
        import subprocess
        subprocess.run(["open", url], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
    except Exception:
        pass


def _extract_wake_tail(raw_text: str) -> str:
    """
    For wake phrases like "ali open my resume", return "open my resume".
    If there's no command tail (just "ali"), return "".
    """
    text_raw = (raw_text or "").strip()
    text = text_raw.lower()
    for prefix in ("hey ali", "okay ali", "ok ali", "ali"):
        if text.startswith(prefix):
            tail = text_raw[len(prefix):].strip(" ,.!?-")
            return tail
    # Inline wake fallback from wake_word.py, e.g. "open my resume"
    # when upstream STT misses the leading "ali" token.
    for prefix in (
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
    ):
        if text.startswith(prefix):
            return text_raw.strip(" ,.!?-")
    return ""


def _should_inline_wake_tail(tail: str) -> bool:
    """
    Inline only when the tail is specific enough to execute directly.
    Partial tails like "open my" should trigger live capture instead.
    """
    t = (tail or "").strip().lower()
    if not t:
        return False
    words = t.split()
    if len(words) >= 4:
        return True
    if any(k in t for k in ("resume", "cv", "cover letter", ".pdf", ".doc", ".docx")):
        return True
    trailing_fillers = {"my", "the", "a", "an", "to", "for"}
    if words[-1] in trailing_fillers:
        return False
    return len(words) >= 3



def _normalize_voice_intent(intent, transcript: str):
    """
    Post-parse guardrail for wake-voice ambiguity.
    If parser returns SEND_EMAIL for utterances that sound like opening a file,
    remap to FIND_FILE so we avoid unrelated planner/screenshot flows.
    """
    try:
        from intent.schema import KnownGoal
    except Exception:
        return intent

    text = (transcript or "").lower()
    if intent.goal != KnownGoal.SEND_EMAIL:
        return intent

    has_email_words = any(w in text for w in ("email", "mail", "gmail", "inbox", "send to"))
    looks_like_open = any(w in text for w in ("open", "find", "show", "reveal", "locate", "resume", "cv"))
    if has_email_words or not looks_like_open:
        return intent

    file_like_words = ("resume", "cv", "cover letter", "pdf", "doc", "docx", "deck", "file", "folder")
    web_like_words = ("linkedin", "github", "notion", "gmail", "inbox", "twitter", "x.com", "website", "site", "url")
    looks_file_like = any(w in text for w in file_like_words)
    looks_web_like = any(w in text for w in web_like_words) and not looks_file_like

    if looks_web_like:
        intent.goal = KnownGoal.OPEN_URL
        service = _extract_web_service(text)
        url = f"https://www.{service}.com" if service else "https://www.google.com"
        if isinstance(intent.target, dict):
            intent.target = {"type": "url", "value": url}
        if isinstance(intent.slots, dict):
            intent.slots["url"] = url
        # #region agent log
        try:
            import json as _j, os as _o, time as _t
            _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
            _o.makedirs(_o.path.dirname(_p), exist_ok=True)
            with open(_p, "a") as _f:
                _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H10",
                    "location":"main:intent_remap_send_email_to_open_url",
                    "message":"remapped likely misclassified send_email to open_url",
                    "data":{"transcript": transcript, "url": url},
                    "timestamp": int(_t.time()*1000)})+"\n")
                _f.flush()
        except Exception:
            pass
        # #endregion
        return intent

    # #region agent log
    try:
        import json as _j, os as _o, time as _t
        _p = "/Users/alspenceramitojr/Desktop/Ali/.cursor/debug-4ea166.log"
        _o.makedirs(_o.path.dirname(_p), exist_ok=True)
        with open(_p, "a") as _f:
            _f.write(_j.dumps({"sessionId":"4ea166","hypothesisId":"H10",
                "location":"main:intent_remap_send_email_to_find_file",
                "message":"remapped likely misclassified send_email to find_file",
                "data":{"transcript": transcript, "slots": intent.slots},
                "timestamp": int(_t.time()*1000)})+"\n")
            _f.flush()
    except Exception:
        pass
    # #endregion

    intent.goal = KnownGoal.FIND_FILE
    if isinstance(intent.slots, dict):
        fq = intent.slots.get("file_query")
        if not isinstance(fq, str) or not fq.strip():
            intent.slots["file_query"] = "resume"
    return intent


def _extract_web_service(text: str) -> str | None:
    for token in ("linkedin", "github", "notion", "gmail", "twitter"):
        if token in text:
            return token
    return None


def _run_agent(overlay: "TranscriptionOverlay") -> None:
    """Entry point for the background asyncio thread."""
    loop = asyncio.new_event_loop()
    asyncio.set_event_loop(loop)
    try:
        loop.run_until_complete(_agent_main(overlay))
    finally:
        loop.close()


# ── Main (Qt on main thread) ──────────────────────────────────────────────────

def main() -> None:
    run_preflight_checks()

    overlay, run_ui = _build_overlay()

    agent_thread = threading.Thread(target=_run_agent, args=(overlay,), daemon=True)
    agent_thread.start()

    # Backtick is handled inside listen_for_command (single pynput listener).
    # Two keyboard.Listener instances on macOS often crash with SIGTRAP.
    print("[demo] Say 'Ali' or press ` (backtick): tone → then hands-free voice command")

    # Block here on the main thread running the selected UI loop
    run_ui()


if __name__ == "__main__":
    main()
