"""
Floating glass overlay for the Ali voice agent.
"""

from __future__ import annotations

import queue
import tkinter as tk
from tkinter import font as tkfont


def _apply_macos_overlay(win: tk.Toplevel) -> None:
    """
    Patch the NSWindow so Ali floats above fullscreen apps on every Space,
    with real transparency (not just tkinter's black-key trick).

    Window level 25 = NSStatusBarWindowLevel — above Mission Control and
    fullscreen apps. Collection behaviour flags:
      1   = NSWindowCollectionBehaviorCanJoinAllSpaces
      16  = NSWindowCollectionBehaviorStationary
      256 = NSWindowCollectionBehaviorFullScreenAuxiliary
    """
    try:
        from AppKit import NSApplication, NSColor  # pyobjc-framework-Cocoa

        _MARKER = "__ali_overlay_find__"
        win.title(_MARKER)
        win.update_idletasks()

        ns_app = NSApplication.sharedApplication()
        ns_win = None
        for w in ns_app.windows():
            try:
                if w.title() == _MARKER:
                    ns_win = w
                    break
            except Exception:
                continue

        if ns_win is not None:
            ns_win.setLevel_(25)                          # above fullscreen
            ns_win.setCollectionBehavior_(1 | 16 | 256)   # all spaces + aux
            ns_win.setOpaque_(False)
            ns_win.setBackgroundColor_(NSColor.clearColor())

            # Add NSVisualEffectView for frosted-glass blur behind canvas
            try:
                from AppKit import (
                    NSVisualEffectView,
                    NSVisualEffectBlendingModeBehindWindow,
                    NSVisualEffectStateActive,
                )
                cv = ns_win.contentView()
                vev = NSVisualEffectView.alloc().initWithFrame_(cv.bounds())
                vev.setMaterial_(4)          # NSVisualEffectMaterialDark
                vev.setBlendingMode_(NSVisualEffectBlendingModeBehindWindow)
                vev.setState_(NSVisualEffectStateActive)
                vev.setAutoresizingMask_(2 | 16)
                cv.addSubview_positioned_relativeTo_(vev, 0, None)
            except Exception:
                pass  # blur is cosmetic — skip if unavailable

        win.title("")
    except Exception as e:
        print(f"[overlay] native boost skipped: {e}")

# ── Palette ───────────────────────────────────────────────────────────────────
BG_TRANSPARENT = "black"
GLASS_FILL     = "#1A1A1C"        # dark tint — blur bleeds through
GLASS_BORDER   = "#38383A"        # slightly brighter rim for definition
GLASS_INNER    = "#222224"
HEADER_FG      = "#636366"        # tertiary label
TEXT_FG        = "#F2F2F7"
ACCENT_RED     = "#FF453A"
ACCENT_YELLOW  = "#FFD60A"
ACCENT_BLUE    = "#64D2FF"
ACCENT_GREEN   = "#30D158"

CLOSE_BG       = "#2C2C2E"        # close button resting fill
CLOSE_BG_HOT   = "#48484A"        # close button hover fill
CLOSE_FG       = "#8E8E93"        # × glyph colour

# ── Layout ────────────────────────────────────────────────────────────────────
W              = 440
MAX_HISTORY    = 6
RADIUS         = 18
PX             = 20               # horizontal padding
PT             = 14               # top padding
PB             = 16               # bottom padding

CLOSE_R        = 9                # close button circle radius
CLOSE_CX       = PX + CLOSE_R    # centre x of close button
CLOSE_CY       = PT + CLOSE_R    # centre y of close button

# ── Animation ─────────────────────────────────────────────────────────────────
PULSE_MS       = 480
POLL_MS        = 40
AUTO_HIDE_MS   = 4_000


def _rrect(canvas: tk.Canvas, x1, y1, x2, y2, r, **kw):
    pts = [
        x1+r, y1,   x2-r, y1,
        x2,   y1,   x2,   y1+r,
        x2,   y2-r, x2,   y2,
        x2-r, y2,   x1+r, y2,
        x1,   y2,   x1,   y2-r,
        x1,   y1+r, x1,   y1,
    ]
    return canvas.create_polygon(pts, smooth=True, **kw)


