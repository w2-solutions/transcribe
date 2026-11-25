#!/bin/bash
# Smoke test of Claude access (§8.5): drives the bundled helper (Contents/Helpers/transcribe-mcp) against a
# fake-engine Debug build of the Mac app, through pairing.
#
#   scripts/mcp-smoke.sh "$DD/Build/Products/Debug/Transcribe.app"
#
# Agent-safe: the app runs with the fake engine and the seeded fake library only, on a throwaway port in 39000–39999
# (not one of the well-known ports), passed for this session only (TRANSCRIBE_MCP_TEST_PORT; never saved). The helper
# always gets that port and a state folder inside this script's temp folder, never the real one. Nothing clicks
# Allow: the app's DEBUG auto-allow hook (session only) stands in for it. It never runs `claude mcp …`, never touches
# Claude's files, and kills only the processes it started.
#
# Steps: 1 launch; 2 raw HTTP (401, 403, 405, 400, a pairing commitment and a wrong reveal); 3 the handshake,
# and an unpaired call asks for permission with a code; 4 data is refused until allowed; 5 relaunched with a new
# key and Allow automatic: the never-verified pairing is replaced by itself and both tools answer; relaunched again,
# the now verified pairing is kept on an unsigned "unknown", then, its state deleted, pairs again and reads; 6 a
# second Claude app gets its own pairing; 7 with the app quit, a DEBUG helper never
# launches it; 8 the helper's fake launch in the background (only when no copy of Transcribe is running). Prints
# PASS, FAIL or SKIP per step; exits 1 on any FAIL, 2 on bad arguments. Runs on macOS /bin/bash 3.2; needs jq
# (/usr/bin/jq on macOS 15 and later), curl, nc, openssl.
set -uo pipefail

