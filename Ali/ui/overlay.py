"""
Liquid glass overlay — Apple-style frosted pill, top-center, expands downward.
"""

from __future__ import annotations

import datetime
import os
import queue
import subprocess
import sys
import threading
from typing import Callable

from PySide6.QtCore import QPoint, QRect, Qt, QObject, QTimer, Signal, Slot  # pyright: ignore[reportMissingImports]
from PySide6.QtGui import (  # pyright: ignore[reportMissingImports]
    QBrush, QColor, QCursor, QFont, QGuiApplication, QImage, QLinearGradient,
    QPainter, QPainterPath, QPen, QPixmap,
)
from PySide6.QtWidgets import QApplication, QWidget  # pyright: ignore[reportMissingImports]

# #region agent log
def _dlog(loc: str, msg: str, data: dict, hid: str = "H2") -> None:
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

# NOTE: `cv2` is deliberately NOT imported at module load time.
# `faster-whisper` pulls in PyAV, which bundles its own `libavdevice.dylib`
# registering `AVFFrameReceiver` / `AVFAudioReceiver`. `cv2` bundles the same
# classes. Having both loaded in the same process causes macOS to SIGTRAP
# ("zsh: trace trap") on the next AVFoundation call (even indirect ones from
# PyAudio/CoreAudio). Import cv2 lazily, only when the wake-scene actually
# opens the webcam.

W_WAKE    = 560
H_WAKE    = 200
CAM_W     = 160
CAM_H     = 160
USER_NAME = "Alspencer"

# ── Meeting mode geometry ─────────────────────────────────────────────────────
W_MEETING       = 560
H_MEETING_BASE  = 200    # height before any action items
H_ACTION_ROW    = 34     # height per action item row
MAX_ACTIONS_SHOWN = 5
MAX_TRANSCRIPT_CHARS = 320    # chars of rolling transcript shown


def _time_greeting() -> str:
    h = datetime.datetime.now().hour
    if h < 12:   return "Good morning"
    if h < 17:   return "Good afternoon"
    return "Good evening"


class _CamBridge(QObject):
    frame_ready = Signal(QImage)
    greeted     = Signal()


class _MacGlobalHotkeyBridge(QObject):
    """Marshals AppKit global key events to the Qt main thread."""

    backtick = Signal()
    right_option_down = Signal()
    right_option_up = Signal()

# ── Colors ────────────────────────────────────────────────────────────────────
CITATION_ROW_H = 26
CITATION_CHIP_PAD_X = 10
CITATION_CHIP_GAP = 8

FG          = QColor(246, 246, 250)       # primary text on liquid glass
DIM         = QColor(196, 194, 202)       # secondary text
RED         = QColor("#E8342E")
YELLOW      = QColor("#F3C84B")
BLUE        = QColor("#64D2FF")
GREEN       = QColor("#3CD07A")
ERR         = QColor("#FF6B6B")

# ── Geometry ──────────────────────────────────────────────────────────────────
W_PILL  = 340
W_FULL  = 560
H_PILL  = 58
R       = 29      # large radius → pill shape
MARGIN  = 8       # gap from top (below menu bar)
MARGIN_RIGHT = 16 # gap from right edge when docked-right
MAX_H   = 540
MAX_HIST = 8

# ── Docking ───────────────────────────────────────────────────────────────────
DOCK_TOP    = "top"
DOCK_RIGHT  = "right"

# ── Timing ────────────────────────────────────────────────────────────────────
PULSE_MS    = 500
POLL_MS     = 40
AUTOHIDE_MS = 5_000


def _apply_macos_overlay(win: QWidget) -> None:
    win._vibrancy_active = False  # type: ignore[attr-defined]
    try:
        from AppKit import NSApplication, NSColor, NSVisualEffectView  # type: ignore[reportMissingImports]

        marker = "__ali_overlay__"
        win.setWindowTitle(marker)
        QApplication.processEvents()

        ns_app = NSApplication.sharedApplication()
        ns_win = None
        for candidate in ns_app.windows():
            try:
                if candidate.title() == marker:
                    ns_win = candidate
                    break
            except Exception:
                continue

        if ns_win is not None:
            # NSPopUpMenuWindowLevel (101) sits above any normal app window
            # including Finder + Mail, so our overlay stays on top regardless
            # of which app is active.
            ns_win.setLevel_(101)
            # 1=CanJoinAllSpaces  8=Transient (no Mission Control card)
            # 64=IgnoresCycle (no Cmd+Tab entry)  256=FullScreenAuxiliary
            ns_win.setCollectionBehavior_(1 | 8 | 64 | 256)
            # Keep the overlay visible when our Python app deactivates
            # (Finder / Mail take focus). Without this, Qt.Tool windows
            # auto-hide on deactivation and the user has to click the Dock
            # icon to bring it back.
            try:
                ns_win.setHidesOnDeactivate_(False)
            except Exception:
                pass
            ns_win.setOpaque_(False)
            ns_win.setBackgroundColor_(NSColor.clearColor())

            qt_view = ns_win.contentView()  # QNSView — Qt renders here
            # Add the blur view BEHIND Qt's content view (as sibling in frame view)
            # so Qt text renders on top of the vibrancy, not underneath it.
            try:
                frame_view = qt_view.superview()  # NSThemeFrame (window frame)
                if frame_view is None:
                    raise ValueError("no frame_view")
                effect = NSVisualEffectView.alloc().initWithFrame_(qt_view.frame())
                effect.setMaterial_(21)      # UnderWindowBackground — subtle
                effect.setBlendingMode_(0)   # BehindWindow
                effect.setState_(1)          # Active
                effect.setAutoresizingMask_(18)
                # Insert behind Qt's view so Qt text is always on top
                frame_view.addSubview_positioned_relativeTo_(effect, -1, qt_view)
                win._ns_window = ns_win  # type: ignore[attr-defined]
                win._ns_effect = effect  # type: ignore[attr-defined]
                win._vibrancy_active = True  # type: ignore[attr-defined]
                print("[overlay] liquid glass vibrancy active")
            except Exception as ve:
                # Vibrancy positioning failed — fall back to Qt-painted glass
                win._ns_window = ns_win  # type: ignore[attr-defined]
                win._vibrancy_active = False  # type: ignore[attr-defined]
                print(f"[overlay] vibrancy positioning skipped ({ve}) — using solid glass")

        win.setWindowTitle("")
    except Exception as e:
        print(f"[overlay] vibrancy skipped: {e}")


