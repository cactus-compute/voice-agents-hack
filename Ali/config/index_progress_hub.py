"""
Tiny pub/sub hub that buffers disk-index progress events between the
bootstrap subprocess (which starts early, from main thread) and downstream
UI consumers (menu bar, overlay) that come online later on other threads.

Thread-safe and dependency-free.
"""

from __future__ import annotations

import threading
from collections import deque
from typing import Callable

Listener = Callable[[str, dict], None]

_lock = threading.Lock()
_listeners: list[Listener] = []
_buffer: deque[tuple[str, dict]] = deque(maxlen=256)
_last_event: tuple[str, dict] | None = None


def publish(event: str, data: dict) -> None:
    """Called by the bootstrap watcher thread for every build event."""
    snapshot = dict(data)
    global _last_event
    with _lock:
        _last_event = (event, snapshot)
        _buffer.append((event, snapshot))
        listeners = list(_listeners)
    for listener in listeners:
        try:
            listener(event, snapshot)
        except Exception:
            # Never let a broken consumer break the build pipeline.
            pass


def subscribe(listener: Listener, *, replay: bool = True) -> Callable[[], None]:
    """Register a consumer; returns an unsubscribe callable.

    If ``replay`` is True (default), the listener is immediately invoked with
    every buffered event so late arrivals catch up on progress already made.
    """
    with _lock:
        _listeners.append(listener)
        to_replay = list(_buffer) if replay else []

    for event, data in to_replay:
        try:
            listener(event, data)
        except Exception:
            pass

    def _unsubscribe() -> None:
        with _lock:
            try:
                _listeners.remove(listener)
            except ValueError:
                pass

    return _unsubscribe


def last_event() -> tuple[str, dict] | None:
    with _lock:
        return _last_event
