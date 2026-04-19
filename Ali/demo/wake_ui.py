"""
Demo Step 1 — Wake UI
Video-call style Qt window: shows live camera feed, detects face,
greets the user by name with a time-appropriate message.
Press backtick ` to launch from main.py.
"""

from __future__ import annotations

import datetime
import threading
import time
from typing import Callable

import cv2  # type: ignore[reportMissingImports]
import pyttsx3  # type: ignore[reportMissingImports]

from PySide6.QtCore import QPoint, QRect, Qt, QTimer, Signal, QObject  # type: ignore[reportMissingImports]
from PySide6.QtGui import (  # type: ignore[reportMissingImports]
    QBrush, QColor, QFont, QImage, QLinearGradient,
    QPainter, QPainterPath, QPen, QPixmap,
)
from PySide6.QtWidgets import QApplication, QLabel, QWidget  # type: ignore[reportMissingImports]

USER_NAME       = "Alspencer"
FACE_HOLD_SEC   = 1.2
CASCADE         = cv2.CascadeClassifier(
    cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
)

W, H    = 480, 360
RADIUS  = 24
CAM_W   = W - 32
CAM_H   = H - 120


def _greeting() -> str:
    hour = datetime.datetime.now().hour
    if hour < 12:
        tod = "Good morning"
    elif hour < 17:
        tod = "Good afternoon"
    else:
        tod = "Good evening"
    return (
        f"{tod}, {USER_NAME}. "
        "While you were asleep I've been busy — "
        "I found some great opportunities and took care of a few things. "
        "Let me walk you through them."
    )


def _speak_async(text: str) -> None:
    def _go():
        engine = pyttsx3.init()
        engine.setProperty("rate", 165)
        for v in engine.getProperty("voices"):
            if "samantha" in v.name.lower() or "alex" in v.name.lower():
                engine.setProperty("voice", v.id)
                break
        engine.say(text)
        engine.runAndWait()
    threading.Thread(target=_go, daemon=True).start()


# ── Signal bridge (camera thread → Qt main thread) ───────────────────────────

class _Bridge(QObject):
    frame_ready  = Signal(QImage)
    face_greeted = Signal(str)