def _open_citation_target(path: str) -> None:
    """Open a cited source when the user clicks its chip.

    * Filesystem paths open with macOS `open <path>` (uses the file's
      default app).
    * `ali://contacts/…` / `ali://calendar/…` / `ali://messages/…` open
      the matching macOS app. We can't easily deep-link to a specific
      contact or event through `open`, so we settle for opening the app
      itself — good enough as a jumping-off point.
    """
    if not path:
        return
    try:
        if path.startswith("ali://"):
            rest = path[len("ali://") :]
            source = rest.split("/", 1)[0]
            app_name = {
                "contacts": "Contacts",
                "calendar": "Calendar",
                "messages": "Messages",
            }.get(source)
            if app_name:
                subprocess.Popen(
                    ["open", "-a", app_name],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            return
        subprocess.Popen(
            ["open", path],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        _dlog(
            "overlay:open_citation",
            "opened cited file",
            {"path": path},
            "H2",
        )
    except Exception as exc:
        _dlog(
            "overlay:open_citation:error",
            "failed to open cited target",
            {"path": path, "err": str(exc)[:200]},
            "H2",
        )


def _paint_citation_chips(
    p: "QPainter",
    *,
    citations: list[dict],
    font: "QFont",
    pad_left: int,
    y: int,
    max_width: int,
) -> list[tuple["QRect", str]]:
    """Draw citation chips in a single row and return their hit rects.

    Each chip renders as an underlined blue label so it reads as a link.
    Returns a list of ``(chip_rect, path)`` pairs — mousePressEvent uses
    this to route clicks to the correct file.
    """
    p.save()
    p.setFont(font)
    fm = p.fontMetrics()
    hit_rects: list[tuple[QRect, str]] = []
    x = pad_left
    chip_h = 20
    chip_y = y + (CITATION_ROW_H - chip_h) // 2
    right_edge = pad_left + max_width
    for entry in citations:
        label = str(entry.get("label") or "").strip() or "(unnamed)"
        path = str(entry.get("path") or "")
        text_w = fm.horizontalAdvance(label)
        chip_w = text_w + CITATION_CHIP_PAD_X * 2
        if x + chip_w > right_edge and hit_rects:
            # No room for another chip on this row — stop (overflow).
            break
        chip_rect = QRect(x, chip_y, chip_w, chip_h)
        # Subtle pill background so the chip reads as tappable.
        bg = QColor(100, 210, 255, 34)
        border = QColor(100, 210, 255, 110)
        path_rect = QPainterPath()
        path_rect.addRoundedRect(chip_rect, chip_h / 2, chip_h / 2)
        p.fillPath(path_rect, bg)
        p.setPen(QPen(border, 1))
        p.drawPath(path_rect)
        # Label (underlined so it's recognisably a link even at a glance).
        link_font = QFont(font)
        link_font.setUnderline(True)
        p.setFont(link_font)
        p.setPen(BLUE if path else DIM)
        p.drawText(
            chip_rect,
            int(Qt.AlignmentFlag.AlignCenter),
            label,
        )
        p.setFont(font)
        if path:
            hit_rects.append((chip_rect, path))
        x += chip_w + CITATION_CHIP_GAP
    p.restore()
    return hit_rects


def _update_vibrancy_mask(win: QWidget) -> None:
    try:
        from Quartz import CGRectMake, CGPathCreateWithRoundedRect  # type: ignore[reportMissingImports]
        from Quartz.QuartzCore import CAShapeLayer  # type: ignore[reportMissingImports]
        effect = getattr(win, "_ns_effect", None)
        if effect is None:
            return
        w, h = win.width(), win.height()
        # Effect view lives in frame_view coords — keep its frame synced with
        # the Qt contentView's frame (they should be identical for frameless windows).
        try:
            ns_win = getattr(win, "_ns_window", None)
            if ns_win is not None:
                qt_frame = ns_win.contentView().frame()
                effect.setFrame_(qt_frame)
        except Exception:
            pass
        bounds = CGRectMake(0, 0, w, h)
        mask = CAShapeLayer.layer()
        path = CGPathCreateWithRoundedRect(bounds, R, R, None)
        mask.setPath_(path)
        effect.setWantsLayer_(True)
        effect.layer().setMask_(mask)
    except Exception:
        pass


class TranscriptionOverlay(QWidget):
    """Thread-safe: wake word calls schedule_wake_prompt() from a background thread."""

    _wake_listen_signal = Signal()

    def __init__(self, app: QApplication) -> None:
        super().__init__()
        self._app = app
        self._q: queue.Queue[tuple[str, str]] = queue.Queue()
        self._history: list[tuple[str, QColor, str]] = []
        # Clickable citation chips + their on-screen hit rectangles.
        # Populated when a `cited_paths` state is pushed; consulted by
        # mousePressEvent to open the underlying file when clicked.
        self._citations: list[dict] = []
        self._citation_hit_rects: list[tuple[QRect, str]] = []
        self._drag_offset: QPoint | None = None
        self._pulse_on = True
        self._recording = False
        self._prompt_armed = False
        self._pill_label = "Listening..."
        self._wake_capture_fn: Callable[[], None] | None = None
        # wake / call state
        self._wake_mode    = False
        self._wake_greeted = False
        self._wake_text    = ""
        self._cam_pixmap   = QPixmap()
        self._cam_bridge   = _CamBridge()
        self._cam_running  = False
        self._cam_bridge.frame_ready.connect(self._on_cam_frame)
        self._cam_bridge.greeted.connect(self._on_wake_greeted)

        # meeting capture state
        self._meeting_mode: bool = False
        self._meeting_transcript: str = ""   # rolling committed words (trimmed)
        self._meeting_interim: str = ""      # current partial phrase
        self._meeting_actions: list[tuple[str, str]] = []  # (task, status)

        self._dock_mode: str = DOCK_TOP

        self._font_label = QFont(".AppleSystemUIFont", 15, QFont.Weight.Bold)
        self._font_body  = QFont(".AppleSystemUIFont", 14)
        self._font_small = QFont(".AppleSystemUIFont", 12)
        self._font_close = QFont(".AppleSystemUIFont", 16, QFont.Weight.Medium)

        # Deliberately NOT using Qt.Tool — on macOS Qt auto-hides Tool
        # windows when the app deactivates, which cannot be overridden from
        # AppKit. Frameless + StaysOnTop + DoesNotAcceptFocus gives us a
        # regular borderless window that stays visible when focus shifts.
        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
        self.setMouseTracking(True)
        self.resize(W_PILL, H_PILL)
        self._reposition(W_PILL, H_PILL)
        # Show briefly so NSApp registers the NSWindow in its windows() list,
        # then immediately hide. _apply_macos_overlay searches that list.
        self.show()
        QApplication.processEvents()
        self.hide()
        _apply_macos_overlay(self)
        _update_vibrancy_mask(self)

        self._poll_timer = QTimer(self)
        self._poll_timer.timeout.connect(self._poll)
        self._poll_timer.start(POLL_MS)

        self._pulse_timer = QTimer(self)
        self._pulse_timer.timeout.connect(self._pulse_tick)

        self._autohide_timer = QTimer(self)
        self._autohide_timer.setSingleShot(True)
        self._autohide_timer.timeout.connect(self.hide)

        self._wake_listen_signal.connect(self._on_wake_sequence)

        self._mac_hotkey_bridge = _MacGlobalHotkeyBridge(self)
        self._mac_hotkey_bridge.backtick.connect(self._on_global_backtick)
        self._mac_hotkey_bridge.right_option_down.connect(self._on_global_right_option_down)
        self._mac_hotkey_bridge.right_option_up.connect(self._on_global_right_option_up)
        self._macos_global_hotkey_monitor = None
        if (
            sys.platform == "darwin"
            and os.environ.get("ALI_ENABLE_HOTKEY") != "1"
            and os.environ.get("ALI_DISABLE_GLOBAL_HOTKEYS") != "1"
        ):
            self._install_macos_global_hotkeys()

    # ── Public ───────────────────────────────────────────────────────────────

    def push(self, state: str, text: str = "") -> None:
        self._q.put((state, text))

    def schedule_wake_prompt(self, start_capture: Callable[[], None]) -> None:
        """
        Conversational wake: show armed pill + pulse, play a listen chime on macOS,
        then invoke start_capture() (typically request_ptt_session_from_wake).
        Safe to call from non-Qt threads.
        """
        self._wake_capture_fn = start_capture
        self._wake_listen_signal.emit()

    @Slot()
    def _on_wake_sequence(self) -> None:
        if self._prompt_armed:
            return  # already armed — ignore duplicate wake trigger
        self._autohide_timer.stop()
        self._wake_mode = False
        self._prompt_armed = True
        self._recording = False
        self._pill_label = "Hi — I'm listening…"
        self._history.clear()
        self._dock_mode = DOCK_TOP
        self._pulse_on = True
        self._set_size(W_PILL, H_PILL)
        self._present()
        self._pulse_timer.start(PULSE_MS)
        self.update()
        QTimer.singleShot(0, self._play_wake_greeting)
        # Start capture almost immediately so wake feels instant.
        QTimer.singleShot(120, self._emit_wake_capture)

    def _play_wake_greeting(self) -> None:
        if sys.platform != "darwin":
            return
        try:
            from voice.speak import _voice
            proc = subprocess.Popen(
                ["/usr/bin/say", "-v", _voice(), "-r", "160", "Hi"],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            try:
                from voice.speak import track_tts_process
                track_tts_process(proc)
            except Exception:
                pass
            # #region agent log
            _dlog("overlay:_play_wake_greeting", "wake greeting launched", {"pid": proc.pid}, "H2")
            # #endregion
        except Exception:
            # #region agent log
            _dlog("overlay:_play_wake_greeting:error", "wake greeting failed", {}, "H2")
            # #endregion

    def _emit_wake_capture(self) -> None:
        fn = self._wake_capture_fn
        self._wake_capture_fn = None
        if fn is not None:
            fn()

    def _install_macos_global_hotkeys(self) -> None:
        """
        Deliver `` ` `` and Right Option without pynput: on macOS, CGEventTap +
        Qt can SIGTRAP, so we use NSEvent.addGlobalMonitorForEventsMatchingMask.
        Requires Accessibility for the host app (Terminal, Cursor, etc.).
        """
        try:
            import AppKit
            from AppKit import NSEvent
        except ImportError:
            print("[overlay] AppKit unavailable — global hotkeys skipped", flush=True)
            return

        emitter = self._mac_hotkey_bridge
        # US/ANSI grave / backtick (kVK_ANSI_Grave); Right Option (kVK_RightOption)
        grave_code = 50
        right_option_code = 61

        def handler(event) -> None:  # type: ignore[no-untyped-def]
            try:
                et = event.type()
                kc = int(event.keyCode())
                if kc == grave_code and et == AppKit.NSEventTypeKeyDown:
                    if event.isARepeat():
                        return
                    emitter.backtick.emit()
                    return
                if kc == right_option_code:
                    if et == AppKit.NSEventTypeKeyDown:
                        emitter.right_option_down.emit()
                    elif et == AppKit.NSEventTypeKeyUp:
                        emitter.right_option_up.emit()
            except Exception:
                pass

        mask = (1 << AppKit.NSEventTypeKeyDown) | (1 << AppKit.NSEventTypeKeyUp)
        monitor = NSEvent.addGlobalMonitorForEventsMatchingMask_handler_(mask, handler)
        if monitor is None:
            print(
                "[overlay][warn] Global ` and Right Option inactive — grant "
                "Accessibility to this app in System Settings → Privacy & Security "
                "(or set ALI_ENABLE_HOTKEY=1 to use pynput; may crash with Qt).",
                flush=True,
            )
        else:
            self._macos_global_hotkey_monitor = monitor
            print(
                "[overlay] Global hotkeys: ` and Right Option (needs Accessibility)",
                flush=True,
            )

    @Slot()
    def _on_global_backtick(self) -> None:
        from voice.capture import invoke_backtick_callback

        invoke_backtick_callback()

    @Slot()
    def _on_global_right_option_down(self) -> None:
        from voice.capture import invoke_right_option_down

        invoke_right_option_down()

    @Slot()
    def _on_global_right_option_up(self) -> None:
        from voice.capture import invoke_right_option_up

        invoke_right_option_up()

    # ── Input ────────────────────────────────────────────────────────────────

    def mousePressEvent(self, e) -> None:  # type: ignore[override]
        if e.button() == Qt.MouseButton.LeftButton:
            x = e.position().x()
            y = e.position().y()
            if self._hit_close(x, y):
                self._do_hide()
                return
            # Citation chip clicks open the underlying file / app.
            for rect, path in self._citation_hit_rects:
                if rect.contains(int(x), int(y)):
                    _open_citation_target(path)
                    return
            self._drag_offset = e.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent_cursor_hint(self, x: float, y: float) -> None:
        """Visual affordance: change cursor to pointing hand over citations."""
        for rect, _ in self._citation_hit_rects:
            if rect.contains(int(x), int(y)):
                self.setCursor(Qt.CursorShape.PointingHandCursor)
                return
        self.setCursor(Qt.CursorShape.ArrowCursor)

    def mouseMoveEvent(self, e) -> None:  # type: ignore[override]
        if self._drag_offset and (e.buttons() & Qt.MouseButton.LeftButton):
            self.move(e.globalPosition().toPoint() - self._drag_offset)
        else:
            self.mouseMoveEvent_cursor_hint(e.position().x(), e.position().y())

    def mouseReleaseEvent(self, e) -> None:  # type: ignore[override]
        if e.button() == Qt.MouseButton.LeftButton:
            self._drag_offset = None

    def resizeEvent(self, e) -> None:  # type: ignore[override]
        super().resizeEvent(e)
        _update_vibrancy_mask(self)

    def _hit_close(self, x: float, y: float) -> bool:
        cx, cy = self.width() - 23, 19
        return (x - cx) ** 2 + (y - cy) ** 2 <= 16 ** 2

    # ── Queue ────────────────────────────────────────────────────────────────

    def _poll(self) -> None:
        try:
            while True:
                state, text = self._q.get_nowait()
                self._apply(state, text)
        except queue.Empty:
            pass

    # ── State ────────────────────────────────────────────────────────────────

    def _on_cam_frame(self, img: QImage) -> None:
        self._cam_pixmap = QPixmap.fromImage(img)
        self.update()

    def _on_wake_greeted(self) -> None:
        self._wake_greeted = True
        self.update()
        # Stay visible until user dismisses (× button or Space + Right Option)

    def _end_wake(self) -> None:
        self._cam_running = False
        self._wake_mode = False
        self._wake_greeted = False
        self._wake_text = ""
        self.hide()

    def _start_camera(self) -> None:
        import time
        self._cam_running = True

        def _prepare_tts(text: str) -> "str | None":
            import os, tempfile
            api_key = os.environ.get("OPENAI_API_KEY", "")
            if api_key:
                try:
                    from openai import OpenAI  # type: ignore[reportMissingImports]
                    client = OpenAI(api_key=api_key)
                    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as f:
                        path = f.name
                    with client.audio.speech.with_streaming_response.create(
                        model="tts-1-hd", voice="nova", input=text, speed=1.0,
                    ) as resp:
                        resp.stream_to_file(path)
                    return path
                except Exception as e:
                    print(f"[tts] OpenAI failed: {e} — falling back to say")
            return None

        def _play_tts(path: "str | None", text: str) -> None:
            import os, subprocess
            if path:
                subprocess.run(["afplay", path], check=True)
                os.unlink(path)
            else:
                subprocess.run(["say", "-v", "Flo (English (US))", "-r", "160", text])

        def _loop() -> None:
            import cv2  # type: ignore[reportMissingImports]
            cascade = cv2.CascadeClassifier(
                cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
            )
            cap = cv2.VideoCapture(0)
            face_first: float | None = None
            greeted = False
            tts_started = False
            greeting = (
                f"{_time_greeting()}, {USER_NAME}. "
                "While you were asleep I've been busy — "
                "I found some great opportunities and took care of a few things. "
                "Let me walk you through them."
            )

            while self._cam_running:
                ok, frame = cap.read()
                if not ok:
                    break
                frame = cv2.flip(frame, 1)
                grey  = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
                faces = cascade.detectMultiScale(grey, 1.1, 5, minSize=(60, 60))

                if len(faces) > 0 and not greeted and not tts_started:
                    if face_first is None:
                        face_first = time.time()
                    if time.time() - face_first >= 1.2:
                        greeted = True
                        tts_started = True
                        def _greet_sync(g=greeting) -> None:
                            # Pre-generate audio first, then show text + play simultaneously
                            audio_path = _prepare_tts(g)
                            self._cam_bridge.greeted.emit()
                            threading.Thread(target=_play_tts, args=(audio_path, g), daemon=True).start()
                        threading.Thread(target=_greet_sync, daemon=True).start()
                elif not greeted and not tts_started:
                    face_first = None

                rgb = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
                fh, fw = rgb.shape[:2]
                img = QImage(rgb.data, fw, fh, fw * 3, QImage.Format.Format_RGB888).copy()
                self._cam_bridge.frame_ready.emit(img)

            cap.release()

        threading.Thread(target=_loop, daemon=True).start()

    def _apply(self, state: str, text: str) -> None:
        self._autohide_timer.stop()
        self._pulse_timer.stop()

        if state == "hidden":
            self._dock_mode = DOCK_TOP
            self._do_hide()
            return

        if state == "wake":
            if self._wake_mode:
                return  # already in wake mode — ignore duplicate trigger
            self._cam_running = False  # stop any lingering camera thread
            self._dock_mode = DOCK_TOP
            self._wake_mode = True
            self._wake_greeted = False
            self._wake_text = ""
            self._reposition(W_WAKE, H_WAKE)
            self.show()
            self.raise_()
            self._reassert_window_level()
            self._start_camera()
            return

        # ── Meeting mode states ──────────────────────────────────────────────
        if state == "meeting_start":
            self._meeting_mode       = True
            self._meeting_transcript = ""
            self._meeting_interim    = ""
            self._meeting_actions    = []
            self._dock_mode          = DOCK_RIGHT
            self._recording          = False
            self._prompt_armed       = False
            h = H_MEETING_BASE
            self._reposition(W_MEETING, h)
            self._present()
            self._pulse_timer.start(PULSE_MS)
            self.update()
            return

        if state == "meeting_interim":
            # Frequent — just update interim text and repaint; don't resize
            self._meeting_interim = text
            self.update()
            return

        if state == "meeting_final":
            # Committed utterance: append to rolling transcript, clear interim
            self._meeting_interim = ""
            combined = (self._meeting_transcript + " " + text).strip()
            # Keep last MAX_TRANSCRIPT_CHARS visible
            if len(combined) > MAX_TRANSCRIPT_CHARS:
                combined = "…" + combined[-MAX_TRANSCRIPT_CHARS:]
            self._meeting_transcript = combined
            self.update()
            return

        if state == "meeting_action":
            self._meeting_actions.append((text, "Queued"))
            self._meeting_actions = self._meeting_actions[-MAX_ACTIONS_SHOWN:]
            n = len(self._meeting_actions)
            h = H_MEETING_BASE + n * H_ACTION_ROW + 12
            self._reposition(W_MEETING, h)
            self.update()
            return

        if state == "meeting_action_update":
            # text = "task_description|status"
            if "|" in text:
                task, status = text.split("|", 1)
                for i, (t, _) in enumerate(self._meeting_actions):
                    if t == task:
                        self._meeting_actions[i] = (t, status)
                        break
            self.update()
            return

        if state == "meeting_stop":
            self._meeting_mode       = False
            self._meeting_transcript = ""
            self._meeting_interim    = ""
            self._meeting_actions    = []
            self._pulse_timer.stop()
            self._do_hide()
            return

        if state == "recording":
            self._dock_mode = DOCK_TOP
            self._history.clear()
            self._prompt_armed = False
            self._recording = True
            self._pill_label = "Listening..."
            self._pulse_on = True
            if not self._wake_mode:
                self._set_size(W_PILL, H_PILL)
            self.show()
            self.raise_()
            self._reassert_window_level()
            self._pulse_timer.start(PULSE_MS)
            self.update()
            return

        self._recording = False
        self._prompt_armed = False

        if state == "transcribing":
            pass  # no-op — don't show "Transcribing…" in history
        elif state == "transcript":
            # New command: reset history and dock back to top-center.
            # Also clear any lingering citations from the previous turn.
            self._history.clear()
            self._citations = []
            self._citation_hit_rects = []
            self._dock_mode = DOCK_TOP
            self._history.append((text, FG, "user"))
        elif state == "intent":
            pass  # skip intent label — action line already conveys this
        elif state == "action":
            self._history.append((text, FG, "assistant"))
            self._dock_mode = DOCK_RIGHT
        elif state == "revealed":
            label = f"Revealed: {text}" if text else "Revealed in Finder"
            self._history.append((label, GREEN, "assistant"))
            self._dock_mode = DOCK_RIGHT
        elif state == "done":
            self._history.append(("✓  Done", GREEN, "assistant"))
            # No autohide — stay visible beside the app until next command
        elif state == "error":
            self._history.append((text or "Error", ERR, "assistant"))
        elif state == "assistant":
            self._history.append((text, FG, "assistant"))
            # No autohide — stay visible until next command or × dismiss
        elif state == "cited_paths":
            # text is a JSON-encoded list of {label, path} dicts. Store them
            # so paintEvent can render clickable chips.
            import json as _json
            try:
                items = _json.loads(text or "[]")
            except _json.JSONDecodeError:
                items = []
            self._citations = [
                {"label": str(i.get("label", "")), "path": str(i.get("path", ""))}
                for i in items
                if isinstance(i, dict) and i.get("path")
            ]
            self._citation_hit_rects = []
        elif state == "cited":
            # Legacy text-only citation — treat as a single chip without
            # a path (not clickable, kept for backward compatibility).
            self._citations = [{"label": text, "path": ""}]
            self._citation_hit_rects = []
        else:
            self._history.append((text, FG, "assistant"))

        self._history = self._history[-MAX_HIST:]
        self._set_size(W_FULL, self._calc_height())
        self._present()
        self.update()

    def _calc_height(self) -> int:
        PAD_TOP = 18
        PAD_BOT = 18
        SEP = 10      # separator under user transcript
        LINE_H = 26   # height per wrapped line of body text
        SMALL_H = 22  # height for user transcript line
        h = PAD_TOP
        for text, _, kind in self._history:
            if kind == "user":
                h += SMALL_H + SEP
            else:
                lines = max(1, (len(text) + 46) // 47)
                h += lines * LINE_H + 6
        if self._citations:
            # Citation chips render in one horizontal row under the body.
            h += CITATION_ROW_H + 6
        h += PAD_BOT
        return min(MAX_H, max(H_PILL, h))

    def _set_size(self, w: int, h: int) -> None:
        self._reposition(w, h)

    def _reposition(self, w: int, h: int) -> None:
        screen = QGuiApplication.screenAt(QCursor.pos()) or QGuiApplication.primaryScreen()
        if screen:
            geo = screen.availableGeometry()
            if self._dock_mode == DOCK_RIGHT:
                x = geo.right() - w - MARGIN_RIGHT
                y = geo.top() + MARGIN   # top-right, same row as pill
            else:
                x = geo.center().x() - w // 2
                y = geo.top() + MARGIN
            self.setGeometry(x, y, w, h)
        else:
            self.resize(w, h)

    # ── Paint ─────────────────────────────────────────────────────────────────

    def paintEvent(self, _event) -> None:  # type: ignore[override]
        p = QPainter(self)
        p.setRenderHints(QPainter.RenderHint.Antialiasing | QPainter.RenderHint.TextAntialiasing)

        w, h = self.width(), self.height()
        vibrancy = getattr(self, "_vibrancy_active", False)

        shell = QPainterPath()
        shell.addRoundedRect(QRect(0, 0, w, h), R, R)

        # ── Wake / call mode — camera feed + greeting ────────────────────────
        if self._wake_mode:
            self._paint_wake(p, w, h, shell)
            return

        # ── Meeting capture mode ──────────────────────────────────────────────
        if self._meeting_mode:
            self._paint_glass_body(p, shell, w, h, vibrancy)
            self._paint_meeting(p, w, h)
            return

        # ── 1. Soft drop shadow (two offset layers for bloom) ─────────────────
        for offset, alpha in ((4, 14), (2, 8)):
            s = QPainterPath()
            s.addRoundedRect(QRect(offset // 2, offset, w - offset, h), R, R)
            p.fillPath(s, QColor(0, 0, 0, alpha))

        # ── 2. Glass body — translucent liquid tint ────────────────────────────
        if vibrancy:
            p.fillPath(shell, QColor(18, 18, 22, 145))  # semi-opaque so text pops over blur
        else:
            p.fillPath(shell, QColor(34, 38, 48, 200))  # solid fallback

        # ── 3. Border — soft glass edge ───────────────────────────────────────
        border = QLinearGradient(0, 0, 0, h)
        border.setColorAt(0.0, QColor(255, 255, 255, 68))
        border.setColorAt(0.5, QColor(210, 220, 240, 44))
        border.setColorAt(1.0, QColor(156, 168, 188, 30))
        p.setPen(QPen(QBrush(border), 1.2))
        p.drawPath(shell)

        # ── 4. Inner contour — slight edge depth with low opacity ─────────────
        inner = QPainterPath()
        inner.addRoundedRect(QRect(1, 1, w - 2, h - 2), R - 1, R - 1)
        inner_hi = QLinearGradient(0, 1, 0, h)
        inner_hi.setColorAt(0.0, QColor(255, 255, 255, 38))
        inner_hi.setColorAt(1.0, QColor(110, 122, 146, 24))
        p.setPen(QPen(QBrush(inner_hi), 0.8))
        p.drawPath(inner)

        # ── 5. Content ────────────────────────────────────────────────────────
        if self._recording or self._prompt_armed:
            self._paint_pill(p)
        else:
            self._paint_expanded(p)

    def _paint_pill(self, p: QPainter) -> None:
        w, h = self.width(), self.height()
        cy = h // 2

        # Blinking dot
        p.setPen(Qt.PenStyle.NoPen)
        dot = RED if self._pulse_on else QColor(200, 80, 76, 80)
        p.setBrush(dot)
        p.drawEllipse(QPoint(26, cy), 8, 8)

        # Mic icon
        self._draw_mic(p, 52, cy)

        # Label
        p.setPen(FG)
        p.setFont(self._font_label)
        p.drawText(
            QRect(74, cy - 12, w - 90, 24),
            Qt.AlignmentFlag.AlignVCenter,
            self._pill_label,
        )

    def _paint_glass_body(
        self, p: QPainter, shell: QPainterPath, w: int, h: int, vibrancy: bool
    ) -> None:
        """Shared glass background used by meeting mode (and the normal pill path)."""
        for offset, alpha in ((4, 14), (2, 8)):
            s = QPainterPath()
            s.addRoundedRect(QRect(offset // 2, offset, w - offset, h), R, R)
            p.fillPath(s, QColor(0, 0, 0, alpha))
        if vibrancy:
            p.fillPath(shell, QColor(18, 18, 22, 145))
        else:
            p.fillPath(shell, QColor(34, 38, 48, 200))
        border = QLinearGradient(0, 0, 0, h)
        border.setColorAt(0.0, QColor(255, 255, 255, 68))
        border.setColorAt(0.5, QColor(210, 220, 240, 44))
        border.setColorAt(1.0, QColor(156, 168, 188, 30))
        p.setPen(QPen(QBrush(border), 1.2))
        p.drawPath(shell)

    def _paint_meeting(self, p: QPainter, w: int, h: int) -> None:
        """Meeting capture overlay: live transcript + action items queue."""
        pad = 14

        # ── Header ────────────────────────────────────────────────────────────
        dot_col = RED if self._pulse_on else QColor(200, 80, 76, 80)
        p.setPen(Qt.PenStyle.NoPen)
        p.setBrush(dot_col)
        p.drawEllipse(QPoint(pad + 6, 22), 6, 6)

        p.setPen(FG)
        p.setFont(self._font_label)
        p.drawText(QRect(pad + 20, 10, w - 90, 24), Qt.AlignmentFlag.AlignVCenter,
                   "Meeting Capture")

        p.setPen(DIM)
        p.setFont(self._font_small)
        p.drawText(QRect(w - 60, 10, 50, 24), Qt.AlignmentFlag.AlignRight | Qt.AlignmentFlag.AlignVCenter,
                   "say stop")

        # Divider
        p.setPen(QPen(QColor(255, 255, 255, 30), 1))
        p.drawLine(QPoint(pad, 38), QPoint(w - pad, 38))

        # ── Transcript area ───────────────────────────────────────────────────
        tx_y   = 46
        tx_h   = 110
        tx_w   = w - pad * 2

        # Committed transcript (dim)
        p.setPen(DIM)
        p.setFont(self._font_small)
        _flags = int(Qt.TextFlag.TextWordWrap) | int(Qt.AlignmentFlag.AlignLeft) | int(Qt.AlignmentFlag.AlignBottom)
        p.drawText(QRect(pad, tx_y, tx_w, tx_h - 22), _flags,
                   self._meeting_transcript or "Listening to meeting…")

        # Interim text (live, brighter) — pulsing
        if self._meeting_interim:
            interim_alpha = 220 if self._pulse_on else 160
            p.setPen(QColor(246, 246, 250, interim_alpha))
            p.setFont(self._font_body)
            p.drawText(QRect(pad, tx_y + tx_h - 26, tx_w, 22),
                       int(Qt.AlignmentFlag.AlignLeft) | int(Qt.AlignmentFlag.AlignVCenter),
                       self._meeting_interim)
        else:
            # Blinking cursor to signal active listening
            if self._pulse_on:
                p.setPen(QColor(100, 210, 255, 180))
                p.setFont(self._font_body)
                p.drawText(QRect(pad, tx_y + tx_h - 26, 20, 22),
                           Qt.AlignmentFlag.AlignLeft, "▌")

        if not self._meeting_actions:
            return

        # Divider before actions
        sep_y = tx_y + tx_h + 4
        p.setPen(QPen(QColor(255, 255, 255, 30), 1))
        p.drawLine(QPoint(pad, sep_y), QPoint(w - pad, sep_y))

        p.setPen(DIM)
        p.setFont(self._font_small)
        p.drawText(QRect(pad, sep_y + 4, 120, 18), Qt.AlignmentFlag.AlignLeft, "Action Items")

        # ── Action items ──────────────────────────────────────────────────────
        STATUS_COLOR = {
            "Queued":  QColor(196, 194, 202),
            "Running": BLUE,
            "done":    GREEN,
            "error":   ERR,
        }
        STATUS_LABEL = {
            "Queued":  "Queued",
            "Running": "Running…",
            "done":    "✓ Done",
            "error":   "✗ Error",
        }

        ay = sep_y + 26
        for task, status in self._meeting_actions:
            sc    = STATUS_COLOR.get(status, DIM)
            label = STATUS_LABEL.get(status, status)

            # Subtle row background
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255, 255, 255, 12))
            p.drawRoundedRect(pad, ay, w - pad * 2, H_ACTION_ROW - 4, 8, 8)

            p.setPen(FG)
            p.setFont(self._font_small)
            p.drawText(QRect(pad + 10, ay + 2, w - 130, H_ACTION_ROW - 6),
                       int(Qt.AlignmentFlag.AlignLeft) | int(Qt.AlignmentFlag.AlignVCenter),
                       task)

            p.setPen(sc)
            p.drawText(QRect(w - 110, ay + 2, 96, H_ACTION_ROW - 6),
                       int(Qt.AlignmentFlag.AlignRight) | int(Qt.AlignmentFlag.AlignVCenter),
                       label)

            ay += H_ACTION_ROW

    def _paint_wake(self, p: QPainter, w: int, h: int, shell: QPainterPath) -> None:
        # Low alpha — let desktop vibrancy bleed through the whole panel
        p.fillPath(shell, QColor(18, 18, 22, 60))
        border = QLinearGradient(0, 0, 0, h)
        border.setColorAt(0, QColor(255, 255, 255, 70))
        border.setColorAt(1, QColor(255, 255, 255, 20))
        p.setPen(QPen(QBrush(border), 1.2))
        p.drawPath(shell)

        pad = 16
        cam_x, cam_y = pad, (h - CAM_H) // 2

        # Camera feed (rounded)
        if not self._cam_pixmap.isNull():
            cam_path = QPainterPath()
            cam_path.addRoundedRect(QRect(cam_x, cam_y, CAM_W, CAM_H), 14, 14)
            p.setClipPath(cam_path)
            scaled = self._cam_pixmap.scaled(
                CAM_W, CAM_H,
                Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                Qt.TransformationMode.SmoothTransformation,
            )
            ox = (scaled.width()  - CAM_W) // 2
            oy = (scaled.height() - CAM_H) // 2
            p.drawPixmap(cam_x - ox, cam_y - oy, scaled)
            p.setClipping(False)
            p.setPen(QPen(QColor(255, 255, 255, 50), 1))
            p.drawPath(cam_path)
        else:
            p.fillRect(QRect(cam_x, cam_y, CAM_W, CAM_H), QColor(40, 40, 44))

        # Recording indicator (top-right corner when listening)
        if self._recording:
            dot_color = RED if self._pulse_on else QColor(200, 80, 76, 80)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(dot_color)
            p.drawEllipse(QPoint(w - 20, 16), 6, 6)
            p.setPen(DIM)
            p.setFont(self._font_small)
            p.drawText(QRect(w - 110, 8, 82, 16), Qt.AlignmentFlag.AlignRight, "Listening…")

        # Text area (right of camera)
        tx = cam_x + CAM_W + pad
        tw = w - tx - pad

        if not self._wake_greeted:
            p.setPen(DIM)
            p.setFont(self._font_small)
            p.drawText(QRect(tx, cam_y + 10, tw, 30), Qt.AlignmentFlag.AlignLeft, "Ali is watching...")
            # progress dots
            p.setPen(FG)
            p.setFont(self._font_body)
            p.drawText(QRect(tx, cam_y + 50, tw, 30), Qt.AlignmentFlag.AlignLeft, "Detecting face...")
        else:
            p.setPen(GREEN)
            p.setFont(self._font_label)
            p.drawText(QRect(tx, cam_y + 8, tw, 28), Qt.AlignmentFlag.AlignLeft,
                       f"{_time_greeting()}, {USER_NAME}!")
            p.setPen(FG)
            p.setFont(self._font_small)
            p.drawText(
                QRect(tx, cam_y + 44, tw, CAM_H - 50),
                int(Qt.TextFlag.TextWordWrap),
                "While you were asleep I've been busy — I found great opportunities and took care of things.",
            )

    def _draw_mic(self, p: QPainter, cx: int, cy: int) -> None:
        pen = QPen(DIM, 1.8)
        pen.setCapStyle(Qt.PenCapStyle.RoundCap)
        p.setPen(pen)
        p.setBrush(Qt.BrushStyle.NoBrush)
        body = QPainterPath()
        body.addRoundedRect(cx - 5, cy - 10, 10, 14, 5, 5)
        p.drawPath(body)
        p.drawArc(QRect(cx - 8, cy + 2, 16, 9), 180 * 16, -180 * 16)
        p.drawLine(QPoint(cx, cy + 11), QPoint(cx, cy + 15))
        p.drawLine(QPoint(cx - 5, cy + 15), QPoint(cx + 5, cy + 15))

    def _paint_expanded(self, p: QPainter) -> None:
        w, h = self.width(), self.height()
        pad = 22

        # Subtle × button
        p.setPen(QColor(180, 178, 195, 100))
        p.setFont(self._font_close)
        p.drawText(QRect(w - 34, 8, 22, 22), Qt.AlignmentFlag.AlignCenter, "×")

        if not self._history:
            return

        y = 18

        for text, colour, kind in self._history:
            if kind == "user":
                # Command: small, muted — one line, italic
                p.setPen(QColor(168, 165, 180))
                p.setFont(self._font_small)
                # Trim quotes, truncate to fit one line
                display = text.strip('"').strip("'")
                if len(display) > 58:
                    display = display[:55] + "…"
                p.drawText(
                    QRect(pad, y, w - pad * 2 - 30, 22),
                    int(Qt.AlignmentFlag.AlignLeft) | int(Qt.AlignmentFlag.AlignVCenter),
                    display,
                )
                y += 22
                # Hairline separator
                p.setPen(QPen(QColor(255, 255, 255, 22), 0.8))
                p.drawLine(QPoint(pad, y + 4), QPoint(w - pad, y + 4))
                y += 14
            else:
                # Response / status — larger, colour-coded
                lines = max(1, (len(text) + 46) // 47)
                th = lines * 26
                p.setPen(colour)
                p.setFont(self._font_body)
                _flags = int(Qt.TextFlag.TextWordWrap) | int(Qt.AlignmentFlag.AlignLeft)
                p.drawText(QRect(pad, y, w - pad * 2, th), _flags, text)
                y += th + 6

        # Clickable citation chips — painted as pill-shaped links after the
        # main body; each chip's on-screen rect is stashed for hit-testing
        # in mousePressEvent.
        if self._citations:
            self._citation_hit_rects = _paint_citation_chips(
                p,
                citations=self._citations,
                font=self._font_small,
                pad_left=pad,
                y=y,
                max_width=w - pad * 2,
            )
            y += CITATION_ROW_H + 6
        else:
            self._citation_hit_rects = []

    # ── Timers ────────────────────────────────────────────────────────────────

    def _pulse_tick(self) -> None:
        if self.isVisible():
            self._pulse_on = not self._pulse_on
            self.update()

    def _do_hide(self) -> None:
        self._pulse_timer.stop()
        self._autohide_timer.stop()
        self._recording = False
        self._prompt_armed = False
        self._wake_capture_fn = None
        self.hide()

    def _present(self) -> None:
        """
        Show overlay above the current app/space without activating a new space.
        """
        self.show()
        self.raise_()
        self._reassert_window_level()

    def _reassert_window_level(self) -> None:
        """
        Re-apply NSWindow level / collection / hides-on-deactivate every
        time we show. Qt can reset these after a resize or re-parent.
        """
        try:
            ns_win = getattr(self, "_ns_window", None)
            if ns_win is None:
                return
            ns_win.setLevel_(101)  # NSPopUpMenuWindowLevel
            ns_win.setCollectionBehavior_(1 | 8 | 64 | 256)
            try:
                ns_win.setHidesOnDeactivate_(False)
            except Exception:
                pass
            ns_win.orderFrontRegardless()
        except Exception:
            pass

    def closeEvent(self, _event) -> None:  # type: ignore[override]
        self._cam_running = False  # signal camera thread to stop before Qt tears down
