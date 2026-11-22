#!/usr/bin/env bash
# Finds Rokus on this network with SSDP (M-SEARCH, ST: roku:ecp) and prints each one's ECP
# address, name, model and whether developer mode is on.
#
#   scripts/discover.sh              # listen for 3 seconds
#   scripts/discover.sh 6            # listen longer
#
# Needs python3 (for the UDP multicast) and curl (for the device details).
set -euo pipefail

WAIT="${1:-3}"
command -v python3 >/dev/null || { echo "discover.sh: needs python3" >&2; exit 1; }

locations="$(python3 -I - "$WAIT" <<'PY'
import socket, sys, time
wait = float(sys.argv[1])
msg = ("M-SEARCH * HTTP/1.1\r\n"
       "HOST: 239.255.255.250:1900\r\n"
       'MAN: "ssdp:discover"\r\n'
       "ST: roku:ecp\r\n"
       "MX: 2\r\n\r\n").encode()
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM, socket.IPPROTO_UDP)
sock.setsockopt(socket.IPPROTO_IP, socket.IP_MULTICAST_TTL, 2)
sock.settimeout(0.5)
for _ in range(3):  # UDP: say it more than once
    sock.sendto(msg, ("239.255.255.250", 1900))
seen = set()
end = time.time() + wait
while time.time() < end:
    try:
        data, _ = sock.recvfrom(4096)
    except socket.timeout:
        continue
    for line in data.decode(errors="replace").split("\r\n"):
        if line.lower().startswith("location:"):
            loc = line.split(":", 1)[1].strip()
            if loc not in seen:
                seen.add(loc)
                print(loc)
PY
)"

if [[ -z "$locations" ]]; then
    echo "No Rokus answered. Check this computer is on the same network, and that the Roku's"
    echo "Settings > System > Advanced system settings > Control by mobile apps isn't Disabled."
    exit 1
fi

field() { sed -n "s:.*<$1>\(.*\)</$1>.*:\1:p" | head -n 1; }
while read -r loc; do
    [[ -n "$loc" ]] || continue
    host="$(echo "$loc" | sed -E 's#https?://([^:/]+).*#\1#')"
    info="$(curl -s -m 3 "${loc%/}/query/device-info" || true)"
    name="$(echo "$info" | field user-device-name)"
    [[ -n "$name" ]] || name="$(echo "$info" | field friendly-device-name)"
    model="$(echo "$info" | field model-name)"
    dev="$(echo "$info" | field developer-enabled)"
    echo "$loc  ip=$host  name=\"${name:-?}\"  model=\"${model:-?}\"  developer-mode=${dev:-?}"
done <<< "$locations"
