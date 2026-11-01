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
trap 'ab close >/dev/null 2>&1; AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-prof" ab close >/dev/null 2>&1; rm -rf "$HOME/.agent-browser/downloads/$AGENT_BROWSER_SESSION"' EXIT

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

# --- watch window -------------------------------------------------------
winfo() { # on-screen window count owned by this session's helper
  swift - "$1" <<'SW' 2>/dev/null
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
print(l.filter {
    guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid, ($0[kCGWindowLayer as String] as? Int) == 0,
          let b = $0[kCGWindowBounds as String] as? [String: Any], let x = b["X"] as? Double, let y = b["Y"] as? Double
    else { return false }
    return x > -5000 && y > -5000   // the windowless helper parks its window at (-30000,-30000)
}.count)
SW
}
HPID=$(pgrep -f "agent-browser --session $AGENT_BROWSER_SESSION daemon")
R=$(ab watch status);                             check "watch off by default" '.ok and .result.watching==false' "$R"
[ "$(winfo $HPID)" = "0" ] && { PASS=$((PASS+1)); echo "ok   - no on-screen window while windowless"; } || { FAIL=$((FAIL+1)); echo "FAIL - window visible while windowless"; }
R=$(ab watch on);                                 check "watch on" '.ok and .result.watching==true' "$R"
[ "$(winfo $HPID)" = "1" ] && { PASS=$((PASS+1)); echo "ok   - watch window is on screen"; } || { FAIL=$((FAIL+1)); echo "FAIL - watch window not on screen"; }
ab open "file://$FIX/search.html" >/dev/null
T=$(ab snapshot | jq -r .result.tree); G=$(ref "$T" 'button "Do nothing"')
R=$(ab click "$G");                               check "highlight does not pollute outcome (no-op stays no-op)" '.ok and .result.outcome=="no-op"' "$R"
R=$(ab watch pause);                              check "watch pause" '.ok and .result.paused==true' "$R"
( ab click "$G" > "${TMPDIR:-/tmp}/ab-paused-$$.json" ) &
BG=$!; sleep 1
kill -0 $BG 2>/dev/null && { PASS=$((PASS+1)); echo "ok   - agent command waits while paused"; } || { FAIL=$((FAIL+1)); echo "FAIL - command did not wait"; }
ab watch resume >/dev/null; wait $BG
R=$(cat "${TMPDIR:-/tmp}/ab-paused-$$.json"); rm -f "${TMPDIR:-/tmp}/ab-paused-$$.json"
check "command completes after resume and reports the wait" '.ok and ([.events[].type]|index("waiting-for-human")!=null)' "$R"
ab watch off >/dev/null
[ "$(winfo $HPID)" = "0" ] && { PASS=$((PASS+1)); echo "ok   - watch off hides the window again"; } || { FAIL=$((FAIL+1)); echo "FAIL - window still visible"; }

# --- wait timeout, screenshot, headless ---------------------------------
R=$(ab wait --selector "#does-not-exist" --timeout 600); check "wait timeout is an error" '.ok==false and .error.code=="TIMEOUT"' "$R"
SHOT="${TMPDIR:-/tmp}/ab-itest-$$.png"
R=$(ab screenshot "$SHOT");                       check "screenshot written" '.ok and .result.width>0' "$R"
[ -s "$SHOT" ] && { PASS=$((PASS+1)); echo "ok   - png file exists"; } || { FAIL=$((FAIL+1)); echo "FAIL - png missing"; }
rm -f "$SHOT"

# --- tabs ----------------------------------------------------------------
ab open "file://$FIX/tabs.html" >/dev/null
T=$(ab snapshot | jq -r .result.tree); LINK=$(ref "$T" 'Open in new tab'); POP=$(ref "$T" 'Pop up')
R=$(ab click "$LINK");                            check "target=_blank opens a new current tab" '.ok and (.result.outcome|test("^opened tab t2 \\(now current\\): done.html"))' "$R"
ab wait --text "Hello bob" --timeout 4000 >/dev/null
R=$(ab tabs);                                     check "tabs lists two, t2 active" '(.result.tabs|length==2) and (.result.tabs|map(select(.active))[0].id=="t2")' "$R"
R=$(ab click "$LINK");                            check "ref from tab t1's snapshot is STALE_REF in t2" '.ok==false and .error.code=="STALE_REF"' "$R"
R=$(ab tab switch t1);                            check "tab switch" '.ok and .result.current=="t1"' "$R"
T=$(ab snapshot | jq -r .result.tree); POP=$(ref "$T" 'Pop up')
echo "$T" | grep -q 'Tabs home' && { PASS=$((PASS+1)); echo "ok   - t1 still shows its own page"; } || { FAIL=$((FAIL+1)); echo "FAIL - t1 content"; }
R=$(ab click "$POP");                             check "window.open opens tab t3" '.ok and (.result.outcome|test("opened tab t3"))' "$R"
R=$(ab tab close t3);                             check "close current tab falls back to another" '.ok and .result.closed=="t3"' "$R"
R=$(ab tab switch t9);                            check "unknown tab -> NO_SUCH_TAB" '.ok==false and .error.code=="NO_SUCH_TAB"' "$R"
ab tab close t2 >/dev/null
R=$(ab tab close);                                check "closing the only tab is refused" '.ok==false and .error.code=="LAST_TAB"' "$R"
R=$(ab tab new "file://$FIX/done.html?user=dave"); check "tab new <url> loads it" '.ok and .result.tab=="t4" and (.result.url|test("dave"))' "$R"
ab tab close >/dev/null

