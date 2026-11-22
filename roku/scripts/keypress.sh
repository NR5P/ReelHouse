#!/usr/bin/env bash
# Presses remote buttons on a Roku through its External Control Protocol (port 8060, no password).
#
#   scripts/keypress.sh <roku-ip> <key> [key...]
#   scripts/keypress.sh 192.168.1.40 Down Down Select
#   scripts/keypress.sh 192.168.1.40 --text "192.168.1.20"   # types into an on-screen keyboard
#   scripts/keypress.sh 192.168.1.40 devmode                 # the developer-mode sequence
#   scripts/keypress.sh 192.168.1.40 launch                  # starts the sideloaded channel
#
# Keys: Home Rev Fwd Play Select Left Right Down Up Back InstantReplay Info Backspace Search Enter
#       (case as written; "Info" is the * Options button). KEY_DELAY=0.5 changes the pause
#       between presses (seconds, default 0.35).
set -euo pipefail

[[ $# -ge 2 ]] || { sed -n '2,13p' "$0"; exit 2; }
IP="$1"; shift
DELAY="${KEY_DELAY:-0.35}"
command -v curl >/dev/null || { echo "keypress.sh: needs curl" >&2; exit 1; }

post() {
    local path="$1"
    local code
    code="$(curl -s -m 5 -o /dev/null -w '%{http_code}' -X POST "http://$IP:8060/$path" || true)"
    case "$code" in
        200|202|204) ;;
        000) echo "keypress.sh: nothing answered at $IP:8060 - is that the Roku's address?" >&2; exit 1 ;;
        403) echo "keypress.sh: ECP refused POST /$path - set Settings > System > Advanced system settings > Control by mobile apps > Network access to Default or Permissive." >&2 ;;
        *) echo "keypress.sh: POST /$path answered HTTP $code" >&2 ;;
    esac
    return 0
}

press() {
    echo "  $1"
    post "keypress/$1"
    sleep "$DELAY"
}

# One character as the Lit_ key ECP expects, percent-encoded as UTF-8.
literal() {
    local ch="$1"
    local encoded
    encoded="$(printf '%s' "$ch" | od -An -tx1 | tr -d ' \n' | sed 's/\(..\)/%\1/g')"
    post "keypress/Lit_$encoded"
    sleep 0.08
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --text)
            [[ $# -ge 2 ]] || { echo "keypress.sh: --text needs a value" >&2; exit 2; }
            text="$2"; shift 2
            echo "  typing \"$text\""
            for ((i = 0; i < ${#text}; i++)); do literal "${text:$i:1}"; done
            ;;
        devmode)
            shift
            for k in Home Home Home Up Up Right Left Right Left Right; do press "$k"; done
            ;;
        launch)
            shift
            echo "  launch dev channel"
            post "launch/dev"
            ;;
        *)
            press "$1"; shift
            ;;
    esac
done
