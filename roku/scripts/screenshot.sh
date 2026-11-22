#!/usr/bin/env bash
# Saves a screenshot of the sideloaded channel, through the Roku's developer web UI (the
# "Utilities > Screenshot" button). Only works while the dev channel is running.
#
#   scripts/screenshot.sh <roku-ip> <dev-password> <out.png|out.jpg>
#   ROKU_DEV_PASSWORD=... scripts/screenshot.sh <roku-ip> "" shot.png
#
# The Roku saves a JPEG (older firmware) or PNG and reports its path (pkgs/dev.jpg / dev.png);
# this fetches that file. If its format differs from the extension asked for, it is converted
# with `sips` (macOS) or ImageMagick when either is installed, else saved under the right
# extension instead.
set -euo pipefail

[[ $# -ge 3 ]] || { sed -n '2,12p' "$0"; exit 2; }
IP="$1"
PASS="${2:-${ROKU_DEV_PASSWORD:-}}"
OUT="$3"
[[ -n "$PASS" ]] || { echo "screenshot.sh: no developer password (argument 2 or ROKU_DEV_PASSWORD)" >&2; exit 2; }
command -v curl >/dev/null || { echo "screenshot.sh: needs curl" >&2; exit 1; }

# curl's config syntax: backslashes and double quotes escaped inside the quoted value. Keeps the
# password off curl's command line.
PASS_ESCAPED="$(printf '%s' "$PASS" | sed 's/\\/\\\\/g; s/"/\\"/g')"
auth() { printf 'user = "rokudev:%s"\n' "$PASS_ESCAPED"; }

page="$(auth | curl -sS -m 30 --digest -K - \
    --form-string "mysubmit=Screenshot" \
    --form-string "archive=" \
    --form-string "passwd=" \
    "http://$IP/plugin_inspect")" || { echo "screenshot.sh: couldn't reach http://$IP/plugin_inspect" >&2; exit 1; }

if echo "$page" | grep -qi '401 Unauthorized'; then
    echo "screenshot.sh: the Roku refused the password (user rokudev)." >&2
    exit 1
fi
path="$(echo "$page" | grep -oE 'pkgs/dev\.(jpg|png)(\?time=[0-9]+)?' | head -n 1 || true)"
if [[ -z "$path" ]]; then
    echo "screenshot.sh: the Roku didn't report a screenshot. Is the sideloaded channel running?" >&2
    exit 1
fi
remote_ext="${path#pkgs/dev.}"; remote_ext="${remote_ext%%\?*}"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
tmp="$tmpdir/shot.$remote_ext"
auth | curl -sS -m 30 --digest -K - -o "$tmp" "http://$IP/$path"
[[ -s "$tmp" ]] || { echo "screenshot.sh: the screenshot download was empty" >&2; exit 1; }

want_ext="$(echo "${OUT##*.}" | tr '[:upper:]' '[:lower:]')"
[[ "$want_ext" == "jpeg" ]] && want_ext="jpg"
mkdir -p "$(dirname "$OUT")"
if [[ "$want_ext" == "$remote_ext" ]]; then
    cp "$tmp" "$OUT"
elif command -v sips >/dev/null; then
    format="png"; [[ "$want_ext" == "jpg" ]] && format="jpeg"
    sips -s format "$format" "$tmp" --out "$OUT" >/dev/null
elif command -v magick >/dev/null; then
    magick "$tmp" "$OUT"
elif command -v convert >/dev/null; then
    convert "$tmp" "$OUT"
else
    OUT="${OUT%.*}.$remote_ext"
    cp "$tmp" "$OUT"
    echo "screenshot.sh: no converter found; saved the Roku's $remote_ext as is" >&2
fi
echo "Saved $OUT"