usage() {
  sed -n '2,19s/^# \{0,1\}//p' "$0" >&2
  exit 2
}
[ $# -eq 1 ] || usage
[ -d "$1" ] || { echo "error: no app at $1" >&2; exit 2; }
# The real path (/var and /tmp resolved to /private/...): LaunchServices runs the app from it, and `pgrep -f "^$EXE"`
# must match that, or step 1 never sees the app it launched and leaves it running.
APP="$(cd "$1" && pwd -P)"
EXE="$APP/Contents/MacOS/Transcribe"
HELPER="$APP/Contents/Helpers/transcribe-mcp"
[ -x "$EXE" ] || { echo "error: $APP has no Contents/MacOS/Transcribe" >&2; exit 2; }
[ -x "$HELPER" ] || { echo "error: $APP has no Contents/Helpers/transcribe-mcp" >&2; exit 2; }
for tool in jq curl nc perl lsappinfo openssl; do
  command -v "$tool" >/dev/null || { echo "error: $tool is missing" >&2; exit 2; }
done

PORT=$((39000 + RANDOM % 1000))
WORK="$(mktemp -d "${TMPDIR:-/tmp}/mcp-smoke.XXXXXX")"
STATE="$WORK/state/Transcribe MCP"
STARTED=""
FAILED=0

cleanup() {
  local pid
  for pid in $STARTED; do kill "$pid" 2>/dev/null; done
  rm -rf "$WORK"
}
trap cleanup EXIT

pass() { echo "PASS $*"; }
fail() { echo "FAIL $*"; FAILED=1; }
now() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time'; }
# seconds_since T0: elapsed seconds, with milliseconds.
seconds_since() { perl -MTime::HiRes=time -e 'printf "%.3f\n", time - $ARGV[0]' "$1"; }
# less_than A B: A < B for decimal numbers.
less_than() { perl -e 'exit($ARGV[0] < $ARGV[1] ? 0 : 1)' "$1" "$2"; }

# The PIDs of copies of this build (matched by executable path), one per line.
app_pids() { pgrep -f "^$EXE" || true; }
# new_pids BEFORE: PIDs of this build that are not in BEFORE.
new_pids() {
  local pid
  for pid in $(app_pids); do
    case " $(echo $1) " in *" $pid "*) ;; *) echo "$pid" ;; esac
  done
}
# wait_for_new_pids BEFORE SECONDS: adds the new PIDs to STARTED; fails when none appears in time.
wait_for_new_pids() {
  local t0 pids
  t0="$(now)"
  while less_than "$(seconds_since "$t0")" "$2"; do
    pids="$(new_pids "$1")"
    if [ -n "$pids" ]; then
      STARTED="$STARTED $(echo $pids)"
      echo "$pids"
      return 0
    fi
    sleep 0.2
  done
  return 1
}
# kill_started: ends every process this script started, waiting up to 10 s, then waits for the port to close.
kill_started() {
  local pid t0
  for pid in $STARTED; do kill "$pid" 2>/dev/null; done
  t0="$(now)"
  for pid in $STARTED; do
    while kill -0 "$pid" 2>/dev/null && less_than "$(seconds_since "$t0")" 10; do sleep 0.2; done
  done
  STARTED=""
  t0="$(now)"
  while nc -z 127.0.0.1 "$PORT" 2>/dev/null && less_than "$(seconds_since "$t0")" 10; do sleep 0.2; done
}
# launch_app STEP [--env VAR=value ...]: starts the fake-engine app with Claude access on for this session, on $PORT,
# and waits for it to listen. A fake-engine run reads the Mac's own defaults, where "Sync with iCloud" may be on: its
# in-memory fake iCloud then reads the last run's sync state as deletions and removes the seeded recordings.
# -settings.syncEnabled NO turns sync off for this run only (the argument domain; nothing is written).
launch_app() {
  local step="$1" before t0
  shift
  before="$(app_pids)"
  open -n -g "$APP" --env TRANSCRIBE_SEED=library --env TRANSCRIBE_MCP=on --env TRANSCRIBE_MCP_TEST_PORT="$PORT" "$@" \
    --args -useFakeEngine -settings.syncEnabled NO
  if ! wait_for_new_pids "$before" 10 >/dev/null; then
    fail "$step launch: no new process of $EXE within 10 s"
    exit 1
  fi
  t0="$(now)"
  until nc -z 127.0.0.1 "$PORT" 2>/dev/null; do
    if ! less_than "$(seconds_since "$t0")" 20; then
      fail "$step launch: nothing listens on 127.0.0.1:$PORT after 20 s"
      exit 1
    fi
    sleep 0.2
  done
}

# helper_session TIMEOUT REPLIES [VAR=value ...] < lines
# Starts the helper with this script's port and state folder (plus the given variables), sends stdin's lines, and
# keeps its input open until REPLIES lines came back or TIMEOUT seconds passed (a launch can take longer than the
# helper's 5 s grace after end of input). The replies end up in $WORK/out and the seconds to the last one in
# $WORK/elapsed.
helper_session() {
  local timeout="$1" want="$2" t0 hpid
  shift 2
  rm -f "$WORK/in" "$WORK/out"
  mkfifo "$WORK/in"
  : >"$WORK/out"
  env -u TRANSCRIBE_MCP_PORT -u TRANSCRIBE_MCP_STATE_DIR -u TRANSCRIBE_MCP_DEBUG_LAUNCH \
    TRANSCRIBE_MCP_PORT="$PORT" TRANSCRIBE_MCP_STATE_DIR="$STATE" "$@" "$HELPER" \
    <"$WORK/in" >"$WORK/out" 2>>"$WORK/helper-stderr" &
  hpid=$!
  exec 3>"$WORK/in"
  t0="$(now)"
  cat >&3
  while [ "$(grep -c . "$WORK/out")" -lt "$want" ] && less_than "$(seconds_since "$t0")" "$timeout"; do sleep 0.05; done
  seconds_since "$t0" >"$WORK/elapsed"
  exec 3>&-
  wait "$hpid" 2>/dev/null
}
# reply ID: the helper's reply with this id, compact.
reply() { jq -c --argjson id "$1" 'select(.id == $id)' "$WORK/out"; }
# reply_text ID: the text of a tools/call reply.
reply_text() { reply "$1" | jq -r '.result.content[0].text // empty'; }
# code_in TEXT: the "123 456" code in a permission message.
code_in() { printf '%s\n' "$1" | sed -n 's/.*the code is \([0-9]\{3\} [0-9]\{3\}\).*/\1/p' | head -n 1; }
# state_files: the helper's pairing files, one per line.
state_files() { ls "$STATE" 2>/dev/null | grep '\.json$' || true; }

init() { printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"%s","version":"1"}}}' "$1"; }
INIT="$(init mcp-smoke)"
INITIALIZED='{"jsonrpc":"2.0","method":"notifications/initialized"}'
TOOLS='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
DISCOVER='{"jsonrpc":"2.0","id":3,"method":"server/discover"}'
LIST='{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"list_recordings","arguments":{}}}'
get() { printf '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"get_transcript","arguments":{"recording_id":"%s"}}}' "$1"; }

echo "Claude access smoke test: $APP (port $PORT, helper state in a temp folder)"

# 1. Launch the fake-engine app with Claude access on for this session (Allow not automatic).
launch_app 1
pass "1 launch: the fake-engine app listens on 127.0.0.1:$PORT"

# 2. Raw HTTP: unauthenticated, from a web page, the wrong method, and a malformed pairing request.
http_code() {
  local path="$1"
  shift
  curl -s --noproxy '*' --max-time 5 -o /dev/null -w '%{http_code}' "$@" "http://127.0.0.1:$PORT$path"
}
code="$(http_code /mcp -X POST --data '{}')"
[ "$code" = 401 ] && pass "2 raw HTTP: unsigned POST /mcp gets 401" || fail "2 raw HTTP: unsigned POST got $code, expected 401"
code="$(http_code /mcp -X POST --data '{}' -H 'Origin: https://example.com')"
[ "$code" = 403 ] && pass "2 raw HTTP: an Origin header gets 403" || fail "2 raw HTTP: Origin got $code, expected 403"
code="$(http_code /mcp -X GET)"
[ "$code" = 405 ] && pass "2 raw HTTP: GET gets 405" || fail "2 raw HTTP: GET got $code, expected 405"
code="$(http_code /pair -X POST --data '{"v":1}' -H 'Content-Type: application/json')"
[ "$code" = 400 ] && pass "2 raw HTTP: a malformed pairing request gets 400" || fail "2 raw HTTP: malformed /pair got $code, expected 400"
code="$(http_code /pair -X POST --data '{}' -H 'Content-Type: application/json' -H 'Origin: https://example.com')"
[ "$code" = 403 ] && pass "2 raw HTTP: a pairing request from a web page gets 403" || fail "2 raw HTTP: /pair with Origin got $code, expected 403"
# Pairing is commit, then reveal: a commitment gets the app's key and a fresh nonce (and shows nothing yet); a nonce
# that does not match the commitment gets 400 and ends the exchange.
b64u() { openssl rand "$1" | base64 | tr '+/' '-_' | tr -d '=\n'; }
RAW_ID="$(b64u 16)"
RAW_KEY="$(b64u 32)"
COMMIT_REPLY="$(curl -s --noproxy '*' --max-time 5 -X POST -H 'Content-Type: application/json' \
  --data "{\"v\":2,\"client_id\":\"$RAW_ID\",\"client_name\":\"mcp-smoke raw\",\"client_key\":\"$RAW_KEY\",\"commit\":\"$(b64u 32)\"}" \
  "http://127.0.0.1:$PORT/pair")"
printf '%s' "$COMMIT_REPLY" | jq -e '.v == 2 and .status == "reveal" and (.app_key | length) == 43 and (.app_nonce | length) == 22 and (keys | length) == 4' >/dev/null &&
  pass "2 raw HTTP: a pairing commitment gets the app's key and a fresh nonce" ||
  fail "2 raw HTTP: commit: $(printf '%s' "$COMMIT_REPLY" | head -c 200)"