class WakeWindow(QWidget):
    def __init__(self, on_wake: Callable[[], None] | None = None) -> None:
        super().__init__()
        self._on_wake   = on_wake
        self._bridge    = _Bridge()
        self._greeted   = False
        self._greeting  = ""
        self._pixmap    = QPixmap()
        self._face_rect: tuple[int,int,int,int] | None = None
        self._progress  = 0.0   # 0‥1 hold progress

        self._font_name = QFont(".AppleSystemUIFont", 18, QFont.Weight.Bold)
        self._font_sub  = QFont(".AppleSystemUIFont", 13)
        self._font_greet= QFont(".AppleSystemUIFont", 14)

        self.setWindowFlags(
            Qt.WindowType.FramelessWindowHint
            | Qt.WindowType.WindowStaysOnTopHint
            | Qt.WindowType.Tool
        )
        self.setAttribute(Qt.WidgetAttribute.WA_TranslucentBackground, True)
        self.resize(W, H)
        self._center()

        self._bridge.frame_ready.connect(self._on_frame)
        self._bridge.face_greeted.connect(self._on_greeted)

        # Start camera capture thread
        self._running = True
        threading.Thread(target=self._capture_loop, daemon=True).start()

        self.show()
        self.raise_()

    def _center(self) -> None:
        from PySide6.QtGui import QGuiApplication  # type: ignore[reportMissingImports]
        screen = QGuiApplication.primaryScreen()
        if screen:
            geo = screen.availableGeometry()
            self.move(geo.center().x() - W // 2, geo.top() + 60)

    # ── Camera thread ─────────────────────────────────────────────────────────

    def _capture_loop(self) -> None:
        cap = cv2.VideoCapture(0)
        if not cap.isOpened():
            print("[wake] Camera unavailable")
            return

        face_first: float | None = None

        while self._running:
            ok, frame = cap.read()
            if not ok:
                break

            frame = cv2.flip(frame, 1)   # mirror
            grey  = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            faces = CASCADE.detectMultiScale(
                grey, scaleFactor=1.1, minNeighbors=5, minSize=(70, 70)
            )

            if len(faces) > 0 and not self._greeted:
                x, y, w, h = faces[0]
                self._face_rect = (x, y, w, h)
                if face_first is None:
                    face_first = time.time()
                self._progress = min(1.0, (time.time() - face_first) / FACE_HOLD_SEC)
                if self._progress >= 1.0:
                    greeting = _greeting()
                    self._greeted = True
                    _speak_async(greeting)
                    self._bridge.face_greeted.emit(greeting)
            else:
                if not self._greeted:
                    face_first = None
                    self._progress = 0.0
                    self._face_rect = None

            # Convert BGR → RGB → QImage
            rgb   = cv2.cvtColor(frame, cv2.COLOR_BGR2RGB)
            h, w  = rgb.shape[:2]
            img   = QImage(rgb.data, w, h, w * 3, QImage.Format.Format_RGB888).copy()
            self._bridge.frame_ready.emit(img)

        cap.release()

    def _on_frame(self, img: QImage) -> None:
        self._pixmap = QPixmap.fromImage(img)
        self.update()

    def _on_greeted(self, text: str) -> None:
        self._greeting = text
        self.update()
        # Close window after 6 s and fire callback
        QTimer.singleShot(6000, self._finish)

    def _finish(self) -> None:
        self._running = False
        self.close()
        if self._on_wake:
            self._on_wake()

    # ── Paint ─────────────────────────────────────────────────────────────────

    def paintEvent(self, _event) -> None:  # type: ignore[override]
        p = QPainter(self)
        p.setRenderHints(
            QPainter.RenderHint.Antialiasing |
            QPainter.RenderHint.SmoothPixmapTransform
        )

        shell = QPainterPath()
        shell.addRoundedRect(QRect(0, 0, W, H), RADIUS, RADIUS)
        p.setClipPath(shell)

        # ── Camera feed ───────────────────────────────────────────────────────
        if not self._pixmap.isNull():
            scaled = self._pixmap.scaled(
                W, H,
                Qt.AspectRatioMode.KeepAspectRatioByExpanding,
                Qt.TransformationMode.SmoothTransformation,
            )
            x_off = (scaled.width()  - W) // 2
            y_off = (scaled.height() - H) // 2
            p.drawPixmap(-x_off, -y_off, scaled)
        else:
            p.fillPath(shell, QColor(20, 20, 24))

        # ── Dark gradient overlay (bottom) ────────────────────────────────────
        grad = QLinearGradient(0, H // 2, 0, H)
        grad.setColorAt(0.0, QColor(0, 0, 0, 0))
        grad.setColorAt(1.0, QColor(0, 0, 0, 200))
        p.fillPath(shell, grad)

        p.setClipping(False)

        # ── Face hold progress bar ────────────────────────────────────────────
        if self._progress > 0 and not self._greeted:
            bar_w = int(W * self._progress)
            p.setPen(Qt.PenStyle.NoPen)
            p.setBrush(QColor(80, 220, 120, 180))
            p.drawRoundedRect(QRect(0, H - 5, bar_w, 5), 2, 2)

        # ── Name plate (bottom left) ──────────────────────────────────────────
        p.setPen(QColor(255, 255, 255))
        p.setFont(self._font_name)
        p.drawText(QRect(20, H - 72, W - 40, 28),
                   Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                   USER_NAME)

        p.setPen(QColor(180, 220, 180))
        p.setFont(self._font_sub)
        status = "Ali is watching..." if not self._greeted else "✓  Greeted"
        p.drawText(QRect(20, H - 46, W - 40, 22),
                   Qt.AlignmentFlag.AlignLeft | Qt.AlignmentFlag.AlignVCenter,
                   status)

        # ── Greeting text (centre, after detection) ───────────────────────────
        if self._greeting:
            p.setPen(QColor(255, 255, 255, 220))
            p.setFont(self._font_greet)
            p.drawText(
                QRect(20, 20, W - 40, H - 100),
                Qt.TextFlag.TextWordWrap | Qt.AlignmentFlag.AlignTop,
                self._greeting,
            )

        # ── Glass border ──────────────────────────────────────────────────────
        border = QLinearGradient(0, 0, 0, H)
        border.setColorAt(0.0, QColor(255, 255, 255, 80))
        border.setColorAt(1.0, QColor(255, 255, 255, 20))
        p.setPen(QPen(QBrush(border), 1.5))
        p.drawPath(shell)

    # ── Drag to move ──────────────────────────────────────────────────────────

    def mousePressEvent(self, e) -> None:  # type: ignore[override]
        if e.button() == Qt.MouseButton.LeftButton:
            self._drag = e.globalPosition().toPoint() - self.frameGeometry().topLeft()

    def mouseMoveEvent(self, e) -> None:  # type: ignore[override]
        if hasattr(self, "_drag") and (e.buttons() & Qt.MouseButton.LeftButton):
            self.move(e.globalPosition().toPoint() - self._drag)

    def mouseReleaseEvent(self, e) -> None:  # type: ignore[override]
        if e.button() == Qt.MouseButton.LeftButton:
            self._drag = QPoint()

    def closeEvent(self, e) -> None:  # type: ignore[override]
        self._running = False
        super().closeEvent(e)