# --- downloads -------------------------------------------------------------
ab open "file://$FIX/download.html" >/dev/null
T=$(ab snapshot | jq -r .result.tree); DL=$(ref "$T" 'Get payload')
R=$(ab click "$DL");                              check "click on download link reports the file as outcome" '.ok and (.result.outcome|test("^download: payload.txt \\(15 bytes\\)"))' "$R"
F=$(echo "$R" | jq -r .result.download.path)
[ "$(cat "$F" 2>/dev/null)" = "hello download" ] && { PASS=$((PASS+1)); echo "ok   - downloaded file content is correct"; } || { FAIL=$((FAIL+1)); echo "FAIL - downloaded file ($F)"; }
R=$(ab open "file://$FIX/blob.bin");              check "open on a non-displayable URL downloads it" '.ok and (.result.outcome|test("^download: blob.bin \\(2048 bytes\\)"))' "$R"
R=$(ab downloads);                                check "downloads lists both as done" '(.result.downloads|length==2) and (.result.downloads|all(.state=="done"))' "$R"
R=$(ab wait --download --timeout 2000);           check "wait --download returns when done" '.ok' "$R"

# --- uploads -----------------------------------------------------------------
UP="${TMPDIR:-/tmp}/ab-up-$$"; mkdir -p "$UP"; printf 'alpha' > "$UP/a.txt"; printf 'beta!' > "$UP/b.txt"
ab open "file://$FIX/upload.html" >/dev/null
T=$(ab snapshot | jq -r .result.tree); FI=$(ref "$T" 'file-input'); PL=$(ref "$T" 'Not a file input')
echo "$T" | grep 'file-input' | grep -q 'hidden' && { PASS=$((PASS+1)); echo "ok   - hidden file input is listed and marked hidden"; } || { FAIL=$((FAIL+1)); echo "FAIL - file input listing"; echo "$T"; }
R=$(ab upload "$FI" "$UP/a.txt" "$UP/b.txt");     check "upload sets multiple files" '.ok and (.result.files==["a.txt","b.txt"])' "$R"
ab snapshot --text | grep -q 'got a.txt:5:alpha | b.txt:5:beta!' && { PASS=$((PASS+1)); echo "ok   - page received the file contents"; } || { FAIL=$((FAIL+1)); echo "FAIL - page did not receive files"; }
T=$(ab snapshot | jq -r .result.tree); FI=$(ref "$T" 'file-input'); PL=$(ref "$T" 'Not a file input')
R=$(ab upload "$PL" "$UP/a.txt");                 check "upload to a non-file element -> NOT_FILE_INPUT" '.ok==false and .error.code=="NOT_FILE_INPUT"' "$R"
R=$(ab upload "$FI" "$UP/missing.txt");           check "missing file -> FILE_NOT_FOUND" '.ok==false and .error.code=="FILE_NOT_FOUND"' "$R"
rm -rf "$UP"

