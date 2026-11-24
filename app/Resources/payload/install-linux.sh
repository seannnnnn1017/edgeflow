#!/usr/bin/env bash
# Edgeflow installer for Linux. Started by the one-line command Edgeflow shows on the Mac:
# it checked this file's sha256 before running it, and passes the pairing secret as $1.
# Steps match the Mac's progress screen and are reported back to it as they finish.
set -u
URL="@@URL@@"
TOKEN="@@TOKEN@@"
VERSION="@@VERSION@@"
SECRET="${1:-}"
DIR="$HOME/.local/share/edgeflow"
APP=org.deskflow.deskflow
CONF_DIR="$HOME/.var/app/$APP/config/Deskflow"
LOG="$HOME/.var/app/$APP/deskflow.log"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
ok() { printf '  \033[32m✓\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✗\033[0m %s\n' "$*"; }
need() { command -v "$1" >/dev/null 2>&1; }
report() {
  curl -fsS -m 5 -X POST --data-urlencode "step=$1" --data-urlencode "state=$2" \
    --data-urlencode "msg=${3:-}" --data-urlencode "log=${4:-}" "$URL/s/$TOKEN" >/dev/null 2>&1 || true
}
fail() { bad "$2"; report "$1" fail "$2" "$2"; printf '\nEdgeflow: %s\n' "$2"; exit 1; }
sudo_run() {
  if [ -n "${EF_SUDO_PASS:-}" ]; then printf '%s\n' "$EF_SUDO_PASS" | sudo -S -p '' "$@"; else sudo "$@"; fi
}
# When run over SSH there is no desktop session in the environment: borrow it from a
# process of the logged-in desktop.
import_session() {
  [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && return
  for pid in $(pgrep -u "$(id -u)" -x gnome-shell) $(pgrep -u "$(id -u)" -f 'plasmashell|xfce4-session|cinnamon|mate-session'); do
    [ -r "/proc/$pid/environ" ] || continue
    while IFS= read -r -d '' kv; do
      case "$kv" in
        DISPLAY=*|WAYLAND_DISPLAY=*|XAUTHORITY=*|DBUS_SESSION_BUS_ADDRESS=*|XDG_RUNTIME_DIR=*|XDG_SESSION_TYPE=*|XDG_CURRENT_DESKTOP=*) export "$kv" ;;
      esac
    done < "/proc/$pid/environ"
    [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ] && return
  done
}

bold "Edgeflow $VERSION"
[ -n "$SECRET" ] || fail 1 "missing pairing secret"
for c in curl openssl python3 sha256sum; do need "$c" || fail 1 "需要 $c / $c is required"; done
import_session

# 1. connect to the Mac and receive the sealed pairing bundle
. /etc/os-release 2>/dev/null
OSV="${PRETTY_NAME:-Linux}"; OSV="${OSV% LTS}"
RESP=$(curl -fsS -m 60 -X POST --data-urlencode "hostname=$(hostname)" --data-urlencode "os=linux" \
  --data-urlencode "osv=$OSV" --data-urlencode "arch=$(uname -m)" "$URL/p/$TOKEN") \
  || fail 1 "連不到 Mac / can't reach the Mac"
IV=$(printf '%s\n' "$RESP" | sed -n 1p)
CT=$(printf '%s\n' "$RESP" | sed -n 2p)
SIG=$(printf '%s\n' "$RESP" | sed -n 3p)
ENC=$(printf 'enc:%s' "$SECRET" | sha256sum | cut -c1-64)
MACKEY=$(printf 'mac:%s' "$SECRET" | sha256sum | cut -c1-64)
CHECK=$(printf '%s' "$CT" | openssl dgst -sha256 -mac HMAC -macopt "hexkey:$MACKEY" -r | cut -c1-64)
[ "$CHECK" = "$SIG" ] || fail 1 "配對資料驗證失敗 / pairing data failed its check"
BUNDLE=$(printf '%s' "$CT" | openssl enc -d -aes-256-cbc -K "$ENC" -iv "$IV" -base64 -A) || fail 1 "decrypt failed"
j() { printf '%s' "$BUNDLE" | python3 -c "import json,sys; v=json.load(sys.stdin)$1; print(v if isinstance(v,str) else json.dumps(v))"; }
SCREEN=$(j "['screen']"); SERVER=$(j "['server']"); SFP=$(j "['serverFingerprint']")
ok "Mac"; report 1 ok

# 2. Deskflow (Flatpak, per user: no admin rights needed once Flatpak exists)
if ! need flatpak; then
  echo "  Flatpak…（需要你的密碼 / needs your password）"
  if need apt-get; then sudo_run apt-get install -y flatpak >/dev/null 2>&1 || fail 2 "flatpak install failed"
  elif need dnf; then sudo_run dnf install -y flatpak >/dev/null 2>&1 || fail 2 "flatpak install failed"
  else fail 2 "請先安裝 flatpak / please install flatpak first"; fi
