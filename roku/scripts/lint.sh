#!/usr/bin/env bash
# Static checks with the BrighterScript compiler (it validates plain BrightScript and SceneGraph
# XML too): syntax, unknown functions, wrong argument counts, missing onChange/observer
# callbacks, script includes that don't exist. Needs Node.js (npx fetches brighterscript).
#
#   scripts/lint.sh          # brighterscript 0.x (the stable compiler)
#   scripts/lint.sh --next   # also the stricter 1.0 pre-release
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
command -v npx >/dev/null || { echo "lint.sh: needs Node.js (npx) on the PATH" >&2; exit 1; }

run() {
    local pkg="$1"
    echo "== $pkg"
    local log
    log="$(npx -y -p "$pkg" bsc --project bsconfig.json --create-package false 2>&1 | grep -v 'npm notice\|npm warn' || true)"
    echo "$log" | grep -E ' - (error|warning) ' || true
    if echo "$log" | grep -qE ' - error '; then
        echo "lint.sh: $pkg found errors" >&2
        return 1
    fi
    echo "   no errors"
}

run brighterscript
if [[ "${1:-}" == "--next" ]]; then
    run brighterscript@next
fi
rm -rf "$ROOT/out/staging"
