"""
Liquid glass overlay — Apple-style frosted pill, top-center, expands downward.
"""

from __future__ import annotations

import datetime
import queue
import threading

import cv2  # type: ignore[reportMissingImports]

from PySide6.QtCore import QPoint, QRect, Qt, QTimer, Signal, QObject  # pyright: ignore[reportMissingImports]
from PySide6.QtGui import (  # pyright: ignore[reportMissingImports]
    QBrush, QColor, QFont, QGuiApplication, QImage, QLinearGradient,
    QPainter, QPainterPath, QPen, QPixmap,
)
from PySide6.QtWidgets import QApplication, QWidget  # pyright: ignore[reportMissingImports]

_CASCADE = cv2.CascadeClassifier(
    cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
)

W_WAKE  = 560
H_WAKE  = 200
CAM_W   = 160
CAM_H   = 160
USER_NAME = "Alspencer"


def _time_greeting() -> str:
    h = datetime.datetime.now().hour
    if h < 12:   return "Good morning"
    if h < 17:   return "Good afternoon"
    return "Good evening"


class _CamBridge(QObject):
    frame_ready = Signal(QImage)
    greeted     = Signal()

# ── Colors ────────────────────────────────────────────────────────────────────
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
MAX_H   = 540
MAX_HIST = 6

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
            ns_win.setLevel_(25)
            # 1=CanJoinAllSpaces 16=IgnoresCycle 256=FullScreenAuxiliary
            ns_win.setCollectionBehavior_(1 | 16 | 256)
            ns_win.setOpaque_(False)
            ns_win.setBackgroundColor_(NSColor.clearColor())

            content = ns_win.contentView()
            effect = NSVisualEffectView.alloc().initWithFrame_(content.bounds())
            effect.setMaterial_(21)      # UnderWindowBackground — most transparent
            effect.setBlendingMode_(0)   # BehindWindow
            effect.setState_(1)          # Active
            effect.setAutoresizingMask_(18)
            # No forced appearance — inherit system so blur stays subtle
            content.addSubview_positioned_relativeTo_(effect, 0, None)
            win._ns_window = ns_win  # type: ignore[attr-defined]
            win._ns_effect = effect  # type: ignore[attr-defined]
            win._vibrancy_active = True  # type: ignore[attr-defined]
            print("[overlay] liquid glass vibrancy active")

        win.setWindowTitle("")
    except Exception as e:
        print(f"[overlay] vibrancy skipped: {e}")


def _update_vibrancy_mask(win: QWidget) -> None:
    try:
        from Quartz import CGRectMake, CGPathCreateWithRoundedRect  # type: ignore[reportMissingImports]
        from Quartz.QuartzCore import CAShapeLayer  # type: ignore[reportMissingImports]
        effect = getattr(win, "_ns_effect", None)
        if effect is None:
            return
        w, h = win.width(), win.height()
        bounds = CGRectMake(0, 0, w, h)
        effect.setFrame_(bounds)
        mask = CAShapeLayer.layer()
        path = CGPathCreateWithRoundedRect(bounds, R, R, None)
        mask.setPath_(path)
        effect.setWantsLayer_(True)
        effect.layer().setMask_(mask)
    except Exception:
        pass


