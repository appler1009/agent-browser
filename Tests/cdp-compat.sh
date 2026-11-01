#!/bin/bash
# Opt-in: drives the CDP shim with real Puppeteer and Playwright (installs them into a temp dir; needs npm + network).
# Usage: Tests/cdp-compat.sh [path-to-binary]
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${1:-$HERE/../.build/debug/agent-browser}"
export AGENT_BROWSER_SESSION="cdpcompat-$$"
WORK="$(mktemp -d)"
trap '"$BIN" close >/dev/null 2>&1; rm -rf "$WORK"' EXIT
cp "$HERE"/cdp/puppeteer.mjs "$HERE"/cdp/playwright.mjs "$WORK"/
(cd "$WORK" && npm init -y >/dev/null && npm install --ignore-scripts --no-audit --no-fund puppeteer-core@24 playwright-core@1 >/dev/null 2>&1)
WS=$("$BIN" cdp start | jq -r .result.ws)
FIX="$HERE/fixtures"
rc=0
for t in puppeteer playwright; do
  echo "== $t"
  if (cd "$WORK" && timeout 120 node "$t.mjs" "$WS" "$FIX") | tee /dev/stderr | grep -q '^DONE'; then echo "ok   - $t"; else echo "FAIL - $t"; rc=1; fi
done
exit $rc
