#!/usr/bin/env bash
# Zips the channel into out/reelhouse-roku.zip, ready to sideload (scripts/sideload.sh) or to
# upload by hand at http://<roku-ip>/ (Development Application Installer).
#
#   scripts/package.sh            # zip it
#   scripts/package.sh --lint     # run the BrighterScript validator first; stop on any error
#   scripts/package.sh --out PATH # write the zip somewhere else
#
# Only what a channel package may contain goes in: manifest, source/, components/, images/.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$ROOT/out/reelhouse-roku.zip"
LINT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --lint) LINT=1; shift ;;
        --out) OUT="$2"; shift 2 ;;
        -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
        *) echo "package.sh: unknown option $1" >&2; exit 2 ;;
    esac
done

command -v zip >/dev/null || { echo "package.sh: needs 'zip' on the PATH" >&2; exit 1; }
for required in manifest source/main.brs components/MainScene.xml images/mm_icon_focus_fhd.png images/splash_fhd.png; do
    [[ -e "$ROOT/$required" ]] || { echo "package.sh: missing $required (images: python3 scripts/make_images.py)" >&2; exit 1; }
done

if [[ $LINT -eq 1 ]]; then
    "$ROOT/scripts/lint.sh"
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
cd "$ROOT"
# -X: no extra file attributes; the exclusions keep Finder and editor droppings out.
zip -q -r -9 -X "$OUT" manifest source components images \
    -x '*.DS_Store' -x '*/.*' -x '*~' -x '*.swp'

version="$(awk -F= '/^major_version/{a=$2}/^minor_version/{b=$2}/^build_version/{c=$2}END{print a"."b"."c}' manifest)"
size="$(wc -c < "$OUT" | tr -d ' ')"
echo "Packaged ReelHouse $version -> $OUT ($size bytes)"
