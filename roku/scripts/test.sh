#!/usr/bin/env bash
# Runs tests/run_tests.brs - the channel's pure helpers (address parsing, URL building, cookie
# handling, JSON-to-tile mapping, Home's rows) - under the brs BrightScript interpreter, off the
# device. Needs Node.js (npx fetches brs).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
command -v npx >/dev/null || { echo "test.sh: needs Node.js (npx) on the PATH" >&2; exit 1; }

output="$(npx -y brs components/lib/Util.brs components/lib/Mappers.brs tests/run_tests.brs 2>&1 | grep -v 'npm notice\|npm warn')"
echo "$output"
echo "$output" | tail -n 1 | grep -q '^ALL PASSED$'
