"""
Layer 5 — macOS Menu Bar
Shows a status icon in the menu bar and provides a push-to-talk button.
Uses rumps (macOS-only). Falls back to a no-op stub on other platforms.
"""

try:
    import rumps  # type: ignore
    RUMPS_AVAILABLE = True
except ImportError:
    RUMPS_AVAILABLE = False

STATUS_ICONS = {
    "ready":        "🎙",
    "transcribing": "⏳",
    "parsing intent": "🧠",
    "running":      "⚙️",
    "error":        "⚠️",
}


class MenuBar:
    def __init__(self):
        if RUMPS_AVAILABLE:
            self._app = _MenuBarApp()
        else:
            self._app = None

    def set_status(self, status: str):
        icon = STATUS_ICONS.get(status, "●")
        label = f"{icon} {status.capitalize()}"
        if self._app:
            self._app.title = label
        else:
            print(f"[menu_bar] {label}")


if RUMPS_AVAILABLE:
    class _MenuBarApp(rumps.App):
        def __init__(self):
            super().__init__("🎙 Ready", quit_button=None)

        @rumps.clicked("Quit")
        def quit(self, _):
            rumps.quit_application()
