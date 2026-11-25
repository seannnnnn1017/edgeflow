#!/usr/bin/env python3
"""Edgeflow helper for Linux. Started at login; one process does it all:

- runs the Deskflow client (deskflow-start.sh) and keeps it running
- polls the Mac every few seconds for settings (signed with this computer's device key),
  fetches new sounds, applies key settings, and runs commands (preview, restart, update,
  uninstall)
- charge sound while the cursor is pressed against the edge toward the Mac
- clipboard images: Deskflow only carries BMP; GNOME and most apps use PNG, so whichever
  of the two is on the clipboard, the picture is re-offered in every format

`--apply-keys` applies the key settings once and exits (used by the installer).
"""
import hashlib
import hmac
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request
from pathlib import Path

VERSION = "1.2.2"
DIR = Path(__file__).resolve().parent
DEVICE = json.loads((DIR / "device.json").read_text())
CONFIG = DIR / "config.json"
STATE = Path.home() / ".cache" / "edgeflow" / "active"
LOG = Path.home() / ".var/app/org.deskflow.deskflow/deskflow.log"


def gs(schema, key, value):
    """gsettings set, only if the schema exists on this desktop."""
    env = dict(os.environ)
    env.setdefault("DBUS_SESSION_BUS_ADDRESS", f"unix:path=/run/user/{os.getuid()}/bus")
    subprocess.run(["gsettings", "set", schema, key, value], env=env,
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def apply_keys(c):
    """Mac habits on this desktop. ⌘ → Ctrl itself is done by Deskflow on the Mac side."""
    on = c.get("keys", True)
    ime = c.get("ime", "caps")
    # ⌘⇧3 / ⌘⇧4 / ⌘⇧5 arrive as Ctrl+Shift+3/4/5
    gs("org.gnome.shell.keybindings", "screenshot", "['<Shift>Print', '<Ctrl><Shift>3']" if on else "['<Shift>Print']")
    gs("org.gnome.shell.keybindings", "show-screenshot-ui",
       "['Print', '<Ctrl><Shift>4', '<Ctrl><Shift>5', '<Ctrl><Super><Shift>4']" if on else "['Print']")
    # 中/英: 新酷音's own toggle key, or ⌃Space (arrives as Super+Space) to switch input sources
    gs("org.freedesktop.IBus.Chewing", "chi-eng-mode-toggle",
       {"caps": "caps_lock", "shift": "shift"}.get(ime, "shift") if on else "shift")
    if on and ime == "ctrlspace":
        gs("org.gnome.desktop.wm.keybindings", "switch-input-source", "['<Super>space', '<Control>space']")


if "--apply-keys" in sys.argv:
    try:
        apply_keys(json.loads(CONFIG.read_text()))
    except (OSError, ValueError):
        pass
    sys.exit(0)

# ---- desktop session -----------------------------------------------------------------
os.environ.setdefault("XDG_RUNTIME_DIR", f"/run/user/{os.getuid()}")
if os.environ.get("WAYLAND_DISPLAY") and os.environ.get("DISPLAY"):
    os.environ["GDK_BACKEND"] = "x11"   # overlays need X11 positioning (XWayland)

import gi  # noqa: E402

gi.require_version("Gdk", "3.0")
gi.require_version("Gtk", "3.0")
gi.require_version("GdkPixbuf", "2.0")
from gi.repository import Gdk, GdkPixbuf, GLib, Gtk  # noqa: E402,F401

cfg = {}
try:
    cfg = json.loads(CONFIG.read_text())
except (OSError, ValueError):
    pass


# ---- talking to the Mac --------------------------------------------------------------
LOGFILE = Path.home() / ".cache" / "edgeflow" / "helper.log"
_last = {"msg": None}


def log(msg):
    """Errors go to ~/.cache/edgeflow/helper.log (repeats collapsed)."""
    if msg == _last["msg"]:
        return
    _last["msg"] = msg
    try:
        LOGFILE.parent.mkdir(parents=True, exist_ok=True)
        with LOGFILE.open("a") as f:
            f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + msg + "\n")
    except OSError:
        pass


def base_urls():
    port = DEVICE["pairUrl"].rsplit(":", 1)[1]
    return [f"http://{DEVICE['serverHost']}:{port}", DEVICE["pairUrl"]]