# --- cookies, storage, profiles -----------------------------------------------
CK="${TMPDIR:-/tmp}/ab-cookies-$$.json"
cat > "$CK" <<'JSON'
[{"name":"sid","value":"abc123","domain":"example.com","path":"/","secure":true,"httpOnly":true,"expires":4102444800}]
JSON
R=$(ab cookies import "$CK");                     check "cookies import" '.ok and .result.imported==1' "$R"
R=$(ab cookies export);                           check "cookies export returns it" '.result.cookies|map(select(.name=="sid" and .value=="abc123" and .httpOnly==true))|length==1' "$R"
ab cookies export "$CK.out" >/dev/null
[ "$(stat -f %Lp "$CK.out")" = "600" ] && { PASS=$((PASS+1)); echo "ok   - exported cookie file is owner-only (0600)"; } || { FAIL=$((FAIL+1)); echo "FAIL - cookie file permissions"; }
R=$(ab cookies clear);                            check "cookies clear" '.ok and .result.cleared>=1' "$R"
R=$(ab cookies export);                           check "cookies empty after clear" '.result.count==0' "$R"
R=$(ab open https://example.com 2>/dev/null)
if echo "$R" | jq -e '.ok' >/dev/null 2>&1; then
  printf '{"origin":"https://example.com","local":{"k":"v"},"session":{}}' > "$CK"
  R=$(ab storage import "$CK");                   check "storage import" '.ok and .result.imported_local==1' "$R"
  R=$(ab storage export);                         check "storage export has the item" '.result.local.k=="v"' "$R"
  printf '{"origin":"https://other.test","local":{}}' > "$CK"
  R=$(ab storage import "$CK");                   check "storage import for another origin refused" '.ok==false and .error.code=="ORIGIN_MISMATCH"' "$R"
else echo "skip - storage tests (no network)"; fi
rm -f "$CK" "$CK.out"

PS="$AGENT_BROWSER_SESSION-prof"; PN="itest$$"
pab() { AGENT_BROWSER_SESSION="$PS" "$BIN" --profile "$PN" "$@"; }
R=$(pab status);                                  check "status shows persistent profile" ".ok and .result.profile==\"$PN\" and .result.persistent==true" "$R"
R=$("$BIN" --session "$PS" --profile other status); check "different profile on a running session is refused" '.ok==false and .error.code=="PROFILE_MISMATCH"' "$R"
cat > "$HOME/.ab-itest-cookie.json" <<'JSON'
[{"name":"keep","value":"me","domain":"example.org","path":"/","expires":4102444800}]
JSON
pab cookies import "$HOME/.ab-itest-cookie.json" >/dev/null; rm -f "$HOME/.ab-itest-cookie.json"
pab close >/dev/null; sleep 2
R=$(pab cookies export);                          check "cookie survives helper restart with the same profile" '.result.cookies|map(select(.name=="keep"))|length==1' "$R"
pab cookies clear >/dev/null; pab close >/dev/null; sleep 1.5
R=$(AGENT_BROWSER_SESSION="$PS" "$BIN" cookies export); check "a temporary session does not see the profile's cookies" '.result.count==0' "$R"
AGENT_BROWSER_SESSION="$PS" "$BIN" close >/dev/null

# --- MCP server over stdio ----------------------------------------------
rpc() { "$BIN" mcp; }
call() { echo "{\"jsonrpc\":\"2.0\",\"id\":$1,\"method\":\"tools/call\",\"params\":{\"name\":\"$2\",\"arguments\":$3}}"; }
OUT=$( { echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}'
  echo '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  call 3 browser_open "{\"url\":\"file://$FIX/modal.html\"}"
  call 4 browser_snapshot '{}'; } | rpc)
line() { echo "$OUT" | jq -c "select(.id==$1)"; }
check "mcp initialize returns tools capability and instructions" '.result.capabilities.tools and (.result.instructions|length>50)' "$(line 1)"
check "mcp tools/list has all 16 tools" '.result.tools|length==16' "$(line 2)"
check "mcp browser_open ok" '.result.isError==false' "$(line 3)"
check "mcp snapshot is plain text tree with refs" '.result.content[0].text|test("snapshot s[0-9]+") and test("@s[0-9]+:e1")' "$(line 4)"
MBUY=$(line 4 | jq -r '.result.content[0].text' | grep 'Buy now' | grep -oE '@s[0-9]+:e[0-9]+')
OUT=$( { call 5 browser_click "{\"ref\":\"$MBUY\"}"
  call 6 browser_click '{"ref":"@s9999:e1"}'
  call 7 browser_screenshot '{}'
  call 8 browser_tabs '{}'
  echo '{"jsonrpc":"2.0","id":9,"method":"nope"}'; } | rpc)
check "mcp covered click is isError and names the cover" '.result.isError==true and (.result.content[0].text|test("ELEMENT_COVERED"))' "$(line 5)"
check "mcp stale ref is isError STALE_REF" '.result.isError==true and (.result.content[0].text|test("STALE_REF"))' "$(line 6)"
check "mcp screenshot returns an image" '.result.content[0].type=="image" and (.result.content[0].data|length>1000)' "$(line 7)"
check "mcp browser_tabs works" '.result.isError==false and (.result.content[0].text|test("t1"))' "$(line 8)"
check "mcp unknown method -> JSON-RPC error" '.error.code==-32601' "$(line 9)"

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
