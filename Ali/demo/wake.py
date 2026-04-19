"""
Demo Step 1 — Wake Detection
Press F8 (or run directly) to open the camera.
When Ali sees a face she greets Alspencer by name via TTS,
then calls the optional on_wake() callback so the rest of the
demo can chain from here.
"""

from __future__ import annotations

import threading
import time
from typing import Callable

import cv2  # type: ignore[reportMissingImports]
import pyttsx3  # type: ignore[reportMissingImports]

USER_NAME = "Alspencer"

# How long (seconds) a face must be visible before triggering
FACE_HOLD_SECONDS = 1.2

# OpenCV's built-in face detector — no model download needed
_CASCADE = cv2.CascadeClassifier(
    cv2.data.haarcascades + "haarcascade_frontalface_default.xml"
)


def _speak(text: str) -> None:
    """Blocking TTS on a background thread so it doesn't stall the camera loop."""
    engine = pyttsx3.init()
    # Slightly slower, warmer rate
    engine.setProperty("rate", 165)
    # Pick the best available voice (prefer Siri/Alex on macOS)
    voices = engine.getProperty("voices")
    for v in voices:
        if "samantha" in v.name.lower() or "alex" in v.name.lower():
            engine.setProperty("voice", v.id)
            break
    engine.say(text)
    engine.runAndWait()


def _speak_async(text: str) -> None:
    threading.Thread(target=_speak, args=(text,), daemon=True).start()


def run_wake(on_wake: Callable[[], None] | None = None) -> None:
    """
    Open the camera, wait for a face, greet the user, fire on_wake().
    Blocks until the greeting fires or the user presses Q to quit.
    """
    cap = cv2.VideoCapture(0)
    if not cap.isOpened():
        print("[wake] Could not open camera")
        return

    print("[wake] Camera open — watching for a face...")
    print("[wake] Press Q in the camera window to cancel")

    face_first_seen: float | None = None
    greeted = False

    try:
        while True:
            ok, frame = cap.read()
            if not ok:
                break

            grey = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            faces = _CASCADE.detectMultiScale(grey, scaleFactor=1.1, minNeighbors=5, minSize=(80, 80))

            if len(faces) > 0:
                # Draw box around first face
                x, y, w, h = faces[0]
                cv2.rectangle(frame, (x, y), (x + w, y + h), (80, 200, 120), 2)

                if face_first_seen is None:
                    face_first_seen = time.time()

                held = time.time() - face_first_seen
                bar_w = int((held / FACE_HOLD_SECONDS) * w)
                cv2.rectangle(frame, (x, y + h + 6), (x + bar_w, y + h + 14), (80, 200, 120), -1)

                if not greeted and held >= FACE_HOLD_SECONDS:
                    greeted = True
                    greeting = (
                        f"Good morning, {USER_NAME}. "
                        "While you were asleep, I've been busy. "
                        "I found some great opportunities and took care of a few things — "
                        "let me walk you through them."
                    )
                    print(f"[wake] Face held {held:.1f}s → greeting")
                    _speak_async(greeting)
                    cv2.destroyAllWindows()
                    cap.release()
                    if on_wake:
                        on_wake()
                    return
            else:
                face_first_seen = None

            cv2.putText(
                frame, "Ali is watching...", (12, 28),
                cv2.FONT_HERSHEY_SIMPLEX, 0.7, (80, 200, 120), 2,
            )
            cv2.imshow("Ali — Wake Detection", frame)

            if cv2.waitKey(1) & 0xFF == ord("q"):
                break
    finally:
        cap.release()
        cv2.destroyAllWindows()


if __name__ == "__main__":
    run_wake(on_wake=lambda: print("\n[demo] Wake fired — next step would start here"))
