#!/usr/bin/env python3
"""Edge effect for the lab_pc (Linux/X11) side of Deskflow.

Deskflow (Flatpak) runs this through `flatpak-spawn --host` when the cursor
enters this computer. Shows a glow along the edge facing the Mac (from
config.json, written by the Edgeflow helper) plus a ripple at the cursor, plays
enter.wav, then exits. Click-through, never takes focus.

Uses two small windows (edge band + ripple box) instead of one that covers the
whole monitor: GNOME/Mutter un-redirects monitor-sized override-redirect
windows, which skips compositing and turns the transparent area black.

Drawn with GTK3 CSS only (no pycairo needed), click-through via the X11
SHAPE extension through ctypes, so nothing extra has to be installed.

Also writes ~/.cache/edgeflow/active so edgeflow-helper.py knows this computer is
the active screen (Deskflow's exit command removes it).

Usage: edge-fx.py [sound.wav] [edge: bottom|top|left|right]  (both default from config)
"""
import ctypes
import json
import os
import subprocess
import sys
import time
from pathlib import Path

# Deskflow's host-spawned process may not inherit the desktop session env:
# borrow it from the desktop shell.
def _import_session():
    if os.environ.get("DISPLAY"):
        return
    import subprocess as sp
    pids = sp.run(["pgrep", "-u", str(os.getuid()), "-x", "gnome-shell"], capture_output=True, text=True).stdout.split()
    for pid in pids:
        try:
            for kv in open(f"/proc/{pid}/environ", "rb").read().split(b"\0"):
                k, _, v = kv.decode(errors="ignore").partition("=")
                if k in ("DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS"):
                    os.environ.setdefault(k, v)
        except OSError:
            continue
        if os.environ.get("DISPLAY"):
            return


_import_session()
os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
if os.environ.get("WAYLAND_DISPLAY") and os.environ.get("DISPLAY"):
    os.environ["GDK_BACKEND"] = "x11"

import gi  # noqa: E402

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
gi.require_version("GdkX11", "3.0")
from gi.repository import Gdk, GdkX11, GLib, Gtk  # noqa: E402,F401

HERE = Path(__file__).resolve().parent
try:
    CFG = json.loads((HERE / "config.json").read_text())  # written by Edgeflow on the Mac
except (OSError, ValueError):
    CFG = {}
SOUND_ON = CFG.get("soundEnabled", True)
EFFECT_ON = CFG.get("effectEnabled", True)
VOLUME = float(CFG.get("volume", 0.8))
DURATION = max(0.2, float(CFG.get("duration", 0.75)))
_c = CFG.get("color", [0.35, 0.85, 1.0])
RGB = ",".join(str(int(round(v * 255))) for v in _c)
BAND = int(CFG.get("glow", 70))
RIPPLE_ON = CFG.get("ripple", True)
SOUND = sys.argv[1] if len(sys.argv) > 1 else str(HERE / "enter.wav")
EDGE = sys.argv[2] if len(sys.argv) > 2 else CFG.get("edge", "bottom")
RINGS = (0.0, 0.18)  # start lag of each ripple ring
MAX_R = 78
BOX = MAX_R * 2 + 8  # ripple window size
STATE = Path.home() / ".cache" / "edgeflow" / "active"


def make_click_through(xid):
    """Empty X11 input shape => every click passes through the window."""
    try:
        x11 = ctypes.CDLL("libX11.so.6")
        xext = ctypes.CDLL("libXext.so.6")
        x11.XOpenDisplay.restype = ctypes.c_void_p
        x11.XOpenDisplay.argtypes = [ctypes.c_char_p]
        x11.XFlush.argtypes = [ctypes.c_void_p]
        x11.XCloseDisplay.argtypes = [ctypes.c_void_p]
        xext.XShapeCombineRectangles.argtypes = [
            ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_int, ctypes.c_int,
            ctypes.c_void_p, ctypes.c_int, ctypes.c_int, ctypes.c_int]
        dpy = x11.XOpenDisplay(None)
        if not dpy:
            return
        SHAPE_INPUT, SHAPE_SET, UNSORTED = 2, 0, 0
        xext.XShapeCombineRectangles(dpy, xid, SHAPE_INPUT, 0, 0, None, 0, SHAPE_SET, UNSORTED)
        x11.XFlush(dpy)
        x11.XCloseDisplay(dpy)
    except OSError:
        pass