code="$(http_code /pair -X POST -H 'Content-Type: application/json' \
  --data "{\"v\":2,\"client_id\":\"$RAW_ID\",\"client_key\":\"$RAW_KEY\",\"reveal\":\"$(b64u 16)\"}")"
[ "$code" = 400 ] && pass "2 raw HTTP: a reveal that does not match the commitment gets 400" ||
  fail "2 raw HTTP: wrong reveal got $code, expected 400"
code="$(http_code /pair -X POST --data '{"v":1,"client_id":"x","client_name":"x","client_key":"x"}' -H 'Content-Type: application/json')"
[ "$code" = 400 ] && pass "2 raw HTTP: the old one-step pairing request gets 400" || fail "2 raw HTTP: one-step /pair got $code, expected 400"

# 3. Through the helper: the handshake (answered by the helper), then a call from an unpaired Claude app, which
# sends a pairing request and asks the user for permission with a code.
printf '%s\n' "$INIT" "$INITIALIZED" "$TOOLS" "$DISCOVER" "$LIST" | helper_session 15 4
lines="$(grep -c . "$WORK/out")"
[ "$lines" = 4 ] && pass "3 helper: 4 replies, none for the notification" || fail "3 helper: $lines replies, expected 4"
reply 1 | jq -e '.result.protocolVersion == "2025-11-25"' >/dev/null &&
  pass "3 helper: initialize answers 2025-11-25" || fail "3 helper: initialize: $(reply 1 | head -c 300)"
reply 2 | jq -e '.result.tools | length == 2' >/dev/null &&
  pass "3 helper: tools/list has 2 tools" || fail "3 helper: tools/list: $(reply 2 | head -c 300)"
reply 3 | jq -e '.error.code == -32601' >/dev/null &&
  pass "3 helper: server/discover is -32601" || fail "3 helper: server/discover: $(reply 3 | head -c 300)"
TEXT="$(reply_text 4)"
CODE="$(code_in "$TEXT")"
if [[ "$TEXT" == "Transcribe needs your permission"* ]] && [ -n "$CODE" ] && reply 4 | jq -e '.result.isError == true' >/dev/null; then
  pass "3 unpaired: the call asks for permission with code $CODE"
else
  fail "3 unpaired: $(reply 4 | head -c 300)"
fi
FILES="$(state_files)"
if [ "$(printf '%s\n' "$FILES" | grep -c .)" = 1 ] && [ "$(stat -f %Lp "$STATE")" = 700 ] &&
  [ "$(stat -f %Lp "$STATE/$FILES")" = 600 ]; then
  pass "3 unpaired: one pairing file ($FILES, 0600) in a 0700 state folder"
else
  fail "3 unpaired: state folder: $(ls -la "$STATE" 2>&1 | head -5)"
fi

# 4. Until the user clicks Allow, every call is refused, with the same code. (A new helper process, as Claude starts
# one per session: the pairing is found again by the client name in initialize.)
printf '%s\n' "$INIT" "$LIST" "$(get 7D1C0A2E-6F7B-4C55-9B1A-2E0F1D3C4B5A)" | helper_session 15 3
TEXT4="$(reply_text 4)"
TEXT5="$(reply_text 5)"
if [[ "$TEXT4" == "Transcribe is still waiting"* ]] && [ "$(code_in "$TEXT4")" = "$CODE" ] &&
  [[ "$TEXT5" == "Transcribe is still waiting"* ]] && [[ "$TEXT5$TEXT4" != *"[0:"* ]] && [[ "$TEXT4" != *"id: "* ]]; then
  pass "4 not allowed: list_recordings and get_transcript are refused (\"still waiting\", code $CODE)"
else
  fail "4 not allowed: $(reply 4 | head -c 200) / $(reply 5 | head -c 200)"
fi

