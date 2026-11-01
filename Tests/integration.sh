#!/bin/bash
# Integration tests: drives the real helper against local file:// fixtures.
# Usage: Tests/integration.sh [path-to-binary]
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${1:-$HERE/../.build/debug/agent-browser}"
FIX="$HERE/fixtures"
export AGENT_BROWSER_SESSION="itest-$$"
PASS=0; FAIL=0

ab() { "$BIN" "$@"; }
check() { # name, jq-filter, json
  if echo "$3" | jq -e "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "       $3" | cut -c1-600; fi
}
ref() { # tree, regex -> first ref on a line matching regex
  echo "$1" | grep -E "$2" | head -1 | grep -oE '@s[0-9]+:e[0-9]+' | head -1
}
trap 'ab close >/dev/null 2>&1' EXIT

# --- login flow --------------------------------------------------------
R=$(ab open "file://$FIX/login.html");           check "open login" '.ok and .result.title=="Login"' "$R"
T=$(ab snapshot | jq -r .result.tree)
U=$(ref "$T" 'Username'); P=$(ref "$T" 'Password'); B=$(ref "$T" 'button "Log in"')
[ -n "$U" ] && [ -n "$P" ] && [ -n "$B" ] && { PASS=$((PASS+1)); echo "ok   - snapshot exposes refs ($U $P $B)"; } || { FAIL=$((FAIL+1)); echo "FAIL - refs missing"; echo "$T"; }
R=$(ab submit "$B");                              check "validation blocks empty submit" '.ok==false and .error.code=="VALIDATION_FAILED"' "$R"
R=$(ab fill "$U" alice);                          check "fill username" '.ok and (.result.value=="alice")' "$R"
R=$(ab fill "$P" 's3cret');                       check "fill password masked" '.ok and (.result.value|test("^•+$"))' "$R"
R=$(ab click "$B");                               check "click submits and navigates" '.ok and (.result.outcome|test("^navigated: done.html\\?user=alice"))' "$R"
check "events include load" '[.events[].type]|index("load")!=null' "$R"
ab wait --text "Hello alice" --timeout 3000 | jq -e '.ok' >/dev/null && { PASS=$((PASS+1)); echo "ok   - confirm result via wait --text"; } || { FAIL=$((FAIL+1)); echo "FAIL - wait --text"; }
R=$(ab click "$B");                               check "old ref after navigation -> STALE_REF" '.ok==false and .error.code=="STALE_REF" and .error.retry_safe==true' "$R"

# --- covered / hidden / stale ------------------------------------------
ab open "file://$FIX/modal.html" >/dev/null
T=$(ab snapshot | jq -r .result.tree)
BUY=$(ref "$T" 'Buy now'); ACC=$(ref "$T" 'Accept cookies'); VAN=$(ref "$T" 'Hide the other'); EPH=$(ref "$T" 'Ephemeral')
echo "$T" | grep -q 'covered by' && { PASS=$((PASS+1)); echo "ok   - snapshot flags covered element"; } || { FAIL=$((FAIL+1)); echo "FAIL - snapshot did not flag covered"; echo "$T"; }
R=$(ab click "$BUY");                             check "covered click fails naming the cover" '.ok==false and .error.code=="ELEMENT_COVERED" and (.error.covered_by|test("overlay|consent|banner"))' "$R"
R=$(ab click "$ACC");                             check "accept consent banner" '.ok and .result.outcome=="dom-changed"' "$R"
R=$(ab click "$BUY");                             check "old snapshot ref after DOM change still valid" '.ok or .error.code=="STALE_REF"' "$R"
T=$(ab snapshot | jq -r .result.tree)
BUY=$(ref "$T" 'Buy now'); VAN=$(ref "$T" 'Hide the other'); EPH=$(ref "$T" 'Ephemeral')
R=$(ab click "$BUY");                             check "click after banner gone works" '.ok and .result.outcome=="dom-changed"' "$R"
ab click "$VAN" >/dev/null
R=$(ab click "$EPH");                             check "hidden target -> ELEMENT_HIDDEN" '.ok==false and .error.code=="ELEMENT_HIDDEN"' "$R"
R=$(ab click "@s999:e1");                         check "ref from unknown snapshot -> STALE_REF" '.ok==false and .error.code=="STALE_REF"' "$R"
R=$(ab click "garbage");                          check "malformed ref -> BAD_REF" '.ok==false and .error.code=="BAD_REF"' "$R"

# --- search, dialog, console -------------------------------------------
R=$(ab open "file://$FIX/search.html");           check "console error captured on load" '[.events[]|select(.type=="console-error")]|length>=1' "$R"
T=$(ab snapshot | jq -r .result.tree)
Q=$(ref "$T" 'searchbox'); G=$(ref "$T" 'button "Search"'); AL=$(ref "$T" 'button "Alert"')
ab fill "$Q" ap >/dev/null; ab click "$G" >/dev/null
T=$(ab snapshot | jq -r .result.tree)
echo "$T" | grep -q 'Result: apple' && echo "$T" | grep -q 'Result: apricot' && ! echo "$T" | grep -q banana \
  && { PASS=$((PASS+1)); echo "ok   - search results rendered and filtered"; } || { FAIL=$((FAIL+1)); echo "FAIL - search results"; echo "$T"; }
AL=$(ref "$T" 'button "Alert"')
R=$(ab click "$AL");                              check "dialog reported as outcome" '.ok and (.result.outcome=="dialog: alert(\"hello there\")")' "$R"

# --- wait timeout, screenshot, headless ---------------------------------
R=$(ab wait --selector "#does-not-exist" --timeout 600); check "wait timeout is an error" '.ok==false and .error.code=="TIMEOUT"' "$R"
SHOT="${TMPDIR:-/tmp}/ab-itest-$$.png"
R=$(ab screenshot "$SHOT");                       check "screenshot written" '.ok and .result.width>0' "$R"
[ -s "$SHOT" ] && { PASS=$((PASS+1)); echo "ok   - png file exists"; } || { FAIL=$((FAIL+1)); echo "FAIL - png missing"; }
rm -f "$SHOT"

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
