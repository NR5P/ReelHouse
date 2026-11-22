#!/usr/bin/env bash
# Installs the channel on a Roku in developer mode (replacing the sideloaded channel already
# there, if any) and launches it.
#
#   scripts/sideload.sh <roku-ip> <dev-password> [zip]
#   ROKU_DEV_PASSWORD=... scripts/sideload.sh <roku-ip>
#
# <dev-password> is the one you chose when enabling developer mode (the user name is always
# "rokudev"). [zip] defaults to out/reelhouse-roku.zip, which is built first if it is missing or
# older than any source file. The password is passed to curl on stdin, not the command line, so
# it doesn't show up in `ps`.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { sed -n '2,12p' "$0"; exit 2; }
[[ $# -ge 1 ]] || usage
IP="$1"
PASS="${2:-${ROKU_DEV_PASSWORD:-}}"
ZIP="${3:-$ROOT/out/reelhouse-roku.zip}"
[[ -n "$PASS" ]] || { echo "sideload.sh: no developer password (argument 2 or ROKU_DEV_PASSWORD)" >&2; exit 2; }
command -v curl >/dev/null || { echo "sideload.sh: needs curl" >&2; exit 1; }

# Rebuild when the zip is missing or stale (default zip only).
if [[ "$ZIP" == "$ROOT/out/reelhouse-roku.zip" ]]; then
    if [[ ! -f "$ZIP" ]] || [[ -n "$(find "$ROOT/manifest" "$ROOT/source" "$ROOT/components" "$ROOT/images" -newer "$ZIP" -print -quit)" ]]; then
        "$ROOT/scripts/package.sh"
    fi
fi
[[ -f "$ZIP" ]] || { echo "sideload.sh: no package at $ZIP" >&2; exit 1; }

echo "Checking $IP is a Roku with developer mode on..."
if ! curl -s -m 5 -o /dev/null "http://$IP:8060/query/device-info"; then
    echo "sideload.sh: nothing answered ECP at http://$IP:8060 - is that the Roku's address (Settings > Network > About)?" >&2
    exit 1
fi
code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' "http://$IP/" || true)"
if [[ "$code" == "000" ]]; then
    echo "sideload.sh: the Roku's developer web server (port 80) isn't answering. Enable developer mode: Home x3, Up x2, Right, Left, Right, Left, Right." >&2
    exit 1
fi

echo "Uploading $(basename "$ZIP") to $IP..."
# curl's config syntax: backslashes and double quotes escaped inside the quoted value.
PASS_ESCAPED="$(printf '%s' "$PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')"
response="$(printf 'user = "rokudev:%s"\n' "$PASS_ESCAPED" | curl -sS -m 120 --digest -K - \
    -w '\nHTTP_STATUS:%{http_code}' \
    --form-string "mysubmit=Install" \
    -F "archive=@$ZIP;type=application/zip" \
    "http://$IP/plugin_install")"
status="${response##*HTTP_STATUS:}"
body="${response%HTTP_STATUS:*}"

if [[ "$status" == "401" ]]; then
    echo "sideload.sh: the Roku refused the password (user rokudev)." >&2
    exit 1
fi
# The installer answers with an HTML page; its message is in a JSON blob or a <font> tag
# depending on firmware.
messages="$(echo "$body" | grep -oE '"text":"[^"]*"' | sed 's/"text":"//; s/"$//' || true)"
[[ -n "$messages" ]] || messages="$(echo "$body" | grep -oE '<font color="red">[^<]*' | sed 's/<font color="red">//' || true)"
echo "${messages:-"(no message from the installer, HTTP $status)"}"

if echo "$messages" | grep -qiE 'Install Success|Identical to previous version|Application Received'; then
    if echo "$messages" | grep -qi 'Identical'; then
        # Nothing was reinstalled, so it isn't relaunched either: launch the dev channel.
        curl -s -m 5 -X POST "http://$IP:8060/launch/dev" >/dev/null || true
    fi
    echo "Installed. Debug console: telnet $IP 8085"
    exit 0
fi
echo "sideload.sh: install failed (HTTP $status)." >&2
exit 1