# 5. Relaunch with Allow automatic (the DEBUG hook, session only). A session like this saves nothing, so the new one
# has a new key of its own: it cannot verify the helper's calls and says "unknown", unsigned. The helper's pairing has
# never had a verified answer (it was only ever pending), so it is replaced: the helper pairs again by itself (allowed
# at once) and both tools answer.
kill_started
launch_app 5 --env TRANSCRIBE_MCP_AUTO_ALLOW=on
client_id() { jq -r '.client_id' "$STATE/$FILES" 2>/dev/null; }
OLD_ID="$(client_id)"
printf '%s\n' "$INIT" "$LIST" | helper_session 15 2
LIST_TEXT="$(reply_text 4)"
first_id() { printf '%s\n' "$1" | sed -n 's/^ *id: \([0-9A-Fa-f-]\{36\}\)$/\1/p' | head -n 1; }
# The server is up from App.init, before the app seeds the fake library, so the first list can be empty.
FIRST_ID="$(first_id "$LIST_TEXT")"
T0="$(now)"
while [ -z "$FIRST_ID" ] && less_than "$(seconds_since "$T0")" 20; do
  sleep 0.5
  printf '%s\n' "$INIT" "$LIST" | helper_session 15 2
  LIST_TEXT="$(reply_text 4)"
  FIRST_ID="$(first_id "$LIST_TEXT")"
done
if [ -n "$FIRST_ID" ] && reply 4 | jq -e '.result.isError == null' >/dev/null && [ "$(client_id)" != "$OLD_ID" ]; then
  pass "5 allowed: the unconfirmed pairing was replaced by itself, and list_recordings answers"
else
  fail "5 allowed: no recording id in the list after 20 s: $(printf '%s' "$LIST_TEXT" | head -c 200)"
fi
if [ -n "$FIRST_ID" ]; then
  # The list can come from the last run's store; the seed then deletes and re-creates the same ids, so a read that
  # lands while it runs finds nothing: try again for a while.
  T0="$(now)"
  while :; do
    printf '%s\n' "$INIT" "$(get "$FIRST_ID")" | helper_session 15 2
    reply 5 | jq -e '.result.isError == null' >/dev/null || ! less_than "$(seconds_since "$T0")" 20 || { sleep 0.5; continue; }
    break
  done
  if [[ "$(reply_text 5)" == *"[0:"* ]] && reply 5 | jq -e '.result.isError == null' >/dev/null; then
    pass "5 allowed: get_transcript answers with timed lines"
  else
    fail "5 allowed: get_transcript: $(reply 5 | head -c 300)"
  fi
fi
[ "$(state_files)" = "$FILES" ] && pass "5 allowed: the same Claude app kept its one pairing file" ||
  fail "5 allowed: pairing files now: $(state_files | tr '\n' ' ')"
[ "$(jq -r '.verified' "$STATE/$FILES" 2>/dev/null)" = true ] && pass "5 allowed: the pairing is marked verified" ||
  fail "5 allowed: the pairing file is not marked verified"

# 5b. Relaunched again (another new key): the pairing has now been verified, so an unsigned "unknown" never replaces
# it; the helper says what to do, and doing that (deleting its state folder), it pairs again and reads.
kill_started
launch_app 5b --env TRANSCRIBE_MCP_AUTO_ALLOW=on
VERIFIED_ID="$(client_id)"
printf '%s\n' "$INIT" "$LIST" | helper_session 15 2
if [[ "$(reply_text 4)" == "Something answered for Transcribe"* ]] && [ "$(client_id)" = "$VERIFIED_ID" ]; then
  pass "5b new app key: an unsigned \"unknown\" keeps the verified pairing and says what to do"
else
  fail "5b new app key: $(reply 4 | head -c 300)"
