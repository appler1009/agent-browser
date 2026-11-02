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
# macOS runners have no coreutils `timeout`.
command -v timeout >/dev/null 2>&1 || timeout() { local s=$1; shift; perl -e 'alarm shift; exec @ARGV' "$s" "$@"; }
check() { # name, jq-filter, json
  if echo "$3" | jq -e "$2" >/dev/null 2>&1; then PASS=$((PASS+1)); echo "ok   - $1"
  else FAIL=$((FAIL+1)); echo "FAIL - $1"; echo "       $3" | cut -c1-600; fi
}
ref() { # tree, regex -> first ref on a line matching regex
  echo "$1" | grep -E "$2" | head -1 | grep -oE '@s[0-9]+:e[0-9]+' | head -1
}
VT="$(mktemp -d)"
export AGENT_BROWSER_COOKIE_KEY_FILE="$VT/cookie.key"   # test key; the real keychain is never touched
export AGENT_BROWSER_VAULT_FILE="$VT/vault.json"   # test store; the real keychain is never touched
vab() { local o; o=$(AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-vault" "$BIN" "$@"); echo "$o" >> "$VT/all-output.log"; echo "$o"; }
trap 'for x in "" -vault -vok -vno -vcdp; do AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION$x" "$BIN" close >/dev/null 2>&1; done; rm -rf "$VT"; ab close >/dev/null 2>&1; AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-prof" ab close >/dev/null 2>&1; rm -rf "$HOME/.agent-browser/downloads/$AGENT_BROWSER_SESSION" "$HOME/.agent-browser/downloads/$AGENT_BROWSER_SESSION-prof" "$HOME/.agent-browser/profiles/itest$$"; rmdir "$HOME/.agent-browser/profiles" 2>/dev/null' EXIT

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
winfo() { # windows of this helper that a person could see: on a screen and not fully transparent
  swift - "$1" <<'SW' 2>/dev/null
import CoreGraphics
import Foundation
let pid = Int32(CommandLine.arguments[1])!
let l = (CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]) ?? []
print(l.filter {
    guard ($0[kCGWindowOwnerPID as String] as? Int32) == pid, ($0[kCGWindowLayer as String] as? Int) == 0,
          let a = $0[kCGWindowAlpha as String] as? Double else { return false }
    return a > 0   // a hidden helper has no window on screen
}.count)
SW
}
HPID=$(pgrep -f "agent-browser --session $AGENT_BROWSER_SESSION daemon")
R=$(ab watch status);                             check "watch off by default" '.ok and .result.watching==false' "$R"
[ "$(winfo $HPID)" = "0" ] && { PASS=$((PASS+1)); echo "ok   - no window at all while hidden"; } || { FAIL=$((FAIL+1)); echo "FAIL - window visible while windowless"; }
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
ab watch off >/dev/null; sleep 0.7
[ "$(winfo $HPID)" = "0" ] && { PASS=$((PASS+1)); echo "ok   - watch off hides the window again"; } || { FAIL=$((FAIL+1)); echo "FAIL - window still visible"; }

# --- wait timeout, screenshot, headless ---------------------------------
R=$(ab wait --selector "#does-not-exist" --timeout 600); check "wait timeout is an error" '.ok==false and .error.code=="TIMEOUT"' "$R"
SHOT="${TMPDIR:-/tmp}/ab-itest-$$.png"
R=$(ab screenshot "$SHOT");                       check "screenshot written" '.ok and .result.width>0' "$R"
[ -s "$SHOT" ] && { PASS=$((PASS+1)); echo "ok   - png file exists"; } || { FAIL=$((FAIL+1)); echo "FAIL - png missing"; }
rm -f "$SHOT"

# --- rendering keeps running while hidden (no window; pageScript keeps pages live) --------------------------
ab watch off >/dev/null
ab open "file://$FIX/raf.html" >/dev/null; sleep 1
T=$(ab snapshot | jq -r .result.tree)
echo "$T" | grep -q 'state: visible' && { PASS=$((PASS+1)); echo "ok   - hidden page still reports visibilityState=visible"; } || { FAIL=$((FAIL+1)); echo "FAIL - page considered hidden"; echo "$T"; }
FR=$(echo "$T" | grep -oE 'frames: [0-9]+' | grep -oE '[0-9]+')
[ "${FR:-0}" -gt 10 ] && { PASS=$((PASS+1)); echo "ok   - requestAnimationFrame keeps firing while hidden ($FR frames)"; } || { FAIL=$((FAIL+1)); echo "FAIL - rAF stalled (frames=$FR)"; }

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
[{"name":"keep","value":"me","domain":"example.org","path":"/","expires":4102444800},
 {"name":"sess","value":"s3ssion-value-xyz","domain":"example.org","path":"/","secure":true,"httpOnly":true}]
JSON
pab cookies import "$HOME/.ab-itest-cookie.json" >/dev/null; rm -f "$HOME/.ab-itest-cookie.json"
pab close >/dev/null; sleep 2
F0=$FAIL
R=$(pab cookies export);                          check "cookie survives helper restart with the same profile" '.result.cookies|map(select(.name=="keep"))|length==1' "$R"
check "a session cookie (no expiry) also survives the restart" '.result.cookies|map(select(.name=="sess" and .value=="s3ssion-value-xyz" and (has("expires")|not)))|length==1' "$R"
if [ "$FAIL" -gt "$F0" ]; then  # help diagnose runner-specific storage behaviour
  echo "       macOS $(sw_vers -productVersion); recently written WebKit/cookie files:"
  find "$HOME/Library" -type f -mmin -3 \( -iname '*cookie*' -o -path '*WebKit*' -o -path '*HTTPStorages*' \) 2>/dev/null | head -20 | sed 's/^/         /'
fi
PD="$HOME/.agent-browser/profiles/$PN"
[ "$(stat -f %Lp "$PD/cookies.enc" 2>/dev/null)" = "600" ] && [ "$(stat -f %Lp "$PD")" = "700" ] && { PASS=$((PASS+1)); echo "ok   - profile cookie file is owner-only"; } || { FAIL=$((FAIL+1)); echo "FAIL - profile cookie file permissions"; }
head -c 6 "$PD/cookies.enc" | grep -q "^ABCK1" && ! grep -q -e "s3ssion-value-xyz" -e "example.org" -e '"keep"' "$PD/cookies.enc" && [ ! -e "$PD/cookies.json" ] \
  && { PASS=$((PASS+1)); echo "ok   - saved cookies are encrypted (no names, values or domains in the file) and no plain copy exists"; } || { FAIL=$((FAIL+1)); echo "FAIL - cookie file is not encrypted"; }
R=$(pab status);                                  check "status reports the saved, encrypted cookies" '.result.profile_cookies.encrypted==true and (.result.profile_cookies.count>=2) and (.result.profile_cookies|has("error")|not)' "$R"
R=$(ab menubar --dump-menu);                      check "menu model: persistent profile line says kept and encrypted" '[.result.menu[]|select(.children!=null)|.children[].title]|(map(test("kept between runs"))|any) and (map(test("encrypted"))|any)' "$R"
# an earlier version's plain cookies.json is encrypted on first start and then securely removed
pab close >/dev/null; sleep 3.5
cat > "$PD/cookies.json" <<'JSON'
[{"name":"legacy","value":"old-plain","domain":"example.org","path":"/","expires":4102444800}]
JSON
R=$(pab cookies export);                          check "legacy plain cookies.json is loaded" '.result.cookies|map(select(.name=="legacy"))|length==1' "$R"
[ ! -e "$PD/cookies.json" ] && [ -f "$PD/cookies.enc" ] && ! grep -q "old-plain" "$PD/cookies.enc" && { PASS=$((PASS+1)); echo "ok   - legacy plain file migrated to the encrypted file and removed"; } || { FAIL=$((FAIL+1)); echo "FAIL - legacy cookie file migration"; }
# a wrong key must not fall back to plain text or lose the file silently
pab close >/dev/null; sleep 3.5
cp "$VT/cookie.key" "$VT/cookie.key.bak"; head -c 32 /dev/urandom > "$VT/cookie.key"
R=$(AGENT_BROWSER_SESSION="$PS" "$BIN" --profile "$PN" status);  check "a wrong key is reported, not hidden" '.result.profile_cookies.error|test("could not be decrypted")' "$R"
AGENT_BROWSER_SESSION="$PS" "$BIN" close >/dev/null; sleep 3.5; cp "$VT/cookie.key.bak" "$VT/cookie.key"
pab cookies clear >/dev/null; pab close >/dev/null; sleep 1.5
R=$(pab cookies export);                          check "cleared cookies do not come back after a restart" '.result.count==0' "$R"
pab close >/dev/null; sleep 1.5
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
check "mcp tools/list has all 25 tools" '(.result.tools|length)==25 and ([.result.tools[].name]|(index("browser_login")!=null and index("browser_fill_secret")!=null and index("browser_vault_list")!=null))' "$(line 2)"
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

# --- polish: iframes, shadow DOM, blocking, UA/viewport, snapshot budgets ----------
ab open "file://$FIX/iframe.html" >/dev/null; sleep 0.5
T=$(ab snapshot | jq -r .result.tree)
echo "$T" | grep -q 'iframe "inner"' && echo "$T" | grep -q 'textbox "Inner name"' && echo "$T" | grep -q 'button "Inner go"' \
  && { PASS=$((PASS+1)); echo "ok   - same-origin iframe contents appear in the snapshot"; } || { FAIL=$((FAIL+1)); echo "FAIL - iframe contents"; echo "$T"; }
echo "$T" | grep -q 'other origin.*cross-origin: contents not included' && { PASS=$((PASS+1)); echo "ok   - cross-origin iframe is reported, not silently skipped"; } || { FAIL=$((FAIL+1)); echo "FAIL - cross-origin iframe note"; echo "$T"; }
IN=$(ref "$T" 'textbox "Inner name"'); IG=$(ref "$T" 'button "Inner go"')
R=$(ab fill "$IN" hello);                         check "fill inside an iframe" '.ok and .result.value=="hello"' "$R"
R=$(ab click "$IG");                              check "click inside an iframe changes its document (dom-changed)" '.ok and .result.outcome=="dom-changed"' "$R"
ab snapshot --text | grep -q 'inner clicked' && { PASS=$((PASS+1)); echo "ok   - iframe click had its effect"; } || { FAIL=$((FAIL+1)); echo "FAIL - iframe click effect"; }

ab open "file://$FIX/shadow.html" >/dev/null
T=$(ab snapshot | jq -r .result.tree); SG=$(ref "$T" 'button "Shadow go"')
[ -n "$SG" ] && { PASS=$((PASS+1)); echo "ok   - open shadow root content is in the snapshot"; } || { FAIL=$((FAIL+1)); echo "FAIL - shadow content"; echo "$T"; }
R=$(ab click "$SG");                              check "click inside a shadow root reports dom-changed" '.ok and .result.outcome=="dom-changed"' "$R"

ab open "file://$FIX/block.html" >/dev/null; sleep 0.3
ab snapshot --text | grep -q 'img: loaded' && { PASS=$((PASS+1)); echo "ok   - image loads by default"; } || { FAIL=$((FAIL+1)); echo "FAIL - image default"; }
R=$(ab block images);                             check "block images" '.ok and (.result.blocking==["images"])' "$R"
ab open "file://$FIX/block.html" >/dev/null; sleep 0.3
ab snapshot --text | grep -q 'img: blocked' && { PASS=$((PASS+1)); echo "ok   - images are blocked after block images"; } || { FAIL=$((FAIL+1)); echo "FAIL - image not blocked"; }
R=$(ab block clear);                              check "block clear" '.ok and (.result.blocking|length==0)' "$R"
ab open "file://$FIX/block.html" >/dev/null; sleep 0.3
ab snapshot --text | grep -q 'img: loaded' && { PASS=$((PASS+1)); echo "ok   - images load again after block clear"; } || { FAIL=$((FAIL+1)); echo "FAIL - image after clear"; }
R=$(ab block url 'pixel\.png');                   check "block url regex" '.ok and (.result.blocking|length==1)' "$R"
ab open "file://$FIX/block.html" >/dev/null; sleep 0.3
ab snapshot --text | grep -q 'img: blocked' && { PASS=$((PASS+1)); echo "ok   - url rule blocks the matching request"; } || { FAIL=$((FAIL+1)); echo "FAIL - url rule"; }
ab block clear >/dev/null
R=$(ab block nonsense);                           check "block rejects unknown kinds" '.ok==false and .error.code=="USAGE"' "$R"

R=$(ab useragent "custom-bot/9.9");               check "useragent set" '.ok and .result.custom==true' "$R"
ab open "file://$FIX/ua.html" >/dev/null
ab snapshot --text | grep -q 'ua: custom-bot/9.9' && { PASS=$((PASS+1)); echo "ok   - page sees the custom user agent"; } || { FAIL=$((FAIL+1)); echo "FAIL - page UA"; }
ab useragent reset >/dev/null
R=$(ab viewport 600 400);                         check "viewport set" '.ok and .result.width==600 and .result.height==400' "$R"
ab open "file://$FIX/ua.html" >/dev/null
ab snapshot --text | grep -q 'size: 600x400' && { PASS=$((PASS+1)); echo "ok   - page sees the 600x400 viewport"; } || { FAIL=$((FAIL+1)); echo "FAIL - page viewport"; }
R=$(ab viewport 50 50);                           check "viewport rejects tiny sizes" '.ok==false and .error.code=="USAGE"' "$R"
ab viewport 1280 800 >/dev/null

ab open "file://$FIX/big.html" >/dev/null
R=$(ab snapshot);                                 check "huge page: capped at 1500 nodes, truncated flag, reports ms and size" '.result.truncated==true and (.result.ms|type=="number") and .result.approx_tokens>1000' "$R"
R=$(ab snapshot --max-chars 2000);                check "--max-chars budget is respected" '.result.truncated==true and .result.chars<=2000' "$R"
R=$(ab snapshot --interactive --max-nodes 50);    check "--interactive lists only actionable elements" '(.result.tree|contains("text \"")|not) and .result.refs==50' "$R"
R=$(ab snapshot --selector '#only');              check "--selector scopes to a subtree" '.result.refs==1 and (.result.tree|contains("Only one"))' "$R"
R=$(ab snapshot --selector '#nope');              check "--selector with no match is an error" '.ok==false and .error.code=="BAD_SELECTOR"' "$R"


# --- sessions and the menu bar item ----------------------------------------
ab open "file://$FIX/login.html" >/dev/null
R=$(ab sessions);                                 check "sessions lists the running helper with its state" '.ok and ([.result.sessions[]|select(.session=="'"$AGENT_BROWSER_SESSION"'")]|length==1) and (.result.sessions[]|select(.session=="'"$AGENT_BROWSER_SESSION"'")|.state=="idle" and (.url|endswith("login.html")) and .needs_you==false and .pid>0)' "$R"
T=$(ab snapshot | jq -r .result.tree); BTN=$(ref "$T" 'button "Log in"')
ab wait --ms 1500 --timeout 5000 >/dev/null &
sleep 0.5
R=$(ab sessions);                                 check "a running command shows as working (status does not wait for the lock)" '(.result.sessions[]|select(.session=="'"$AGENT_BROWSER_SESSION"'")|.state=="working" and (.command|startswith("wait")))' "$R"
wait
ab watch on >/dev/null; ab watch pause >/dev/null
ab click "$BTN" >/dev/null &
CLICKPID=$!
sleep 0.8
R=$(ab sessions);                                 check "paused with a waiting command -> needs_you" '(.result.sessions[]|select(.session=="'"$AGENT_BROWSER_SESSION"'")|.state=="paused" and .needs_you==true)' "$R"
R=$(ab menubar --dump-menu);                      check "menu model: session submenu with resume, close, needs-you marker" '[.result.menu[]|select((.title|test("'"$AGENT_BROWSER_SESSION"'")) and (.title|test("needs you")))|.children[].title]|(index("Resume (give control back)")!=null and index("Close session")!=null and index("Hide window")!=null)' "$R"
R=$(ab watch resume);                             check "resume releases the waiting command" '.ok and .result.paused==false' "$R"
wait $CLICKPID
ab watch off >/dev/null
R=$(ab menubar --dump-menu);                      check "menu model: idle session offers show window and take over" '[.result.menu[]|select(.title|test("'"$AGENT_BROWSER_SESSION"'"))|.children[].title]|(index("Show window")!=null and index("Take over (pause the agent)")!=null)' "$R"
check "menu model: static items" '[.result.menu[].title]|(index("Open downloads folder")!=null and index("Start at login")!=null and index("Quit menu bar item")!=null)' "$R"
R=$(ab menubar --dump-menu);                      check "menu model: an idle session row has no state glyph, only its name" '[.result.menu[]|select(.title|test("'"$AGENT_BROWSER_SESSION"'"))|.title|test("^[○●▲]")]|all(.==false)' "$R"
R=$(ab menubar --dump-menu);                      check "menu model: session rows carry an icon field for the favicon" '[.result.menu[]|select(.title|test("'"$AGENT_BROWSER_SESSION"'"))|has("icon")]|all' "$R"
# favicon URL in status (the menu bar item loads it); needs python3 for a throwaway local server
if command -v python3 >/dev/null; then
  FP=$((20000 + RANDOM % 20000)); python3 -m http.server $FP --bind 127.0.0.1 --directory "$FIX" >/dev/null 2>&1 & FPID=$!
  sleep 1
  ab open "http://127.0.0.1:$FP/login.html" >/dev/null
  R=$(ab status); check "status reports the page's favicon url (default /favicon.ico)" '.result.favicon=="http://127.0.0.1:'$FP'/favicon.ico"' "$R"
  ab open "file://$FIX/login.html" >/dev/null
  R=$(ab status); check "status has no favicon for a file page" '.result|has("favicon")|not' "$R"
  kill $FPID 2>/dev/null; wait $FPID 2>/dev/null
fi
LA="$(mktemp -d)"
R=$(AGENT_BROWSER_LAUNCH_AGENTS_DIR="$LA" ab menubar install);   check "menubar install writes a launch agent" '.ok' "$R"
[ "$(plutil -extract ProgramArguments json -o - "$LA/dev.appler.agent-browser.menubar.plist" | jq -r '.[1],.[2]' | tr '\n' ' ')" = "menubar --foreground " ] && [ "$(plutil -extract RunAtLoad raw -o - "$LA/dev.appler.agent-browser.menubar.plist")" = "true" ] && { PASS=$((PASS+1)); echo "ok   - launch agent runs 'menubar --foreground' at load"; } || { FAIL=$((FAIL+1)); echo "FAIL - launch agent contents"; }
R=$(AGENT_BROWSER_LAUNCH_AGENTS_DIR="$LA" ab menubar --dump-menu); check "menu shows 'Start at login' checked once installed" '.result.menu[]|select(.title=="Start at login")|.checked==true' "$R"
AGENT_BROWSER_LAUNCH_AGENTS_DIR="$LA" ab menubar uninstall >/dev/null
[ ! -e "$LA/dev.appler.agent-browser.menubar.plist" ] && { PASS=$((PASS+1)); echo "ok   - menubar uninstall removes the launch agent"; } || { FAIL=$((FAIL+1)); echo "FAIL - launch agent not removed"; }
rm -rf "$LA"
"$BIN" menubar --foreground </dev/null >/dev/null 2>&1 & MBPID=$!
sleep 2
if kill -0 $MBPID 2>/dev/null; then kill $MBPID 2>/dev/null; wait $MBPID 2>/dev/null; PASS=$((PASS+1)); echo "ok   - menu bar item starts and keeps running"
elif pgrep -f "menubar --foreground" >/dev/null; then PASS=$((PASS+1)); echo "ok   - menu bar item already running (single instance)"
else FAIL=$((FAIL+1)); echo "FAIL - menu bar item exited"; fi


# --- human checks: CAPTCHA pages get a needs_human hint, ordinary pages do not -------------
R=$(ab open "file://$FIX/captcha.html");              check "open on a CAPTCHA page carries needs_human" '.ok and .result.needs_human.kind=="captcha" and (.result.needs_human.hint|test("watch pause"))' "$R"
R=$(ab snapshot --text | tail -1);                    echo "$R" | grep -q "^# NEEDS A HUMAN (captcha)" && { PASS=$((PASS+1)); echo "ok   - text snapshot ends with a NEEDS A HUMAN line"; } || { FAIL=$((FAIL+1)); echo "FAIL - text snapshot lacks the NEEDS A HUMAN line: $R"; }
R=$(ab status);                                       check "a pending human check makes the session needs_you" '.result.needs_you==true' "$R"
R=$(ab open "file://$FIX/captcha-badge.html");        check "invisible reCAPTCHA badge and hidden elements are not flagged" '.ok and (.result|has("needs_human")|not)' "$R"
R=$(ab status);                                       check "needs_you clears once the page is fine" '.result.needs_you==false' "$R"
R=$(ab open "file://$FIX/login.html");                check "an ordinary page has no needs_human" '.ok and (.result|has("needs_human")|not)' "$R"

# --- vault: credentials for bots -----------------------------------------
PW='Zq9-vault-pw-1'; PW2='other-pw-4567'; TSECRET='GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ'
R=$(ab vault selftest);                           check "vault: TOTP matches RFC 6238 vectors" '.ok and .result.selftest=="ok"' "$R"
R=$(printf '%s\n' "$PW" | ab vault add site --origin file:// --username alice);   check "vault add (password read from stdin, never argv)" '.ok and .result.added=="site"' "$R"
R=$(printf '%s\n' "$PW2" | ab vault add other --origin https://example.com --username bob);  check "vault add https origin" '.ok and (.result.origins==["https://example.com"])' "$R"
R=$(printf '%s\n' x | ab vault add bad --origin http://example.com --username u);  check "vault add rejects plain http to a remote host" '.ok==false and (.error.message|test("https"))' "$R"
R=$(printf '%s\n' "$PW" | ab vault add site --origin file:// --username alice);   check "vault add refuses to overwrite without --replace" '.ok==false and .error.code=="VAULT_EXISTS"' "$R"
R=$(ab vault list);                               check "vault list shows names, sites, flags and no values" '.ok and (.result.entries|length==2) and (.result.entries[0]|has("password")|not)' "$R"
echo "$R" | grep -q -e "$PW" -e alice && { FAIL=$((FAIL+1)); echo "FAIL - vault list leaked a credential"; } || { PASS=$((PASS+1)); echo "ok   - vault list output holds no credentials"; }
R=$(env -u AGENT_BROWSER_VAULT_FILE "$BIN" vault add nope --origin https://example.com --username u </dev/null);  check "vault add needs a terminal (an agent cannot create entries)" '.ok==false and .error.code=="VAULT_NEEDS_TTY"' "$R"
R=$(env -u AGENT_BROWSER_VAULT_FILE "$BIN" vault rm site </dev/null);  check "vault rm needs a terminal" '.ok==false and .error.code=="VAULT_NEEDS_TTY"' "$R"
R=$(ab vault origin other --add https://login.example.com);  check "vault origin --add keeps the old site and adds the new one" '.ok and .result.changed and (.result.origins==["https://example.com","https://login.example.com"])' "$R"
R=$(ab vault origin other --add https://login.example.com);  check "vault origin --add of a known site changes nothing" '.ok and (.result.changed==false)' "$R"
R=$(ab vault origin other --add http://evil.example.com);    check "vault origin rejects plain http to a remote host" '.ok==false and (.error.message|test("https"))' "$R"
R=$(ab vault origin other --remove https://nowhere.example.com);  check "vault origin --remove of an unknown site fails" '.ok==false and .error.code=="VAULT_NO_ORIGIN"' "$R"
R=$(ab vault origin other --remove https://example.com);     check "vault origin --remove drops one site" '.ok and (.result.origins==["https://login.example.com"])' "$R"
R=$(ab vault origin other --remove https://login.example.com);  check "vault origin refuses to remove the last site" '.ok==false' "$R"
R=$(ab vault origin nope --add https://example.com);         check "vault origin on a missing entry" '.ok==false and .error.code=="VAULT_NO_ENTRY"' "$R"
R=$(env -u AGENT_BROWSER_VAULT_FILE "$BIN" vault origin other --add https://x.example.com </dev/null);  check "vault origin needs a terminal (an agent cannot widen a login)" '.ok==false and .error.code=="VAULT_NEEDS_TTY"' "$R"
R=$(ab vault list);  check "vault origin left the other entry untouched" '(.result.entries[]|select(.name=="other")|.origins)==["https://login.example.com"]' "$R"

vab open "file://$FIX/login.html" >/dev/null
T=$(vab snapshot | jq -r .result.tree); U=$(ref "$T" 'Username'); P=$(ref "$T" 'Password'); B=$(ref "$T" 'button "Log in"')
R=$(vab fill "$U" --secret site --field username);  check "fill --secret username" '.ok and .result.value=="(from vault)" and .result.entry=="site"' "$R"
R=$(vab fill "$P" --secret site);                 check "fill --secret password never echoes the value" '.ok and .result.value=="(from vault)"' "$R"
T=$(vab snapshot | jq -r .result.tree)
echo "$T" | grep -q 'value=•••(' && { PASS=$((PASS+1)); echo "ok   - snapshot masks the typed password"; } || { FAIL=$((FAIL+1)); echo "FAIL - password not masked in snapshot"; echo "$T"; }
R=$(vab click "$(ref "$T" 'button "Log in"')");  check "login form submitted; the password in the GET url is redacted" '.ok and (.result.outcome|test("navigated: done.html\\?user=alice")) and (.result.url|contains("[redacted]"))' "$R"
vab wait --text "Hello alice" --timeout 3000 | jq -e '.ok' >/dev/null && { PASS=$((PASS+1)); echo "ok   - the page received the real username"; } || { FAIL=$((FAIL+1)); echo "FAIL - username not received"; }

vab open "file://$FIX/login.html" >/dev/null
R=$(vab login site --submit);                     check "login fills username + password and submits" '.ok and .result.filled==["username","password"] and .result.submitted==true and (.result.outcome|test("navigated: done.html\\?user=alice"))' "$R"
vab open "file://$FIX/login.html" >/dev/null
R=$(vab login other);                             check "login on the wrong site -> ORIGIN_MISMATCH" '.ok==false and .error.code=="ORIGIN_MISMATCH" and (.error.message|test("Nothing was entered"))' "$R"
T=$(vab snapshot | jq -r .result.tree); U=$(ref "$T" 'Username')
R=$(vab fill "$U" --secret other --field username); check "fill --secret on the wrong site -> ORIGIN_MISMATCH" '.ok==false and .error.code=="ORIGIN_MISMATCH"' "$R"
echo "$(vab snapshot | jq -r .result.tree)" | grep -q 'value="bob"' && { FAIL=$((FAIL+1)); echo "FAIL - a mismatched entry still typed into the page"; } || { PASS=$((PASS+1)); echo "ok   - nothing was typed after the mismatch"; }
R=$(vab login nope);                              check "login with an unknown entry lists what exists" '.ok==false and .error.code=="VAULT_NO_ENTRY" and (.error.message|test("site"))' "$R"
vab open "file://$FIX/done.html" >/dev/null
R=$(vab login site);                              check "login with no fields on the page -> NO_LOGIN_FIELDS" '.ok==false and .error.code=="NO_LOGIN_FIELDS"' "$R"
R=$(vab fill @s1:e1 --secret site --field bogus); check "fill --secret rejects an unknown field" '.ok==false' "$R"

# two-step login (identifier first, then password)
R=$(printf '%s\n' "$PW" | ab vault add mail --origin file:// --username alice@example.test);  check "vault add (email username)" '.ok' "$R"
vab open "file://$FIX/twostep1.html" >/dev/null
R=$(vab login mail --submit);                     check "two-step: first page fills only the username" '.ok and .result.filled==["username"] and (.result.outcome|test("navigated: twostep2.html"))' "$R"
R=$(vab login mail --submit);                     check "two-step: second page fills only the password" '.ok and .result.filled==["password"] and (.result.outcome|test("navigated: done.html"))' "$R"

# TOTP
R=$(printf '%s\n%s\n' "$PW" "$TSECRET" | ab vault add tfa --origin file:// --username alice --totp);  check "vault add --totp validates the secret" '.ok and .result.totp==true' "$R"
R=$(printf '%s\n%s\n' "$PW" "not base32 !" | ab vault add tfabad --origin file:// --username alice --totp);  check "vault add --totp rejects a bad secret" '.ok==false' "$R"
[ $(( $(date +%s) % 30 )) -ge 27 ] && sleep 4
CODE=$(python3 - <<PY
import hmac,hashlib,struct,time,base64
k=base64.b32decode("$TSECRET"); c=struct.pack(">Q",int(time.time())//30)
h=hmac.new(k,c,hashlib.sha1).digest(); o=h[-1]&15
print("%06d"%((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000))
PY
)
AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-vault" "$BIN" open "file://$FIX/twofactor.html?expect=$CODE" >/dev/null  # not logged: the test itself knows the code
R=$(vab login tfa);                               check "login fills the current TOTP code too" '.ok and .result.filled==["username","password","otp"]' "$R"
vab wait --text "OTP OK" --timeout 3000 | jq -e '.ok' >/dev/null && { PASS=$((PASS+1)); echo "ok   - the typed one-time code is correct"; } || { FAIL=$((FAIL+1)); echo "FAIL - one-time code was wrong"; }
echo "$(vab snapshot | jq -r .result.tree)" | grep -q "$CODE" && { FAIL=$((FAIL+1)); echo "FAIL - one-time code visible in snapshot"; } || { PASS=$((PASS+1)); echo "ok   - one-time code is redacted from snapshots"; }
R=$(vab fill @s1:e1 --secret site --field totp);  check "fill --field totp on an entry without TOTP fails" '.ok==false and .error.code!="INTERNAL"' "$R"

# the session that typed secrets cannot expose a DevTools endpoint
R=$(vab cdp start);                               check "cdp is refused once secrets were typed in the session" '.ok==false and .error.code=="VAULT_CDP_BLOCKED"' "$R"
vc() { AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-vcdp" "$BIN" "$@"; }
vc open "file://$FIX/login.html" >/dev/null; vc cdp start >/dev/null
R=$(vc login site);                               check "vault is refused while the DevTools endpoint runs" '.ok==false and .error.code=="VAULT_CDP_BLOCKED"' "$R"
vc cdp stop >/dev/null; vc close >/dev/null

# confirm: human approval per use
R=$(printf '%s\n' "$PW" | ab vault add guarded --origin file:// --username alice --confirm);  check "vault add --confirm" '.ok and .result.confirm==true' "$R"
vab open "file://$FIX/login.html" >/dev/null
R=$(vab login guarded);                           check "confirm entry without approval is denied and types nothing" '.ok==false and .error.code=="VAULT_APPROVAL_DENIED"' "$R"
for mode in yes no; do
  vx() { AGENT_BROWSER_VAULT_APPROVE=$mode AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-v$( [ $mode = yes ] && echo ok || echo no)" "$BIN" "$@"; }
  vx open "file://$FIX/login.html" >/dev/null
  R=$(vx login guarded)
  if [ $mode = yes ]; then check "confirm entry is used once approved" '.ok and .result.filled==["username","password"]' "$R"
  else check "confirm entry is not used when the person says no" '.ok==false and .error.code=="VAULT_APPROVAL_DENIED"' "$R"; fi
done


# --- 2FA enrollment: capture the secret on a signup page without the agent seeing it ---
KEY='JBSWY3DPEHPK3PXP'
for e in signup qronly keyonly conflict; do printf '%s\n' "$PW" | ab vault add $e --origin file:// --username alice >/dev/null; done
vab open "file://$FIX/totp-setup.html" >/dev/null
T=$(vab snapshot --text)
echo "$T" | grep -q 'hidden: possible 2FA setup key' && ! echo "$T" | grep -q -e 'Y3DP' -e "$KEY" && { PASS=$((PASS+1)); echo "ok   - snapshot hides the 2FA setup key"; } || { FAIL=$((FAIL+1)); echo "FAIL - setup key visible in snapshot"; echo "$T"; }
R=$(vab totp enroll signup);                      check "totp enroll reads the QR/key and saves it (no secret in the result)" '.ok and .result.saved==true and .result.issuer=="Example" and .result.account=="alice" and .result.digits==6' "$R"
echo "$R" | grep -q -e "$KEY" -e 'secret=' && { FAIL=$((FAIL+1)); echo "FAIL - enroll result leaked the secret"; } || { PASS=$((PASS+1)); echo "ok   - enroll result holds no secret"; }
R=$(ab vault list);                               check "vault list shows totp:true after enroll" '(.result.entries[]|select(.name=="signup")|.totp)==true' "$R"
R=$(vab totp enroll signup);                      check "totp enroll refuses to overwrite without --replace" '.ok==false and .error.code=="VAULT_HAS_TOTP"' "$R"
R=$(vab totp enroll signup --replace);            check "totp enroll --replace" '.ok and .result.saved==true' "$R"
[ $(( $(date +%s) % 30 )) -ge 27 ] && sleep 4
CODE2=$(python3 - <<PY
import hmac,hashlib,struct,time,base64
k=base64.b32decode("$KEY"); c=struct.pack(">Q",int(time.time())//30)
h=hmac.new(k,c,hashlib.sha1).digest(); o=h[-1]&15
print("%06d"%((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000))
PY
)
AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-vault" "$BIN" open "file://$FIX/totp-setup.html?expect=$CODE2" >/dev/null
T=$(vab snapshot | jq -r .result.tree); C=$(ref "$T" 'Verification code')
R=$(vab fill "$C" --secret signup --field totp);  check "the enrolled secret produces the right code" '.ok' "$R"
vab wait --text "OTP OK" --timeout 3000 | jq -e '.ok' >/dev/null && { PASS=$((PASS+1)); echo "ok   - code from the enrolled secret is accepted by the page"; } || { FAIL=$((FAIL+1)); echo "FAIL - enrolled secret gave a wrong code"; }
vab open "file://$FIX/totp-qr-only.html" >/dev/null
R=$(vab totp enroll qronly);                      check "enroll from a QR image alone (Vision decode)" '.ok and .result.source=="qr" and .result.issuer=="Example"' "$R"
vab open "file://$FIX/totp-key-only.html" >/dev/null
T=$(vab snapshot --text)
echo "$T" | grep -q "$KEY" && { FAIL=$((FAIL+1)); echo "FAIL - key in an input value visible in snapshot"; } || { PASS=$((PASS+1)); echo "ok   - setup key in an input value is hidden too"; }
R=$(vab totp enroll keyonly);                     check "enroll from a setup key alone" '.ok and .result.source=="key"' "$R"
vab open "file://$FIX/totp-conflict.html" >/dev/null
R=$(vab totp enroll conflict);                    check "conflicting secrets on a page -> TOTP_AMBIGUOUS, nothing saved" '.ok==false and .error.code=="TOTP_AMBIGUOUS"' "$R"
R=$(ab vault list);                               check "ambiguous enroll left the entry without TOTP" '(.result.entries[]|select(.name=="conflict")|.totp)==false' "$R"
vab open "file://$FIX/done.html" >/dev/null
R=$(vab totp enroll conflict);                    check "page without 2FA setup -> TOTP_NOT_FOUND" '.ok==false and .error.code=="TOTP_NOT_FOUND"' "$R"
vab open "file://$FIX/totp-setup.html" >/dev/null
R=$(vab totp enroll other);                       check "enroll for an entry of another site -> ORIGIN_MISMATCH" '.ok==false and .error.code=="ORIGIN_MISMATCH"' "$R"

# recovery codes
vab open "file://$FIX/recovery.html" >/dev/null
R=$(vab recovery save signup);                    check "recovery save finds the code list" '.ok and .result.saved==8' "$R"
echo "$R" | grep -q 'a1b2' && { FAIL=$((FAIL+1)); echo "FAIL - recovery codes in result"; } || { PASS=$((PASS+1)); echo "ok   - recovery result holds no codes"; }
T=$(vab snapshot --text)
echo "$T" | grep -q -e 'a1b2-c3d4' -e 'd6e7-f8g9' && { FAIL=$((FAIL+1)); echo "FAIL - saved recovery codes still visible"; } || { PASS=$((PASS+1)); echo "ok   - saved recovery codes are redacted from later snapshots"; }
R=$(vab recovery save signup --selector '#codes'); check "recovery save with a selector" '.ok and .result.saved==8' "$R"
R=$(vab recovery save signup --selector 'h1');    check "recovery save rejects a non-code element" '.ok==false and .error.code=="NO_RECOVERY_CODES"' "$R"
R=$(ab vault list);                               check "vault list counts recovery codes" '(.result.entries[]|select(.name=="signup")|.recovery)==8' "$R"

# export: the person gets the backup, the agent cannot
R=$(ab vault export signup --json);               check "export without approval is denied" '.ok==false and .error.code=="VAULT_APPROVAL_DENIED"' "$R"
R=$(AGENT_BROWSER_VAULT_APPROVE=yes ab vault export signup --json)
check "export shows the secret, link, current code and recovery codes" '.ok and .result.totp.secret=="JBSWY3DPEHPK3PXP" and (.result.totp.uri|startswith("otpauth://totp/")) and (.result.totp.current_code|test("^[0-9]{6}$")) and (.result.recovery_codes|length)==8' "$R"
[ "$(echo "$R" | jq -r .result.totp.current_code)" = "$(python3 - <<PY
import hmac,hashlib,struct,time,base64
k=base64.b32decode("$KEY"); c=struct.pack(">Q",int(time.time())//30)
h=hmac.new(k,c,hashlib.sha1).digest(); o=h[-1]&15
print("%06d"%((struct.unpack(">I",h[o:o+4])[0]&0x7fffffff)%1000000))
PY
)" ] && { PASS=$((PASS+1)); echo "ok   - exported current code matches an independent TOTP"; } || { FAIL=$((FAIL+1)); echo "FAIL - exported current code differs"; }
TXT=$(AGENT_BROWSER_VAULT_APPROVE=yes ab vault export signup --qr)
echo "$TXT" | grep -q 'TOTP secret: JBSWY3DPEHPK3PXP' && echo "$TXT" | grep -q $'\033\[107m' && { PASS=$((PASS+1)); echo "ok   - export prints the human-readable backup and a QR code"; } || { FAIL=$((FAIL+1)); echo "FAIL - export text/QR"; echo "$TXT" | head -5; }
R=$(env -u AGENT_BROWSER_VAULT_FILE "$BIN" vault export signup </dev/null);  check "export needs a terminal" '.ok==false and .error.code=="VAULT_NEEDS_TTY"' "$R"
R=$(ab vault audit --limit 100);                  check "audit records enroll, recovery and export" '([.result.entries[].action]|index("enroll")!=null and index("recovery")!=null and index("export")!=null)' "$R"

# audit trail
R=$(ab vault audit --limit 50);                   check "audit records fills, mismatches and denials" '.ok and ([.result.entries[].outcome]|index("ok")!=null and index("ORIGIN_MISMATCH")!=null and index("APPROVAL_DENIED")!=null) and ([.result.entries[]|select(.action=="login")]|length>=3)' "$R"
# mcp
M=$( { printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"t","version":"0"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"browser_vault_list","arguments":{}}}'; sleep 1; } | AGENT_BROWSER_SESSION="$AGENT_BROWSER_SESSION-vault" "$BIN" mcp | sed -n 2p )
check "mcp browser_vault_list returns names without values" '.result.isError==false and (.result.content[0].text|contains("site") and (contains("Zq9")|not))' "$M"
# nothing the agent could see contains a stored value
if grep -q -e "$PW" -e "$PW2" -e "$TSECRET" -e "$CODE" -e "$KEY" -e 'Y3DP' -e 'a1b2-c3d4' "$VT/all-output.log" "$VT/vault.json.audit"; then
  FAIL=$((FAIL+1)); echo "FAIL - a stored secret appeared in command output or the audit log"; grep -n -e "$PW" -e "$PW2" -e "$CODE" "$VT/all-output.log" | cut -c1-200 | head -3
else PASS=$((PASS+1)); echo "ok   - no stored secret appears in any command output or the audit log"; fi
R=$(ab vault origin guarded --add https://more.example.com);  check "vault origin on a --confirm entry is denied without approval" '.ok==false and .error.code=="VAULT_APPROVAL_DENIED"' "$R"
R=$(AGENT_BROWSER_VAULT_APPROVE=yes ab vault origin guarded --add https://more.example.com);  check "vault origin on a --confirm entry works when approved" '.ok and .result.changed' "$R"
R=$(ab vault audit --limit 100);  check "audit records origin changes with old and new sites" '[.result.entries[]|select(.action=="origin")]|length>=3' "$R"
R=$(ab vault rm guarded);                         check "vault rm" '.ok and .result.removed=="guarded"' "$R"
R=$(ab vault list);                               check "vault list after rm" '(.result.entries|map(.name)|index("guarded"))==null' "$R"

# --- CDP shim (raw protocol; Puppeteer/Playwright live in Tests/cdp-compat.sh) ------
if command -v node >/dev/null 2>&1 && [ "$(node -p 'process.versions.node.split(".")[0]')" -ge 22 ]; then
  CDPINFO=$(ab cdp start)
  check "cdp start returns loopback http and ws endpoints" '.ok and (.result.http|test("^http://127.0.0.1:[0-9]+$")) and (.result.ws|test("^ws://127.0.0.1:"))' "$CDPINFO"
  HTTP=$(echo "$CDPINFO" | jq -r .result.http); WSURL=$(echo "$CDPINFO" | jq -r .result.ws)
  check "/json/version advertises the websocket" '.webSocketDebuggerUrl|startswith("ws://127.0.0.1:")' "$(curl -s "$HTTP/json/version")"
  check "/json/list lists pages with ws urls" 'length>=1 and (.[0].webSocketDebuggerUrl|test("/devtools/page/"))' "$(curl -s "$HTTP/json/list")"
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.example' "$HTTP/json/version")" = "403" ] && { PASS=$((PASS+1)); echo "ok   - browser-origin requests are rejected (403)"; } || { FAIL=$((FAIL+1)); echo "FAIL - Origin header not rejected"; }
  [ "$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "$HTTP/json/version")" = "403" ] && { PASS=$((PASS+1)); echo "ok   - non-local Host header is rejected (403)"; } || { FAIL=$((FAIL+1)); echo "FAIL - Host header not rejected"; }
  R=$(timeout 60 node "$HERE/cdp/raw.mjs" "$WSURL" "$FIX" 2>&1 | tail -1)
  check "cdp: version, targets, attach" '(.version|startswith("agent-browser/")) and .pageTargets>=1 and .attached' "$R"
  check "cdp: Page.navigate emits frameNavigated, lifecycle and load" '.navigateHasLoader and .loadEvent and .frameNavigated and (.lifecycle|index("load")!=null and index("DOMContentLoaded")!=null)' "$R"
  check "cdp: Runtime.evaluate values, promises and exceptions" '.sum==3 and .title=="Login" and .promise==42 and .exception=="Error: boom"' "$R"
  check "cdp: remote objects and callFunctionOn" '.h1Subtype=="node" and .callFunctionOn=="Sign in"' "$R"
  check "cdp: DOM query, box model, focus + insertText, mouse click focuses" '.querySelector and .boxHasSize and .typed=="alice" and .focusedAfterClick=="u"' "$R"
  check "cdp: screenshot and accessibility tree" '.screenshotBytes>1000 and .axNodes>2' "$R"
  check "cdp: PDF inline and as an IO stream" '.pdfInline=="%PDF" and .pdfStream=="%PDF"' "$R"
  check "cdp: unsupported things fail loudly" '(.fetchEnable|test("not supported")) and (.browserContext|test("not supported")) and .unknown==-32601 and .unknownSession==-32001' "$R"
  check "cdp: createTarget/closeTarget" '.createdListed and .closed' "$R"
  R=$(ab cdp stop);                               check "cdp stop" '.ok and .result.running==false' "$R"
  curl -s -m 2 "$HTTP/json/version" >/dev/null 2>&1 && { FAIL=$((FAIL+1)); echo "FAIL - endpoint still answering after stop"; } || { PASS=$((PASS+1)); echo "ok   - endpoint is closed after stop"; }
else echo "skip - CDP tests (need Node 22+)"; fi

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
