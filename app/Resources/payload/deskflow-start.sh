#!/bin/sh
# Starts the Deskflow client (no window) pointed at the Mac. The Mac is looked up by its
# mDNS name on the host — the Flatpak sandbox can't resolve .local names — so a new
# DHCP address is picked up; the last known IP is the fallback.
DIR="$HOME/.local/share/edgeflow"
CONF="$HOME/.var/app/org.deskflow.deskflow/config/Deskflow/Deskflow.conf"
HOST=$(python3 -c "import json; print(json.load(open('$DIR/device.json'))['serverHost'])" 2>/dev/null)
IP=""
[ -n "$HOST" ] && IP=$(getent ahostsv4 "$HOST" 2>/dev/null | awk 'NR==1 {print $1}')
[ -n "$IP" ] && sed -i "s/^remoteHost=.*/remoteHost=$IP/" "$CONF"
exec /usr/bin/flatpak run --command=deskflow-core org.deskflow.deskflow client
