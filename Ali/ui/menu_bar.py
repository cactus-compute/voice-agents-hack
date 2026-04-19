"""
Layer 5 — macOS Menu Bar

Minimal status indicator + "Rebuild Index…" menu item. Uses rumps
(macOS-only). Falls back to a no-op stub on other platforms.

Indexing progress is intentionally *not* surfaced in the menu bar title —
the terminal already shows a tqdm bar and the per-event log. The menu bar
only toggles between the coarse agent states (ready / transcribing /
parsing / running / indexing / error).
"""

from __future__ import annotations

import subprocess
import sys
import threading
from pathlib import Path

try:
    import rumps  # type: ignore
    RUMPS_AVAILABLE = True
except ImportError:
    RUMPS_AVAILABLE = False

STATUS_ICONS = {
    "ready":          "🎙",
    "transcribing":   "⏳",
    "parsing intent": "🧠",
    "running":        "⚙️",
    "indexing":       "📚",
    "error":          "⚠️",
}


_BUILD_SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "build_index.py"


class MenuBar:
    def __init__(self):
        if RUMPS_AVAILABLE:
            self._app = _MenuBarApp(on_rebuild=self._rebuild_index)
        else:
            self._app = None
        self._rebuild_thread: threading.Thread | None = None

    def set_status(self, status: str):
        icon = STATUS_ICONS.get(status, "●")
        label = f"{icon} {status.capitalize()}"
        if self._app is not None:
            self._app.title = label
        else:
            print(f"[menu_bar] {label}")

    def _rebuild_index(self) -> None:
        """Run scripts/build_index.py in a background thread so the UI stays
        responsive. Only one rebuild may be in flight at a time."""
        if self._rebuild_thread is not None and self._rebuild_thread.is_alive():
            print("[menu_bar] rebuild already in progress, ignoring click")
            return

        def _worker() -> None:
            self.set_status("indexing")
            try:
                from config.index_bootstrap import ensure_index

                ensure_index(force_rebuild=True, background=False)
            except Exception as exc:
                print(f"[menu_bar] rebuild failed: {exc}")
            finally:
                self.set_status("ready")

        self._rebuild_thread = threading.Thread(
            target=_worker, daemon=True, name="index-rebuild"
        )
        self._rebuild_thread.start()


if RUMPS_AVAILABLE:
    class _MenuBarApp(rumps.App):
        def __init__(self, *, on_rebuild):
            super().__init__("🎙 Ready", quit_button=None)
            self._on_rebuild = on_rebuild
            self.menu = [
                rumps.MenuItem("Rebuild Index…", callback=self._handle_rebuild),
                None,
                rumps.MenuItem("Quit", callback=self._handle_quit),
            ]

        def _handle_rebuild(self, _sender) -> None:
            self._on_rebuild()

        def _handle_quit(self, _sender) -> None:
            rumps.quit_application()