class TranscriptionOverlay:
    def __init__(self, root: tk.Tk) -> None:
        self._root   = root
        self._q: queue.Queue[tuple[str, str]] = queue.Queue()
        self._history: list[tuple[str, str]] = []

        self._drag_x = 0
        self._drag_y = 0

        self._pulse_id:     str | None = None
        self._auto_hide_id: str | None = None
        self._pulse_state   = True
        self._close_hot     = False

        self._build()
        self._poll()

    # ── Public ────────────────────────────────────────────────────────────────

    def push(self, state: str, text: str = "") -> None:
        self._q.put((state, text))

    # ── Window construction ───────────────────────────────────────────────────

    def _build(self) -> None:
        win = tk.Toplevel(self._root)
        win.withdraw()
        win.overrideredirect(True)
        win.wm_attributes("-topmost", True)
        win.wm_attributes("-alpha", 0.88)
        try:
            win.wm_attributes("-transparent", True)
        except tk.TclError:
            pass
        win.configure(bg=BG_TRANSPARENT)

        sw = win.winfo_screenwidth()
        sh = win.winfo_screenheight()
        win.geometry(f"1x1+{(sw - W) // 2}+{sh - 210}")

        self._canvas = tk.Canvas(
            win, bg=BG_TRANSPARENT, highlightthickness=0, bd=0,
        )
        self._canvas.pack(fill="both", expand=True)

        families = tkfont.families()
        body_fam  = "SF Pro Display" if "SF Pro Display"  in families else "Helvetica Neue"
        ui_fam    = "SF Pro Text"    if "SF Pro Text"     in families else "Helvetica Neue"

        self._f_label  = tk.font.Font(family=ui_fam,   size=11)
        self._f_body   = tk.font.Font(family=body_fam,  size=15, weight="bold")
        self._f_small  = tk.font.Font(family=ui_fam,    size=13)
        self._f_close  = tk.font.Font(family=ui_fam,    size=11, weight="bold")

        win.bind("<Button-1>",         self._on_click)
        win.bind("<B1-Motion>",        self._drag_move)
        self._canvas.bind("<Motion>",  self._on_motion)
        self._canvas.bind("<Leave>",   self._on_leave)

        self._win = win
        _apply_macos_overlay(win)

    # ── Input handling ────────────────────────────────────────────────────────

    def _on_click(self, e: tk.Event) -> None:
        if self._hit_close(e.x, e.y):
            self._hide()
        else:
            self._drag_x = e.x_root - self._win.winfo_x()
            self._drag_y = e.y_root - self._win.winfo_y()

    def _drag_move(self, e: tk.Event) -> None:
        if not self._hit_close(e.x, e.y):
            nx = e.x_root - self._drag_x
            ny = e.y_root - self._drag_y
            self._win.geometry(f"+{nx}+{ny}")

    def _on_motion(self, e: tk.Event) -> None:
        hot = self._hit_close(e.x, e.y)
        if hot != self._close_hot:
            self._close_hot = hot
            self._redraw_close(hot)

    def _on_leave(self, e: tk.Event) -> None:
        if self._close_hot:
            self._close_hot = False
            self._redraw_close(False)

    def _hit_close(self, x: int, y: int) -> bool:
        return (x - CLOSE_CX) ** 2 + (y - CLOSE_CY) ** 2 <= CLOSE_R ** 2

    # ── Queue poll ────────────────────────────────────────────────────────────

    def _poll(self) -> None:
        try:
            while True:
                state, text = self._q.get_nowait()
                self._apply(state, text)
        except queue.Empty:
            pass
        self._root.after(POLL_MS, self._poll)

    # ── State transitions ─────────────────────────────────────────────────────

    def _apply(self, state: str, text: str) -> None:
        for attr in ("_auto_hide_id", "_pulse_id"):
            h = getattr(self, attr)
            if h:
                self._root.after_cancel(h)
                setattr(self, attr, None)

        if state == "hidden":
            self._win.withdraw()
            return

        if state == "recording":
            self._history.clear()
            self._win.deiconify()
            self._win.lift()
            self._redraw_recording()
            self._pulse_tick()
            return

        if state == "transcribing":
            colour, display = ACCENT_YELLOW, "Transcribing…"
        elif state == "transcript":
            colour, display = TEXT_FG, text
            self._history.append((display, colour))
        elif state == "intent":
            colour, display = ACCENT_BLUE, text
            self._history.append((display, colour))
        elif state == "action":
            colour, display = ACCENT_GREEN, text
            self._history.append((display, colour))
        elif state == "done":
            colour, display = ACCENT_GREEN, "✓  Done"
            self._history.append((display, colour))
            self._auto_hide_id = self._root.after(AUTO_HIDE_MS, self._win.withdraw)
        elif state == "error":
            colour, display = ACCENT_RED, text or "Error"
            self._history.append((display, colour))
            self._auto_hide_id = self._root.after(AUTO_HIDE_MS, self._win.withdraw)
        else:
            colour, display = TEXT_FG, text

        self._win.deiconify()
        self._win.lift()
        self._redraw_history()

    # ── Canvas rendering ──────────────────────────────────────────────────────

    def _draw_shell(self, h: int) -> None:
        """Draw glass background + close button — shared by all states."""
        c = self._canvas
        # Outer glass body
        _rrect(c, 0, 0, W, h, RADIUS,
               fill=GLASS_FILL, outline=GLASS_BORDER, width=1)
        # Subtle inner highlight rim (top edge only, faint)
        _rrect(c, 1, 1, W-1, h-1, RADIUS-1,
               fill="", outline="#28282C", width=1)

        self._redraw_close(self._close_hot)

    def _redraw_close(self, hot: bool) -> None:
        c = self._canvas
        c.delete("close")
        cx, cy, r = CLOSE_CX, CLOSE_CY, CLOSE_R
        bg = CLOSE_BG_HOT if hot else CLOSE_BG
        c.create_oval(cx-r, cy-r, cx+r, cy+r,
                      fill=bg, outline="", tags="close")
        c.create_text(cx, cy+0.5,
                      text="×", fill=CLOSE_FG,
                      font=self._f_close, anchor="center", tags="close")

    def _redraw_recording(self) -> None:
        c = self._canvas
        c.delete("all")

        line_h = self._f_body.metrics("linespace") + 6
        h = PT + line_h + PB + 32

        self._win.geometry(f"{W}x{h}")
        c.configure(width=W, height=h)
        self._draw_shell(h)

        # Header label — centred
        c.create_text(
            W // 2, PT + 2,
            text="Ali  ·  Listening",
            anchor="n", fill=HEADER_FG, font=self._f_label,
        )

        # Pulsing dot + hint row
        cy = PT + 26 + 14
        self._ring_cy = cy
        self._ring_x  = PX + 28
        self._redraw_ring(ACCENT_RED)

        c.create_text(
            self._ring_x + 22, cy,
            text="Hold Right Shift to record  ·  Space + Right Shift to dismiss",
            anchor="w", fill=HEADER_FG, font=self._f_label,
        )

    def _redraw_ring(self, colour: str) -> None:
        c = self._canvas
        c.delete("ring")
        cx, cy, r = self._ring_x, self._ring_cy, 5
        c.create_oval(cx-r, cy-r, cx+r, cy+r,
                      fill=colour, outline="", tags="ring")

    def _pulse_tick(self) -> None:
        if not self._pulse_id and not self._win.winfo_ismapped():
            return
        self._pulse_state = not self._pulse_state
        col = ACCENT_RED if self._pulse_state else GLASS_FILL
        self._redraw_ring(col)
        self._pulse_id = self._root.after(PULSE_MS, self._pulse_tick)

    def _redraw_history(self) -> None:
        c = self._canvas
        c.delete("all")

        recent  = self._history[-MAX_HISTORY:]
        line_h  = self._f_body.metrics("linespace") + 6
        h = PT + 22 + len(recent) * (line_h + 4) + PB
        h = max(h, 78)

        self._win.geometry(f"{W}x{h}")
        c.configure(width=W, height=h)
        self._draw_shell(h)

        # Centred "Ali" header
        c.create_text(
            W // 2, PT + 2,
            text="Ali",
            anchor="n", fill=HEADER_FG, font=self._f_label,
        )

        y = PT + 26
        for i, (text, colour) in enumerate(recent):
            is_latest = i == len(recent) - 1
            fnt = self._f_body if is_latest else self._f_small
            fg  = colour       if is_latest else HEADER_FG
            c.create_text(
                PX + 4, y,
                text=text, anchor="nw",
                fill=fg, font=fnt,
                width=W - (PX + 4) * 2,
            )
            lines = max(1, len(text) // 40 + 1)
            y += fnt.metrics("linespace") * lines + 6

    # ── Hide ──────────────────────────────────────────────────────────────────

    def _hide(self) -> None:
        if self._pulse_id:
            self._root.after_cancel(self._pulse_id)
            self._pulse_id = None
        if self._auto_hide_id:
            self._root.after_cancel(self._auto_hide_id)
            self._auto_hide_id = None
        self._win.withdraw()