fi
rm -f "$STATE"/*.json
T0="$(now)"
while :; do
  printf '%s\n' "$INIT" "$LIST" | helper_session 15 2
  [ -n "$(first_id "$(reply_text 4)")" ] || ! less_than "$(seconds_since "$T0")" 20 || { sleep 0.5; continue; }
  break
done
if [ -n "$(first_id "$(reply_text 4)")" ] && reply 4 | jq -e '.result.isError == null' >/dev/null; then
  pass "5b state deleted: the helper pairs again and list_recordings answers"
else
  fail "5b state deleted: $(reply 4 | head -c 300)"
fi

# 6. Another Claude app (another clientInfo name) gets a pairing of its own.
printf '%s\n' "$(init mcp-smoke-2)" "$LIST" | helper_session 15 2
if [[ "$(reply_text 4)" == *recordings* ]] && reply 4 | jq -e '.result.isError == null' >/dev/null &&
  [ "$(state_files | grep -c .)" = 2 ]; then
  pass "6 second app: its own pairing file, and it reads"
else
  fail "6 second app: $(reply 4 | head -c 200); files: $(state_files | tr '\n' ' ')"
fi

# 7. With the app quit, a DEBUG helper (no TRANSCRIBE_MCP_DEBUG_LAUNCH) never launches it.
kill_started
OTHERS="$(pgrep -x Transcribe | sort | tr '\n' ' ')"
printf '%s\n' "$LIST" | helper_session 10 1
ELAPSED="$(cat "$WORK/elapsed")"
AFTER="$(pgrep -x Transcribe | sort | tr '\n' ' ')"
TEXT="$(reply_text 4)"
if [ "$AFTER" != "$OTHERS" ]; then
  fail "7 no launch: a Transcribe process started or ended during the call"
elif [ -z "$OTHERS" ]; then
  [[ "$TEXT" == *"isn't open"* ]] && less_than "$ELAPSED" 1 &&
    pass "7 no launch: \"isn't open\" in ${ELAPSED}s, nothing launched" || fail "7 no launch: ${ELAPSED}s: $TEXT"
else
  # Another copy (not started here, such as /Applications/Transcribe.app) is running: the helper retries it for
  # about a second and answers "isn't sharing", still without launching anything.
  [[ "$TEXT" == *"isn't sharing"* ]] && less_than "$ELAPSED" 3 &&
    pass "7 no launch: another copy is running, so \"isn't sharing\" in ${ELAPSED}s, nothing launched" ||
    fail "7 no launch: ${ELAPSED}s: $TEXT"
fi

# 8. The helper's fake launch, in the background, only when no copy of Transcribe is running at all. It starts the
# fake engine on this port with Allow automatic, so the helper pairs again and reads.
if [ -n "$(pgrep -x Transcribe)" ]; then
  echo "SKIP 8 auto-launch: another copy of Transcribe is running"
else
  FRONT_BEFORE="$(lsappinfo info -only name "$(lsappinfo front)")"
  BEFORE="$(app_pids)"
  printf '%s\n' "$LIST" | helper_session 15 1 TRANSCRIBE_MCP_DEBUG_LAUNCH=fake
  ELAPSED="$(cat "$WORK/elapsed")"
  wait_for_new_pids "$BEFORE" 1 >/dev/null
  FRONT_AFTER="$(lsappinfo info -only name "$(lsappinfo front)")"
  if [[ "$(reply_text 4)" == *recordings* ]] && reply 4 | jq -e '.result.isError == null' >/dev/null &&
    less_than "$ELAPSED" 13; then
    pass "8 auto-launch: answered in ${ELAPSED}s"
  else
    fail "8 auto-launch: ${ELAPSED}s: $(reply 4 | head -c 300)"
  fi
  [ "$FRONT_AFTER" = "$FRONT_BEFORE" ] && pass "8 auto-launch: the frontmost app did not change" ||
    fail "8 auto-launch: the frontmost app changed ($FRONT_BEFORE → $FRONT_AFTER)"
  kill_started
fi

if [ "$FAILED" = 0 ]; then
  echo "PASS all steps"
  exit 0
fi
echo "FAIL (see above)"
exit 1