fi
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo >/dev/null 2>&1
flatpak install --user -y --noninteractive flathub "$APP" >/dev/null 2>&1 || flatpak info "$APP" >/dev/null 2>&1 \
  || fail 2 "下載逾時，請確認這台電腦能上網 / download timed out, check this computer is online"
flatpak override --user --talk-name=org.freedesktop.Flatpak "$APP"   # lets Deskflow run the edge effect
ok "Deskflow"; report 2 ok

# 3. Edgeflow helper
mkdir -p "$DIR" "$HOME/.config/autostart"
for f in edge-fx.py edgeflow-helper.py deskflow-start.sh; do
  want=$(j "['files']['$f']")
  curl -fsS -m 60 "$URL/f/$f" -o "$DIR/$f.tmp" || fail 3 "download $f"
  [ "$(sha256sum "$DIR/$f.tmp" | cut -c1-64)" = "$want" ] || fail 3 "$f failed its check"
  mv "$DIR/$f.tmp" "$DIR/$f"; chmod +x "$DIR/$f"
done
printf '%s' "$BUNDLE" | python3 -c "
import json, sys
b = json.load(sys.stdin)
keep = ('deviceId', 'deviceKey', 'screen', 'name', 'server', 'serverHost', 'pairUrl', 'serverFingerprint', 'version')
json.dump({k: b[k] for k in keep}, open(sys.argv[1], 'w'), indent=1)
json.dump(b['config'], open(sys.argv[2], 'w'), indent=1)" "$DIR/device.json" "$DIR/config.json"
chmod 600 "$DIR/device.json"
# retire an older hand-made setup, if any
pkill -f 'deskflow-fx/(charge-watch|edgeflow-helper)' 2>/dev/null
rm -f ~/.config/autostart/deskflow-fx-charge.desktop ~/.config/autostart/edgeflow-helper.desktop \
      ~/.config/autostart/org.deskflow.deskflow.desktop
cat > ~/.config/autostart/edgeflow.desktop <<EOF
[Desktop Entry]
Type=Application
Name=Edgeflow
Exec=$DIR/edgeflow-helper.py
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF
ok "Edgeflow helper"; report 3 ok

# 4. certificates: this computer's own (made by the Mac) and the Mac's, trusted up front
mkdir -p "$CONF_DIR/tls"
j "['pem']" > "$CONF_DIR/tls/deskflow.pem"
chmod 600 "$CONF_DIR/tls/deskflow.pem"
echo "v2:sha256:$SFP" > "$CONF_DIR/tls/trusted-servers"
cat > "$CONF_DIR/Deskflow.conf" <<EOF
[client]
remoteHost=$SERVER

[core]
coreMode=1
computerName=$SCREEN
enableEnterCommand=true
enterCommand="flatpak-spawn --host $DIR/edge-fx.py"
enableExitCommand=true
exitCommand="flatpak-spawn --host rm -f $HOME/.cache/edgeflow/active"

[security]
tlsEnabled=true
checkPeerFingerprints=true

[log]
toFile=true
level=Info
file=$LOG

[gui]
enableUpdateCheck=false
EOF
ok "TLS"; report 4 ok

# 5. key mapping (screenshot shortcuts, input-method switch key)
"$DIR/edgeflow-helper.py" --apply-keys >/dev/null 2>&1 || true
ok "keys"; report 5 ok

# 6. start everything and wait for the Mac to see us
pkill -x deskflow 2>/dev/null; pkill -x deskflow-core 2>/dev/null
systemctl --user stop edgeflow-helper 2>/dev/null
for p in $(pgrep -f "$DIR/edgeflow-helper.py"); do kill "$p" 2>/dev/null; done
: > "$LOG" 2>/dev/null
# Run as its own user service: closing this terminal ends everything started from it,
# even with setsid (GNOME Terminal tabs are systemd scopes). Login starts it via autostart.
if need systemd-run; then
  set -- --user --collect --unit=edgeflow-helper
  for v in DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS XDG_RUNTIME_DIR XDG_SESSION_TYPE XDG_CURRENT_DESKTOP; do
    eval "val=\${$v:-}"; [ -n "$val" ] && set -- "$@" "--setenv=$v=$val"
  done
  systemd-run "$@" "$DIR/edgeflow-helper.py" >/dev/null 2>&1 || setsid "$DIR/edgeflow-helper.py" >/dev/null 2>&1 < /dev/null &
else
  setsid "$DIR/edgeflow-helper.py" >/dev/null 2>&1 < /dev/null &
fi
for _ in $(seq 1 60); do
  # Deskflow writes "connected to server" only at debug level; at info it's the TLS line
  if grep -q -E "connected to (server|secure socket)" "$LOG" 2>/dev/null; then
    ok "$SCREEN ⇄ Mac"; report 6 ok
    printf '\n完成，可以關掉這個視窗。 / Done — you can close this window.\n'
    exit 0
  fi
  sleep 1
done
fail 6 "Deskflow 沒有連上 Mac / Deskflow didn't connect to the Mac"