def signed(path, extra=None):
    ts = str(int(time.time()))
    sig = hmac.new(bytes.fromhex(DEVICE["deviceKey"]), f"{DEVICE['deviceId']}:{ts}".encode(), hashlib.sha256).hexdigest()
    q = {"ts": ts, "sig": sig, **(extra or {})}
    return f"{path}?{urllib.parse.urlencode(q)}"


def fetch(path, timeout=6):
    last = None
    for base in base_urls():
        try:
            with urllib.request.urlopen(base + path, timeout=timeout) as r:
                return r.read()
        except Exception as e:  # noqa: BLE001 — try the next address
            last = e
    raise last


def sha(p):
    try:
        return hashlib.sha256(Path(p).read_bytes()).hexdigest()
    except OSError:
        return ""


# ---- Deskflow client -----------------------------------------------------------------
deskflow = {"proc": None}


def deskflow_running():
    p = deskflow["proc"]
    return p is not None and p.poll() is None


def start_deskflow():
    if deskflow_running() or cfg.get("paused"):
        return
    subprocess.run(["pkill", "-x", "deskflow-core"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deskflow["proc"] = subprocess.Popen([str(DIR / "deskflow-start.sh")], stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL, start_new_session=True)


def stop_deskflow():
    p = deskflow["proc"]
    if p and p.poll() is None:
        p.terminate()
    subprocess.run(["pkill", "-x", "deskflow-core"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    deskflow["proc"] = None


def uninstall():
    stop_deskflow()
    for f in ("edgeflow.desktop",):
        try:
            (Path.home() / ".config/autostart" / f).unlink()
        except OSError:
            pass
    shutil.rmtree(DIR, ignore_errors=True)
    GLib.idle_add(Gtk.main_quit)


def self_update(files):
    for name, want in files.items():
        if not name.endswith((".py", ".sh")) or sha(DIR / name) == want:
            continue
        data = fetch(f"/f/{name}", timeout=30)
        if hashlib.sha256(data).hexdigest() == want:
            tmp = DIR / (name + ".tmp")
            tmp.write_bytes(data)
            tmp.chmod(0o755)
            tmp.replace(DIR / name)
    stop_deskflow()
    os.execv(sys.executable, [sys.executable, str(DIR / "edgeflow-helper.py")])


def handle(cmd, payload):
    if cmd == "preview":
        env = dict(os.environ, DESKFLOW_FX_PREVIEW="1")
        subprocess.Popen([str(DIR / "edge-fx.py")], env=env)
    elif cmd == "restart":
        stop_deskflow()
    elif cmd == "update":
        self_update(payload.get("helperFiles", {}))
    elif cmd == "uninstall":
        uninstall()


def poll_loop():
    while True:
        try:
            active = "1" if STATE.exists() else "0"
            data = json.loads(fetch(signed(f"/c/{DEVICE['deviceId']}",
                                           {"v": VERSION, "cv": cfg.get("cv", ""), "active": active,
                                            "mon": screens["mon"]})))
            for wav, want in data.get("files", {}).items():
                if sha(DIR / wav) != want:
                    try:   # one failed sound must not hold up the settings
                        blob = fetch(signed(f"/d/{DEVICE['deviceId']}/{wav}"), timeout=20)
                        if hashlib.sha256(blob).hexdigest() == want:
                            (DIR / wav).write_bytes(blob)
                    except Exception as e:  # noqa: BLE001
                        log(f"sound {wav}: {e!r}")
            old_keys = (cfg.get("keys"), cfg.get("ime"))
            cmds = data.pop("commands", [])
            if data.get("cv") != cfg.get("cv"):
                CONFIG.write_text(json.dumps(data, indent=1))
                cfg.clear()
                cfg.update(data)
                if (cfg.get("keys"), cfg.get("ime")) != old_keys:
                    apply_keys(cfg)
            for c in cmds:
                GLib.idle_add(handle, c, data)
        except Exception as e:  # noqa: BLE001 — the Mac may be asleep or on another network
            log(f"poll: {e!r}")
        time.sleep(3)


screens = {"mon": ""}


def read_monitors():
    """"x,y,w,h,primary;…" in device pixels, so the Mac can draw these screens and line them up."""
    d = Gdk.Display.get_default()
    out = []
    for i in range(d.get_n_monitors()):
        m = d.get_monitor(i)
        g, f = m.get_geometry(), m.get_scale_factor()
        out.append(f"{g.x * f},{g.y * f},{g.width * f},{g.height * f},{int(m.is_primary())}")
    screens["mon"] = ";".join(out)


def supervise():
    """Keep Deskflow running (or stopped while paused); refresh the screen layout."""
    read_monitors()
    if cfg.get("paused"):
        if deskflow_running():
            stop_deskflow()
    elif not deskflow_running():
        start_deskflow()
    return True


# ---- charge sound --------------------------------------------------------------------
st = {"since": None, "armed": False, "proc": None, "state_mtime": None, "spent": False}
TOL = 2


def stop_sound():
    p = st["proc"]
    if p and p.poll() is None:
        p.terminate()
    st["proc"] = None


def play_charge():
    stop_sound()
    wav = DIR / "charge.wav"
    if wav.exists():
        st["proc"] = subprocess.Popen(["pw-play", "--volume", f"{float(cfg.get('volume', 0.6)):.2f}", str(wav)],
                                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def at_edge(x, y, mon):
    edge = cfg.get("edge", "bottom")
    # only the part of the edge that leads to the Mac (several screens: see the Mac's layout)
    scr = Gdk.Screen.get_default()
    f = x / max(1, scr.get_width()) if edge in ("top", "bottom") else y / max(1, scr.get_height())
    if not float(cfg.get("edgeLo", 0)) - 0.002 <= f <= float(cfg.get("edgeHi", 1)) + 0.002:
        return False
    return {"bottom": y >= mon.y + mon.height - 1 - TOL, "top": y <= mon.y + TOL,
            "left": x <= mon.x + TOL, "right": x >= mon.x + mon.width - 1 - TOL}.get(edge, False)


def make_click_through(xid):
    """Empty X11 input shape => clicks pass through (same as edge-fx.py)."""
    import ctypes
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
        if dpy:
            xext.XShapeCombineRectangles(dpy, xid, 2, 0, 0, None, 0, 0, 0)
            x11.XFlush(dpy)
            x11.XCloseDisplay(dpy)
    except OSError:
        pass


class ChargeGlow:
    """While the cursor pushes against the edge toward the Mac: a glow at that spot that
    grows and slowly brightens over the switch delay (same look as on the Mac)."""

    def __init__(self):
        self.win = None
        self.rect = None
        self.fade_from = None
        self.last = (0.0, 0)
        self.css = Gtk.CssProvider()
        Gtk.StyleContext.add_provider_for_screen(Gdk.Screen.get_default(), self.css,
                                                 Gtk.STYLE_PROVIDER_PRIORITY_APPLICATION)

    def _make(self, x, y, w, h):
        win = Gtk.Window(type=Gtk.WindowType.POPUP)
        win.get_style_context().add_class("chgwin")
        visual = win.get_screen().get_rgba_visual()
        if visual is not None:
            win.set_visual(visual)
        win.set_accept_focus(False)
        win.set_keep_above(True)
        win.move(x, y)
        win.set_default_size(w, h)
        win.set_size_request(w, h)
        win.connect("realize", lambda ww: make_click_through(ww.get_window().get_xid()))
        box = Gtk.Box()
        box.set_name("chg")
        win.add(box)
        return win

    def show(self, x, y, mon, p):
        self.fade_from = None
        edge = cfg.get("edge", "bottom")
        d = int(max(40, float(cfg.get("glow", 48))) * 1.4)
        if edge in ("top", "bottom"):
            rect = (mon.x, mon.y if edge == "top" else mon.y + mon.height - d, mon.width, d)
            along = x - mon.x
        else:
            rect = (mon.x if edge == "left" else mon.x + mon.width - d, mon.y, d, mon.height)
            along = y - mon.y
        if rect != self.rect:
            if self.win:
                self.win.destroy()
            self.win, self.rect = self._make(*rect), rect
        self.last = (p, along)
        self.render(p, along, 1.0)
        if not self.win.get_visible():
            self.win.show_all()

    def render(self, p, along, fade):
        edge = cfg.get("edge", "bottom")
        depth = max(40, float(cfg.get("glow", 48)))
        level = (0.12 + 0.88 * p ** 1.8) * fade
        reach = 90 + 300 * (1 - (1 - p) ** 2)
        deep = depth * (0.55 + 0.75 * p)
        c = [float(v) for v in cfg.get("color", [0.35, 0.85, 1.0])]
        hot = [v + (1 - v) * 0.4 * p for v in c]
        at = {"bottom": f"{along}px 100%", "top": f"{along}px 0%",
              "left": f"0% {along}px", "right": f"100% {along}px"}[edge]
        horizontal = edge in ("top", "bottom")

        def grad(rx, ry, a, col):
            size = f"{int(rx)}px {max(1, int(ry))}px" if horizontal else f"{max(1, int(ry))}px {int(rx)}px"
            rgb = ",".join(str(int(round(v * 255))) for v in col)
            return (f"radial-gradient(ellipse {size} at {at}, rgba({rgb},{a:.3f}) 0%, "
                    f"rgba({rgb},{a * 0.5:.3f}) 45%, rgba({rgb},0) 100%)")

        layers = [grad(reach * 0.9, 3, min(1.0, level * 1.1), hot),        # the edge line
                  grad(reach * 0.35, deep * 0.45, level, hot),            # hot core
                  grad(reach, deep, 0.9 * level, c)]                     # soft halo
        self.css.load_from_data((".chgwin { background-color: transparent; }\n"
                                 f"#chg {{ background-image: {', '.join(layers)}; }}").encode())

    def hide(self):
        if not self.win or not self.win.get_visible() or self.fade_from is not None:
            return
        self.fade_from = time.monotonic()

        def step():
            if self.fade_from is None:          # shown again meanwhile
                return False
            k = (time.monotonic() - self.fade_from) / 0.18
            if k >= 1:
                self.fade_from = None
                self.win.hide()
                return False
            self.render(self.last[0], self.last[1], 1 - k)
            return True
        GLib.timeout_add(16, step)


glow = None


def charge_tick():
    global glow
    delay = float(cfg.get("delay", 0.25))
    base = delay >= 0.05 and not cfg.get("paused")
    sound_on = base and cfg.get("chargeSound", True) and cfg.get("soundEnabled", True)
    glow_on = base and cfg.get("chargeGlow", True) and cfg.get("effectEnabled", True)
    keep = max(0.08, delay * 0.8)
    try:
        mtime = STATE.stat().st_mtime
    except FileNotFoundError:
        mtime = None
    if mtime != st["state_mtime"]:
        st["state_mtime"] = mtime
        st["armed"] = False          # just arrived (Deskflow drops the cursor on the edge): wait until off it
        st["since"] = None
    display = Gdk.Display.get_default()
    _, x, y = display.get_default_seat().get_pointer().get_position()
    mon = display.get_monitor_at_point(x, y).get_geometry()
    if (sound_on or glow_on) and mtime is not None and at_edge(x, y, mon):
        if st["since"] is None and st["armed"]:
            st["since"] = time.monotonic()
            st["armed"] = False
            if sound_on:
                play_charge()
        if st["since"] is not None and glow_on and not st["spent"]:
            if glow is None:
                glow = ChargeGlow()
            p = (time.monotonic() - st["since"]) / delay
            if p >= 1.1:        # fully charged: that's the crossing, don't wait for Deskflow's exit command
                glow.hide()
                st["spent"] = True
            else:
                glow.show(x, y, mon, min(1.0, p))
    else:
        if st["since"] is not None and time.monotonic() - st["since"] < keep:
            stop_sound()
        if glow is not None:
            glow.hide()     # also when Deskflow's exit command reset the charge first (no-op if hidden)
        st["since"] = None
        st["spent"] = False
        if mtime is not None:
            st["armed"] = True
    return True


# ---- clipboard images ----------------------------------------------------------------
CLIP = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD)
BMP = {"image/bmp", "image/x-bmp", "image/x-MS-bmp"}


def on_targets(_clip, atoms, *_):
    if not atoms:
        return
    names = {a.name() for a in atoms}
    if ("image/png" in names) != bool(names & BMP):
        CLIP.request_image(lambda _c, pixbuf, *_: pixbuf is not None and CLIP.set_image(pixbuf))


def on_owner_change(_clip, _event):
    if cfg.get("clipboard", True):
        CLIP.request_targets(on_targets)


CLIP.connect("owner-change", on_owner_change)
read_monitors()
threading.Thread(target=poll_loop, daemon=True).start()
start_deskflow()
GLib.timeout_add(16, charge_tick)
GLib.timeout_add(2000, supervise)
Gtk.main()
