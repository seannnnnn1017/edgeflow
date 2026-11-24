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

VERSION = "1.0.0"
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
                                           {"v": VERSION, "cv": cfg.get("cv", ""), "active": active})))
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


def supervise():
    """Keep Deskflow running (or stopped while paused)."""
    if cfg.get("paused"):
        if deskflow_running():
            stop_deskflow()
    elif not deskflow_running():
        start_deskflow()
    return True


# ---- charge sound --------------------------------------------------------------------
st = {"since": None, "armed": False, "proc": None, "state_mtime": None}
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
    return {"bottom": y >= mon.y + mon.height - 1 - TOL, "top": y <= mon.y + TOL,
            "left": x <= mon.x + TOL, "right": x >= mon.x + mon.width - 1 - TOL}.get(edge, False)


def charge_tick():
    delay = float(cfg.get("delay", 0.25))
    enabled = cfg.get("chargeSound", True) and cfg.get("soundEnabled", True) and delay >= 0.05 and not cfg.get("paused")
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
    if enabled and mtime is not None and at_edge(x, y, mon):
        if st["since"] is None and st["armed"]:
            st["since"] = time.monotonic()
            st["armed"] = False
            play_charge()
    else:
        if st["since"] is not None and time.monotonic() - st["since"] < keep:
            stop_sound()
        st["since"] = None
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
threading.Thread(target=poll_loop, daemon=True).start()
start_deskflow()
GLib.timeout_add(16, charge_tick)
GLib.timeout_add(2000, supervise)
Gtk.main()