def overlay(x, y, w, h):
    win = Gtk.Window(type=Gtk.WindowType.POPUP)
    win.get_style_context().add_class("fxwin")
    visual = win.get_screen().get_rgba_visual()
    if visual is not None:
        win.set_visual(visual)
    win.set_accept_focus(False)
    win.set_keep_above(True)
    win.move(x, y)
    win.set_default_size(w, h)
    win.set_size_request(w, h)
    win.connect("realize", lambda ww: make_click_through(ww.get_window().get_xid()))
    return win


def play_sound():
    if SOUND_ON and SOUND and os.path.exists(SOUND):
        subprocess.Popen(["pw-play", "--volume", f"{VOLUME:.2f}", SOUND],
                         stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def main():
    if not os.environ.get("DESKFLOW_FX_PREVIEW"):  # previews from Edgeflow don't mean lab_pc is active
        STATE.parent.mkdir(parents=True, exist_ok=True)
        STATE.write_text(str(time.time()))
    if not EFFECT_ON:
        play_sound()
        return

    display = Gdk.Display.get_default()
    _, px, py = display.get_default_seat().get_pointer().get_position()
    mon = display.get_monitor_at_point(px, py).get_geometry()

    css = Gtk.CssProvider()
    Gtk.StyleContext.add_provider_for_screen(
        Gdk.Screen.get_default(), css, Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    # 1) edge band window
    if EDGE in ("top", "bottom"):
        bx, by, bw, bh = mon.x, mon.y if EDGE == "top" else mon.y + mon.height - BAND, mon.width, BAND
    else:
        bx, by, bw, bh = mon.x if EDGE == "left" else mon.x + mon.width - BAND, mon.y, BAND, mon.height
    band_win = overlay(bx, by, bw, bh)
    glow = Gtk.Box()
    glow.set_name("glow")
    band_win.add(glow)
    direction = {"bottom": "to top", "top": "to bottom", "left": "to right", "right": "to left"}[EDGE]

    # 2) ripple window centred on the cursor
    rx, ry = px - BOX // 2, py - BOX // 2
    ripple_win = overlay(rx, ry, BOX, BOX)
    fixed = Gtk.Fixed()
    ripple_win.add(fixed)
    c = BOX // 2
    rings = []
    for i in range(len(RINGS)):
        r = Gtk.Box()
        r.set_name(f"ring{i}")
        fixed.put(r, c, c)
        rings.append(r)
    dot = Gtk.Box()
    dot.set_name("dot")
    dot.set_size_request(12, 12)
    fixed.put(dot, c - 6, c - 6)

    def render(p):
        fade = 1 - p * p
        parts = [
            ".fxwin { background-color: transparent; }",
            f"#glow {{ background-image: linear-gradient({direction}, "
            f"rgba({RGB},{0.85 * fade:.3f}), rgba({RGB},0)); }}",
            f"#dot {{ border-radius: 9999px; background-color: rgba({RGB},{0.6 * fade:.3f}); }}",
        ]
        for i, lag in enumerate(RINGS):
            q = max(0.0, min(1.0, (p - lag) / (1 - lag)))
            radius = int(8 + (MAX_R - 8) * (1 - (1 - q) ** 3))
            alpha = (1 - q) * (0.9 if i == 0 else 0.55) if q > 0 else 0
            width = max(1, int(round(3 * (1 - q) + 1)))
            parts.append(
                f"#ring{i} {{ border-radius: 9999px; border: {width}px solid rgba({RGB},{alpha:.3f}); }}")
            rings[i].set_size_request(radius * 2, radius * 2)
            fixed.move(rings[i], c - radius, c - radius)
        css.load_from_data("\n".join(parts).encode())

    render(0.0)
    if BAND > 0:
        band_win.show_all()
    if RIPPLE_ON:
        ripple_win.show_all()
    play_sound()

    start = time.monotonic()

    def tick():
        p = (time.monotonic() - start) / DURATION
        if p >= 1:
            band_win.destroy()
            ripple_win.destroy()
            GLib.timeout_add(250, Gtk.main_quit)
            return False
        render(p)
        return True

    GLib.timeout_add(16, tick)
    Gtk.main()


if __name__ == "__main__":
    main()
