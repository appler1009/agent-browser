#!/bin/bash
# CPU and memory of the host and its WebKit helpers in a few scenarios (macOS tools only: ps, footprint, heap).
# Usage: Tests/perf.sh [binary] [extra URL...]     Extra URLs are loaded and measured idle (they need network).
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
BIN="${1:-$HERE/../.build/release/agent-browser}"; shift 2>/dev/null
export AGENT_BROWSER_HOST_ID="perf-$$" AGENT_BROWSER_COOKIE_KEY_FILE="$(mktemp -u)" AGENT_BROWSER_IDLE_SUSPEND_SECS=3600
W="$(mktemp -d)"
python3 - "$W" <<'PY'
import sys
rows=''.join(f'<div><a href="#x{i}">item {i}</a> <button>b{i}</button> <input value="v{i}"></div>' for i in range(8000))
open(sys.argv[1]+'/bigdom.html','w').write('<!doctype html><title>bigdom</title>'+rows)
PY
cp "$HERE/perf/anim.html" "$HERE/fixtures/login.html" "$W/"
trap 'for s in a b c d e; do AGENT_BROWSER_SESSION=perf$s "$BIN" close >/dev/null 2>&1; done; rm -rf "$W" "$AGENT_BROWSER_COOKIE_KEY_FILE"' EXIT
ab() { local s=$1; shift; AGENT_BROWSER_SESSION=perf$s "$BIN" "$@"; }
ab a open "file://$W/login.html" >/dev/null; HP=$(ab a status | jq -r .result.pid); sleep 3
m() { python3 "$HERE/perf/sample.py" "$HP" "$1" "$2" | jq -c '{label,total_cpu_pct:.total_cpu,total_mb,procs:(.procs|map_values({n,cpu,mb}))}'; }
m 15 "1 session, small page, idle"
ab a open "file://$W/anim.html" >/dev/null; sleep 3; m 15 "1 session, animated page, hidden"
ab a open "file://$W/bigdom.html" >/dev/null; sleep 3; m 15 "1 session, 8000-row page, idle"
( for i in $(seq 1 100); do ab a snapshot >/dev/null; done ) & m 8 "100 snapshots of the 8000-row page"; wait
for s in b c d e; do ab $s open "file://$W/bigdom.html" >/dev/null & done; wait; sleep 3; m 15 "5 sessions, 8000-row page each, idle"
for s in a b c d e; do ab $s watch on >/dev/null; done; sleep 3; m 15 "5 sessions shown as tabs"
for s in a b c d e; do ab $s watch off >/dev/null; done
for u in "$@"; do ab a open "$u" >/dev/null; sleep 10; m 20 "idle: $u"; done
for s in a b c d e; do ab $s close >/dev/null; done
echo "leak check: 20 open/close cycles"
ab keep open "file://$W/login.html" >/dev/null; KP=$(ab keep status | jq -r .result.pid)
hc() { heap "$KP" 2>/dev/null | awk -v c="$1" '$4==c{print $1}' | head -1; }
B0=$(hc Browser); F0=$(footprint -p "$KP" --noCategories | grep -o 'Footprint: [0-9.]* [KMG]B')
for i in $(seq 1 20); do ab x open "file://$W/bigdom.html" >/dev/null; ab x snapshot >/dev/null; ab x close >/dev/null; done
sleep 3; echo "browsers $B0 -> $(hc Browser); host $F0 -> $(footprint -p "$KP" --noCategories | grep -o 'Footprint: [0-9.]* [KMG]B')"
ab keep close >/dev/null