class TranscriptionOverlay(QWidget):
    def __init__(self, app: QApplication) -> None:
        super().__init__()
        self._app = app
        self._q: queue.Queue[tuple[str, str]] = queue.Queue()
        self._history: list[tuple[str, QColor, str]] = []
        self._drag_offset: QPoint | None = None
        self._pulse_on = True
        self._recording = False
        # wake / call state
        self._wake_mode   = False
        self._wake_greeted = False
        self._wake_text   = ""
        self._cam_pixmap  = QPixmap()
        self._cam_bridge  = _CamBridge()
        self._cam_running = False
        self._cam_bridge.frame_ready.connect(self._on_cam_frame)
        self._cam_bridge.greeted.connect(self._on_wake_greeted)

        self._font_label = QFont(".AppleSystemUIFont", 15, QFont.Weight.Bold)
        self._font_body  = QFont(".AppleSystemUIFont", 14)
        self._font_small = QFont(".AppleSystemUIFont", 12)
        self._font_close = QFont(".AppleSystemUIFont", 16, QFont.Weight.Medium)

        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.Tool
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.WindowDoesNotAcceptFocus
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.setAttribute(Qt.WidgetAttribute.WA_ShowWithoutActivating, True)
        self.setMouseTracking(True)
        self.resize(W_PILL, H_PILL)
        self._reposition(W_PILL, H_PILL)
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

    # ── Public ───────────────────────────────────────────────────────────────

    def push(self, state: str, text: str = "") -> None:
        self._q.put((state, text))

    # ── Input ────────────────────────────────────────────────────────────────

    def mousePressEvent(self, e) -> None:  # type: ignore[override]
        if e.button() == Qt.MouseButton.LeftButton:
            if self._hit_close(e.position().x(), e.position().y()):
                self._do_hide()
            else:
                self._drag_offset = e.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, e) -> None:  # type: ignore[override]
        if self._drag_offset and (e.buttons() & Qt.MouseButton.LeftButton):
            self.move(e.globalPosition().toPoint() - self._drag_offset)

    def mouseReleaseEvent(self, e) -> None:  # type: ignore[override]
        if e.button() == Qt.MouseButton.LeftButton:
            self._drag_offset = None

    def resizeEvent(self, e) -> None:  # type: ignore[override]
        super().resizeEvent(e)
        _update_vibrancy_mask(self)

    def _hit_close(self, x: float, y: float) -> bool:
        cx, cy = self.width() - 24, 24
        return (x - cx) ** 2 + (y - cy) ** 2 <= 14 ** 2

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
                faces = _CASCADE.detectMultiScale(grey, 1.1, 5, minSize=(60, 60))

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
            self._do_hide()
            return

        if state == "wake":
            self._wake_mode = True
            self._wake_greeted = False
            self._wake_text = ""
            self._reposition(W_WAKE, H_WAKE)
            self.show()
            self.raise_()
            self._start_camera()
            return

        if state == "recording":
            self._history.clear()
            self._recording = True
            self._pulse_on = True
            if not self._wake_mode:
                self._set_size(W_PILL, H_PILL)
            self.show()
            self.raise_()
            self._pulse_timer.start(PULSE_MS)
            self.update()
            return

        self._recording = False

        if state == "transcribing":
            self._history.append(("Transcribing...", YELLOW, "status"))
        elif state == "transcript":
            self._history.append((text, FG, "user"))
        elif state == "intent":
            self._history.append((text, BLUE, "status"))
        elif state == "action":
            self._history.append((text, GREEN, "assistant"))
        elif state == "done":
            self._history.append(("✓  Done", GREEN, "assistant"))
            self._autohide_timer.start(AUTOHIDE_MS)
        elif state == "error":
            self._history.append((text or "Error", ERR, "status"))
            self._autohide_timer.start(AUTOHIDE_MS)
        else:
            self._history.append((text, FG, "assistant"))

        self._history = self._history[-MAX_HIST:]
        self._set_size(W_FULL, self._calc_height())
        self._present()
        self.update()

    def _calc_height(self) -> int:
        h = 20
        for text, _, kind in self._history:
            lines = max(1, (len(text) + 48) // 49)
            h += (lines * 22 + 24) if kind != "status" else 40
        return min(MAX_H, max(H_PILL, h + 20))

    def _set_size(self, w: int, h: int) -> None:
        self._reposition(w, h)

    def _reposition(self, w: int, h: int) -> None:
        screen = QGuiApplication.primaryScreen()
        if screen:
            geo = screen.availableGeometry()
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

        # ── 1. Soft drop shadow (two offset layers for bloom) ─────────────────
        for offset, alpha in ((4, 14), (2, 8)):
            s = QPainterPath()
            s.addRoundedRect(QRect(offset // 2, offset, w - offset, h), R, R)
            p.fillPath(s, QColor(0, 0, 0, alpha))

        # ── 2. Glass body — translucent liquid tint ────────────────────────────
        if vibrancy:
            p.fillPath(shell, QColor(255, 255, 255, 18))
        else:
            p.fillPath(shell, QColor(34, 38, 48, 118))  # translucent fallback

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
        if self._recording:
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
            "Listening...",
        )

    def _paint_wake(self, p: QPainter, w: int, h: int, shell: QPainterPath) -> None:
        # Glass background
        p.fillPath(shell, QColor(18, 18, 22, 210))
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
                Qt.TextFlag.TextWordWrap,
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
        w = self.width()

        # Close ×
        p.setPen(DIM)
        p.setFont(self._font_close)
        p.drawText(QRect(w - 36, 8, 22, 22), Qt.AlignmentFlag.AlignCenter, "×")

        y = 14
        for text, colour, kind in self._history:
            lines = max(1, (len(text) + 48) // 49)
            bh = lines * 22 + 20 if kind != "status" else 38

            bx, bw = 12, w - 24
            bub_alpha = 16 if kind == "user" else 10 if kind == "assistant" else 8
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(255, 255, 255, bub_alpha))
            p.drawRoundedRect(bx, y, bw, bh, 12, 12)

            p.setPen(colour)
            p.setFont(self._font_body if kind != "status" else self._font_small)
            p.drawText(
                QRect(bx + 14, y + 8, bw - 24, bh - 12),
                Qt.TextFlag.TextWordWrap | Qt.AlignmentFlag.AlignVCenter,
                text,
            )
            y += bh + 8

    # ── Timers ────────────────────────────────────────────────────────────────

    def _pulse_tick(self) -> None:
        if self.isVisible():
            self._pulse_on = not self._pulse_on
            self.update()

    def _do_hide(self) -> None:
        self._pulse_timer.stop()
        self._autohide_timer.stop()
        self._recording = False
        self.hide()

    def _present(self) -> None:
        """
        Show overlay above the current app/space without activating a new space.
        """
        self.show()
        try:
            ns_win = getattr(self, "_ns_window", None)
            if ns_win is not None:
                ns_win.orderFrontRegardless()
        except Exception:
            pass
