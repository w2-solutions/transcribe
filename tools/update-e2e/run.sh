#!/bin/bash
# End-to-end test of the Mac app's in-app updates (Sparkle). A Release build of version 0.2.9 (209) updates itself
# to 0.3.0 (300) from a feed on 127.0.0.1, through the same signing and publishing scripts as a real release: the
# scheduled check after Check Automatically shows only the quiet reminder (no update window); Update Available… brings
# up the update, stays after Remind Me Later, and installs it. Then three negatives through Check for Updates…,
# each from a fresh 0.2.9: a tampered DMG, a tampered feed and an unsigned feed. 15 to 30 minutes. Not run in CI.
#
#   tools/update-e2e/run.sh                  the local test (unlocked screen; it clicks through Sparkle's windows)
#   tools/update-e2e/run.sh --developer-id   prepares the owner's Developer ID update test for a second macOS user
#
# Local test: everything is throwaway and kept apart from the real app. The bundle id is
# ai.w2solutions.transcribe.updatetest (its own sandbox container), the update key a seed made for this run (never
# generate_keys, never the keychain), the feed http://127.0.0.1:8788/transcribe/appcast.xml. The builds are Release
# (the updater exists only there), signed to run locally. It never touches /Applications/Transcribe.app, the real
# container or library, the real feed or the real key. It checks every header the update check and the download
# send, and prints them. Clean-up always runs: the app quit, the server stopped, the builds, the installed copy, the
# test container and the seed deleted.
#
# --developer-id (owner-run, before publishing a release): builds TEST 0.2.9 and 0.3.0 with make release-mac (Developer
# ID, notarised, the real bundle id, a throwaway key and the localhost feed), signs and publishes 0.3.0 to a folder,
# puts the old DMG, the feed and the server in /Users/Shared/transcribe-update-test, deletes the seed and the build
# outputs, and prints the steps for a separate macOS user (who installs into their own ~/Applications).
#
# Environment:
#   E2E            work folder, outside the repo (default $TMPDIR/transcribe-update-e2e); keeps requests-*.log and
#                  shots/ afterwards
#   FROM           passed to make models (copy model files you already have instead of downloading)
#   KEEP_BUILDS=1  local test only: keep the seed, the builds and the feed for a re-run (delete $E2E yourself)
#
# Exit: 0 passed (or prepared); 1 a check failed; 2 bad arguments, or the Mac is not ready for the test.
# Runs on macOS /bin/bash 3.2; needs Xcode, xcodegen, jq, python3, hdiutil, osascript (Accessibility for the
# terminal) and screencapture.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd -P)"
SELF="$ROOT/tools/update-e2e/$(basename "$0")"
BID=ai.w2solutions.transcribe.updatetest
PORT=8788
FEED_URL="http://127.0.0.1:$PORT/transcribe/appcast.xml"
DOWNLOAD_PREFIX="http://127.0.0.1:$PORT/transcribe/download/"
OLD_V=0.2.9
OLD_B=209
NEW_V=0.3.0
NEW_B=300
SPARKLE_VERSION=2.10.1
SHARED=/Users/Shared/transcribe-update-test
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
CONTAINER="$HOME/Library/Containers/$BID"

usage() {
  sed -n '2,30s/^# \{0,1\}//p' "$SELF" >&2
  exit 2
}
step() { printf '\n==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
fatal() {
  echo "FAIL: $*" >&2
  exit 1
}
not_ready() {
  echo "error: $*" >&2
  exit 2
}
FAILS=0
# check DESCRIPTION COMMAND...: records a failed check and goes on.
check() {
  local what="$1"
  shift
  if "$@"; then
    printf '    PASS: %s\n' "$what"
  else
    printf '    FAIL: %s\n' "$what"
    FAILS=$((FAILS + 1))
  fi
}

MODE=local
case "${1-}" in
  "") ;;
  --developer-id) MODE=developer-id ;;
  -h | --help) usage ;;
  *) usage ;;
esac
[ $# -le 1 ] || usage

for tool in xcodebuild xcodegen jq python3 hdiutil osascript screencapture curl ditto; do
  command -v "$tool" >/dev/null || not_ready "$tool is missing"
done

mkdir -p "${E2E:=${TMPDIR:-/tmp}/transcribe-update-e2e}"
E2E="$(cd "$E2E" && pwd -P)"
case "$E2E/" in "$ROOT/"*) not_ready "E2E ($E2E) must be outside the repo" ;; esac
case "$E2E" in /Applications* | "$HOME/Library/Containers"*) not_ready "E2E ($E2E) is not a safe work folder" ;; esac

# The port must be free: something else answering there would be the feed.
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then not_ready "port $PORT is in use"; fi

# models: the Release builds need the verified models inside the app.
models() {
  step "Models"
  (cd "$ROOT" && make models ${FROM:+FROM="$FROM"}) >"$E2E/models.log" 2>&1 || { tail -20 "$E2E/models.log" >&2; fatal "make models"; }
  note "$(tail -1 "$E2E/models.log")"
}

# new_seed: a throwaway update key for this run (a file, never the keychain); sets PUB.
new_seed() {
  (umask 077 && openssl rand -base64 32 >"$E2E/seed")
  PUB="$(xcrun swift "$ROOT/scripts/ed25519.swift" public-key <"$E2E/seed")" || fatal "could not derive the public key"
}

# --- Developer ID mode ----------------------------------------------------------------------------------------------

if [ "$MODE" = developer-id ]; then
  [ ! -e "$SHARED" ] || not_ready "$SHARED exists: delete it first (rm -rf $SHARED)"
  RELEASE_DD="$E2E/release"
  # shellcheck disable=SC2329 # run by the trap below
  cleanup_developer_id() {
    if [ -d "$RELEASE_DD" ]; then
      find "$RELEASE_DD" -name '*.app' -type d -prune -exec "$LSREGISTER" -u {} \; 2>/dev/null || true
      rm -rf "$RELEASE_DD"
    fi
    rm -f "$E2E/seed" "$ROOT/dist/Transcribe-$OLD_V-TEST.dmg" "$ROOT/dist/Transcribe-$NEW_V-TEST.dmg"
    rm -rf "$E2E/dist"
  }
  trap cleanup_developer_id EXIT
  models
  new_seed
  for v in "$OLD_V" "$NEW_V"; do
    step "TEST release $v (Developer ID, notarised; never published)"
    (cd "$ROOT" && TRANSCRIBE_ED_PUBLIC_KEY="$PUB" TRANSCRIBE_TEST_VERSION="$v" TRANSCRIBE_FEED_URL="$FEED_URL" \
      DERIVED="$RELEASE_DD" FROM="${FROM:-}" ./scripts/release-mac.sh) || fatal "release-mac.sh for $v"
  done
  step "Sign and publish $NEW_V to a folder"
  mkdir -p "$SHARED"
  DIST="$E2E/dist" SPARKLE_ED_PRIVATE_KEY="$(cat "$E2E/seed")" "$ROOT/scripts/sign-mac-release.sh" --test \
    --download-prefix "$DOWNLOAD_PREFIX" "$ROOT/dist/Transcribe-$NEW_V-TEST.dmg" || fatal "sign-mac-release.sh"
  "$ROOT/scripts/publish-mac.sh" --release "$E2E/dist/Transcribe-$NEW_V-TEST.latest.json" \
    --dmg "$ROOT/dist/Transcribe-$NEW_V-TEST.dmg" --appcast "$E2E/dist/Transcribe-$NEW_V-TEST.appcast.xml" \
    --dest "dir:$SHARED/feed" --public-key "$PUB" || fatal "publish-mac.sh"
  # The old app stays inside its DMG, so this account's Launch Services never registers a second copy of the real
  # bundle id.
  mv "$ROOT/dist/Transcribe-$OLD_V-TEST.dmg" "$SHARED/Transcribe-$OLD_V-TEST.dmg"
  cp "$ROOT/tools/update-e2e/feed-server.py" "$SHARED/feed-server.py"
  chmod -R a+rX "$SHARED"
  cat <<EOF

Prepared $SHARED (the seed and the build outputs are deleted). In a separate macOS user (never this one: the TEST
apps use the real bundle id), in Terminal:

  1. mkdir -p ~/Applications && hdiutil attach -nobrowse $SHARED/Transcribe-$OLD_V-TEST.dmg
     ditto "/Volumes/Transcribe/Transcribe.app" ~/Applications/Transcribe.app && hdiutil detach /Volumes/Transcribe
     (never /Applications: that would replace the real app for every user)
  2. python3 -I $SHARED/feed-server.py --root $SHARED/feed --port $PORT --log /tmp/transcribe-requests.log &
  3. open ~/Applications/Transcribe.app; wait for the window; then Transcribe → Check for Updates…,
     Install Update, and Install and Relaunch.
  4. Check: /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' ~/Applications/Transcribe.app/Contents/Info.plist
     prints $NEW_B, and codesign --verify --deep --strict ~/Applications/Transcribe.app prints nothing.
  5. Quit Transcribe, stop the server (kill %1), delete ~/Applications/Transcribe.app and
     ~/Library/Containers/ai.w2solutions.transcribe.mac in that user.

As soon as the test ends, in this account: rm -rf $SHARED
(every user of this Mac can read it, and it holds a notarised TEST build with the real bundle id and its signature)
EOF
  exit 0
fi

# --- Local test -----------------------------------------------------------------------------------------------------

INSTALLED="$E2E/Applications/Transcribe.app"
EXE="$INSTALLED/Contents/MacOS/Transcribe"
FEED="$E2E/feed"
LOG="$E2E/requests.log"
SHOTS="$E2E/shots"
SERVER_PID=""

if ioreg -n Root -d1 | grep -q '"IOConsoleLocked" = Yes'; then not_ready "the screen is locked (keep it unlocked for the whole run)"; fi
osascript -e 'tell application "System Events" to count processes' >/dev/null 2>&1 ||
  not_ready "osascript cannot use System Events (allow the terminal in Privacy & Security → Accessibility)"

# ax SCRIPT ARGS...: AppleScript against the test app's process, found by its bundle id (never by name). The script
# is the body of `on run argv` and sees `p` (the process, or missing value) and `argv` (ARGS).
ax() {
  local body="$1"
  shift
  osascript - "$BID" "$@" <<EOF
on run argv
  set bid to item 1 of argv
  set argv to rest of argv
  tell application "System Events"
    set ps to (every process whose bundle identifier is bid)
    if ps is {} then
      set p to missing value
    else
      set p to item 1 of ps
    end if
    $body
  end tell
end run
EOF
}

app_running() { [ "$(ax 'return p is not missing value')" = true ]; }
window_count() { ax 'if p is missing value then return 0
    return count of windows of p'; }

# click_button NAME: the first button so named in any window or sheet of the app; prints ok or none.
click_button() {
  ax 'if p is missing value then return "none"
    repeat with w in windows of p
      repeat with b in (buttons of w)
        if name of b is (item 1 of argv) then
          click b
          return "ok"
        end if
      end repeat
      repeat with s in sheets of w
        repeat with b in (buttons of s)
          if name of b is (item 1 of argv) then
            click b
            return "ok"
          end if
        end repeat
      end repeat
    end repeat
    return "none"' "$1"
}

# texts: the static texts directly in the app's windows and sheets (where Sparkle's alerts put theirs), one per line.
texts() {
  ax 'if p is missing value then return ""
    set out to {}
    repeat with w in windows of p
      try
        set out to out & (value of static texts of w)
      end try
      repeat with s in sheets of w
        try
          set out to out & (value of static texts of s)
        end try
      end repeat
    end repeat
    set AppleScript'"'"'s text item delimiters to linefeed
    return out as text'
}

# menu ITEM: clicks ITEM in the app menu (the menu bar item after the Apple menu).
menu() {
  ax 'set frontmost of p to true
    delay 0.5
    click menu item (item 1 of argv) of menu 1 of menu bar item 2 of menu bar 1 of p
    return "ok"' "$1" >/dev/null
}

# wait_for SECONDS COMMAND...: polls every 2 s.
wait_for() {
  local deadline=$((SECONDS + $1))
  shift
  until "$@"; do
    [ "$SECONDS" -lt "$deadline" ] || return 1
    sleep 2
  done
}
has_window() { [ "$(window_count)" -gt 0 ] 2>/dev/null; }
has_button() { [ "$(ax 'if p is missing value then return false
    repeat with w in windows of p
      if exists (first button of w whose name is (item 1 of argv)) then return true
    end repeat
    return false' "$1")" = true ]; }
has_text() { texts | grep -qF "$1"; }
# has_menu_item NAME: the app menu holds an item so named.
has_menu_item() { [ "$(ax 'if p is missing value then return false
    return exists menu item (item 1 of argv) of menu 1 of menu bar item 2 of menu bar 1 of p' "$1")" = true ]; }
feed_requests() { grep -c 'appcast.xml' "$LOG" || true; }
exe_running() { pgrep -f "^$EXE" >/dev/null; }
installed_build() { /usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INSTALLED/Contents/Info.plist" 2>/dev/null || true; }
is_build() { [ "$(installed_build)" = "$1" ]; }

# shot NAME: a screenshot of the app's front window only (not the whole screen), in shots/.
shot() {
  local rect
  rect="$(ax 'if p is missing value or (count of windows of p) is 0 then return ""
    set {x, y} to position of window 1 of p
    set {w, h} to size of window 1 of p
    return (x as text) & "," & (y as text) & "," & (w as text) & "," & (h as text)')" || true
  mkdir -p "$SHOTS"
  if [ -n "$rect" ]; then
    screencapture -x -R "$rect" "$SHOTS/$1.png" && note "screenshot: $SHOTS/$1.png"
  fi
}

screen_locked() { ioreg -n Root -d1 | grep -q '"IOConsoleLocked" = Yes'; }

launch() {
  open "$INSTALLED" || fatal "could not open $INSTALLED"
  if ! wait_for 120 has_window; then
    # System Events lists no windows while the screen is locked (it can lock by itself when the Mac sits idle).
    screen_locked && fatal "the screen locked during the test (System Events sees no windows then): unlock it and run again"
    fatal "no window within 2 minutes of launching"
  fi
}

quit_app() {
  app_running || return 0
  ax 'click menu item ("Quit " & name of p) of menu 1 of menu bar item 2 of menu bar 1 of p
    return "ok"' >/dev/null 2>&1 || true
  if ! wait_for 30 eval '! app_running'; then
    pkill -TERM -f "^$EXE" || true
    wait_for 15 eval '! app_running' || pkill -KILL -f "^$EXE" || true
  fi
}

install_old() {
  quit_app
  rm -rf "$INSTALLED"
  mkdir -p "$E2E/Applications"
  ditto "$E2E/build-$OLD_V/Transcribe.app" "$INSTALLED"
}

# save_log NAME: keeps the requests since the last save as requests-NAME.log.
save_log() {
  cp "$LOG" "$E2E/requests-$1.log"
  : >"$LOG"
}

# remove_container: the test container's data (Sparkle's settings, the library, the prepared models). macOS keeps
# the empty folder with its own protected metadata file, which holds no data.
remove_container() {
  case "$CONTAINER" in
    */Library/Containers/ai.w2solutions.transcribe.updatetest)
      rm -rf "$CONTAINER/Data"
      rm -rf "$CONTAINER" 2>/dev/null || true
      ;;
  esac
}

sparkle_log() { /usr/bin/log show --last "$1" --info --style compact --predicate 'subsystem == "org.sparkle-project.Sparkle"' 2>/dev/null | grep -v '^Timestamp' || true; }

cleanup() {
  local status=$?
  set +e
  step "Clean-up"
  quit_app
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null
    wait "$SERVER_PID" 2>/dev/null
  fi
  for app in "$INSTALLED" "$E2E/build-$OLD_V/Transcribe.app" "$E2E/build-$NEW_V/Transcribe.app" \
    "$E2E/dd/Build/Products/Release/Transcribe.app"; do
    [ -d "$app" ] && "$LSREGISTER" -u "$app" 2>/dev/null
  done
  rm -rf "$E2E/Applications"
  remove_container
  for d in "$HOME/Library/Caches/$BID" "$HOME/Library/Application Scripts/$BID" "$HOME/Library/HTTPStorages/$BID"; do
    case "$d" in *.updatetest) rm -rf "$d" ;; esac
  done
  if [ "${KEEP_BUILDS:-}" = 1 ]; then
    note "KEEP_BUILDS=1: kept the seed, builds and feed in $E2E (delete them yourself)"
  else
    rm -rf "$E2E/build-$OLD_V" "$E2E/build-$NEW_V" "$E2E/dd" "$FEED" "$E2E/dist" "$E2E"/*.dmg
    [ ! -f "$E2E/seed" ] || rm -P "$E2E/seed"
  fi
  note "left: $(find "$E2E" -mindepth 1 -maxdepth 1 -exec basename {} \; | tr '\n' ' ')"
  exit "$status"
}

# Never run beside another copy of the test app.
if app_running || exe_running; then not_ready "a copy of $BID is running: quit it first"; fi
trap cleanup EXIT
remove_container
rm -rf "$SHOTS" "$E2E"/requests*.log "$E2E"/sparkle-*.log

# 1-3. Models, key and the two builds (reused with KEEP_BUILDS=1 when they trust the kept seed).

# build VERSION BUILD: a Release build signed to run locally, with the test bundle id, feed and key.
build() {
  local v="$1" b="$2" out="$E2E/build-$1" product="$E2E/dd/Build/Products/Release/Transcribe.app"
  step "Build $v ($b)"
  # $() expands to nothing on the xcodebuild line; it stops "//" from being read as the start of a comment.
  # shellcheck disable=SC2016
  (cd "$ROOT" && xcodebuild -project Transcribe.xcodeproj -scheme TranscribeMac -configuration Release \
    -destination 'generic/platform=macOS' -derivedDataPath "$E2E/dd" build \
    MARKETING_VERSION="$v" CURRENT_PROJECT_VERSION="$b" TRANSCRIBE_MAC_BUNDLE_ID="$BID" \
    TRANSCRIBE_FEED_URL='http:/$()/127.0.0.1:'"$PORT"'/transcribe/appcast.xml' TRANSCRIBE_ED_PUBLIC_KEY="$PUB" \
    DEVELOPMENT_TEAM= OTHER_CODE_SIGN_FLAGS=) >"$E2E/build-$v.log" 2>&1 ||
    { grep -E 'error:|\*\* BUILD' "$E2E/build-$v.log" | tail -20 >&2; fatal "xcodebuild for $v"; }
  grep -F '** BUILD SUCCEEDED **' "$E2E/build-$v.log" | sed 's/^/    /'
  rm -rf "$out"
  mkdir -p "$out"
  ditto "$product" "$out/Transcribe.app"
  "$LSREGISTER" -u "$product" 2>/dev/null || true
  check_build "$v" "$b" "$out/Transcribe.app"
}

check_build() {
  local v="$1" b="$2" app="$3" plist="$3/Contents/Info.plist" ents
  pv() { /usr/libexec/PlistBuddy -c "Print :$1" "$plist" 2>/dev/null || true; }
  check "$v: version $v ($b)" test "$(pv CFBundleShortVersionString) $(pv CFBundleVersion)" = "$v $b"
  check "$v: bundle id $BID" test "$(pv CFBundleIdentifier)" = "$BID"
  check "$v: SUFeedURL $FEED_URL" test "$(pv SUFeedURL)" = "$FEED_URL"
  check "$v: SUPublicEDKey is this run's key" test "$(pv SUPublicEDKey)" = "$PUB"
  check "$v: SURequireSignedFeed, no failure expiry" test "$(pv SURequireSignedFeed) $(plutil -extract SUSignedFeedFailureExpirationInterval raw "$plist")" = "true 0"
  check "$v: codesign --verify --deep --strict" codesign --verify --deep --strict "$app"
  check "$v: Sparkle.framework embedded" test -d "$app/Contents/Frameworks/Sparkle.framework"
  ents="$(codesign -d --entitlements - --xml "$app" 2>/dev/null | plutil -convert json -o - - 2>/dev/null || true)"
  check "$v: network.client and mach-lookup $BID-spks/-spki" test "$(jq -c '[.["com.apple.security.network.client"],
    (.["com.apple.security.temporary-exception.mach-lookup.global-name"] | sort)]' <<<"$ents")" = "[true,[\"$BID-spki\",\"$BID-spks\"]]"
}

if [ "${KEEP_BUILDS:-}" = 1 ] && [ -f "$E2E/seed" ] && [ -d "$E2E/build-$OLD_V/Transcribe.app" ] &&
  [ -d "$E2E/build-$NEW_V/Transcribe.app" ] && [ -f "$FEED/transcribe/appcast.xml" ]; then
  step "Reusing the kept seed, builds and feed (KEEP_BUILDS=1)"
  PUB="$(xcrun swift "$ROOT/scripts/ed25519.swift" public-key <"$E2E/seed")"
  check_build "$OLD_V" "$OLD_B" "$E2E/build-$OLD_V/Transcribe.app"
  check_build "$NEW_V" "$NEW_B" "$E2E/build-$NEW_V/Transcribe.app"
else
  models
  step "Throwaway update key"
  new_seed
  note "public key $PUB (seed in $E2E/seed, deleted at the end)"
  (cd "$ROOT" && xcodegen generate >/dev/null) || fatal "xcodegen generate"
  build "$OLD_V" "$OLD_B"
  build "$NEW_V" "$NEW_B"
  [ "$FAILS" = 0 ] || fatal "the builds are not as expected"

  # 4. The update DMG (as release-mac.sh makes it: UDZO, the app and an Applications link), signed the CI way.
  step "DMG of $NEW_V, signed with sign-mac-release.sh --test"
  ln -s /Applications "$E2E/build-$NEW_V/Applications"
  hdiutil create -quiet -volname Transcribe -srcfolder "$E2E/build-$NEW_V" -format UDZO -ov \
    "$E2E/Transcribe-$NEW_V-TEST.dmg" || fatal "hdiutil create"
  rm "$E2E/build-$NEW_V/Applications"
  DIST="$E2E/dist" SPARKLE_ED_PRIVATE_KEY="$(cat "$E2E/seed")" "$ROOT/scripts/sign-mac-release.sh" --test \
    --download-prefix "$DOWNLOAD_PREFIX" "$E2E/Transcribe-$NEW_V-TEST.dmg" || fatal "sign-mac-release.sh"

  # 5. The feed folder, written by publish-mac.sh.
  step "Publish to $FEED"
  rm -rf "$FEED"
  "$ROOT/scripts/publish-mac.sh" --release "$E2E/dist/Transcribe-$NEW_V-TEST.latest.json" \
    --dmg "$E2E/Transcribe-$NEW_V-TEST.dmg" --appcast "$E2E/dist/Transcribe-$NEW_V-TEST.appcast.xml" \
    --dest "dir:$FEED" --public-key "$PUB" || fatal "publish-mac.sh"
  rm -f "$E2E/Transcribe-$NEW_V-TEST.dmg"
fi
DMG="$FEED/transcribe/Transcribe-$NEW_V.dmg"
APPCAST="$FEED/transcribe/appcast.xml"
DMG_SHA="$(jq -r .sha256 "$FEED/transcribe/latest.json")"
cp "$APPCAST" "$E2E/appcast.good.xml"

step "Feed server on 127.0.0.1:$PORT"
: >"$LOG"
python3 -I "$ROOT/tools/update-e2e/feed-server.py" --root "$FEED" --port "$PORT" --log "$LOG" &
SERVER_PID=$!
wait_for 20 curl -fs -o /dev/null "$FEED_URL" || fatal "the feed server did not answer"
check "the server serves the feed byte for byte" cmp -s <(curl -fsS "$FEED_URL") "$APPCAST"
: >"$LOG"

# 6. Install 0.2.9 and launch it twice: the second launch that opens a window shows Sparkle's permission prompt.
step "Install $OLD_V; first launch (no permission prompt yet)"
install_old
launch
note "window open; the real engine prepares its models in the test container"
sleep 10
check "no permission prompt on the first launch" eval '! has_button "Check Automatically"'
quit_app
check "the app quit" eval '! app_running'
check "nothing requested on the first launch" test ! -s "$LOG"

step "Second launch: Sparkle's permission prompt"
open "$INSTALLED"
if wait_for 90 has_button "Check Automatically"; then
  printf '    PASS: %s\n' "the permission prompt appears on the second launch"
  shot permission-prompt
  texts | grep . | sed 's/^/    text: /'
  check "the prompt offers Don’t Check" has_button "Don’t Check"
  [ "$(click_button "Check Automatically")" = ok ] || fatal "could not click Check Automatically"
else
  printf '    FAIL: %s\n' "no permission prompt within 90 s of the second launch"
  FAILS=$((FAILS + 1))
fi
wait_for 60 has_window || fatal "no window on the second launch"

# 7. Allowing automatic checks starts a scheduled check at once, "in immediate focus" (just after launch), where
# Sparkle would show its update window by itself. The app shows only its quiet reminder instead (D23).
step "Scheduled check: the reminder, no update window"
wait_for 90 grep -q 'appcast.xml' "$LOG" || fatal "no scheduled check within 90 s of Check Automatically"
note "the scheduled check fetched the feed"
if wait_for 60 has_menu_item "Update Available…"; then
  printf '    PASS: %s\n' "the app menu reads Update Available…"
else
  printf '    FAIL: %s\n' "no Update Available… in the app menu within 60 s of the scheduled check"
  FAILS=$((FAILS + 1))
fi
sleep 10
check "no update window opened by itself" eval '! has_button "Install Update"'
check "Check for Updates… is replaced while the update waits" eval '! has_menu_item "Check for Updates…"'
shot update-reminder

# 8. Update Available… brings up Sparkle's window for the waiting update; Remind Me Later keeps the reminder.
# The sidebar chip calls the same AppUpdater.checkForUpdates(); its presence, label and identifier are covered by
# MacUpdatesTests (XCUITest). This test drives the reminder through the app menu because System Events cannot read the
# SwiftUI sidebar (the chip shows in shots/update-reminder.png, but System Events reports no identifier or label).
step "Update Available…; Remind Me Later keeps it"
menu "Update Available…"
wait_for 90 has_button "Install Update" || { texts >&2; fatal "no update offered within 90 s"; }
check "the reminder showed the waiting update without checking again" test "$(feed_requests)" = 1
shot remind-later-alert
check "the alert offers Remind Me Later (automatic checks are on)" has_button "Remind Me Later"
[ "$(click_button "Remind Me Later")" = ok ] || fatal "could not click Remind Me Later"
check "the update window closed" wait_for 30 eval '! has_button "Install Update"'
sleep 3
check "after Remind Me Later the app menu still reads Update Available…" has_menu_item "Update Available…"

# 9. Chosen again, it checks again (Sparkle ended the session at Remind Me Later): Install Update, Install and Relaunch.
step "Update $OLD_V → $NEW_V through Update Available…"
menu "Update Available…"
wait_for 90 has_button "Install Update" || { texts >&2; fatal "no update offered within 90 s"; }
check "chosen after Remind Me Later, the reminder checked the feed again" test "$(feed_requests)" = 2
shot update-alert
check "the alert offers $NEW_V to $OLD_V" has_text "Transcribe $NEW_V is now available—you have $OLD_V."
click_button "Install Update" >/dev/null
note "downloading and extracting (the DMG is about $(($(stat -f %z "$DMG") / 1000000)) MB)"
wait_for 600 has_button "Install and Relaunch" || { texts >&2; fatal "not ready to install within 10 minutes"; }
shot ready-to-install
click_button "Install and Relaunch" >/dev/null
if wait_for 300 is_build "$NEW_B"; then
  printf '    PASS: %s\n' "the installed app is $NEW_V ($NEW_B) within 5 minutes"
else
  printf '    FAIL: %s\n' "the installed app is still build $(installed_build) after 5 minutes"
  FAILS=$((FAILS + 1))
fi
check "the updated app relaunched from $INSTALLED" wait_for 120 exe_running
check "the updated app: codesign --verify --deep --strict" codesign --verify --deep --strict "$INSTALLED"
sparkle_log 15m >"$E2E/sparkle-positive.log"
check "Sparkle checked the feed's signature (in the app)" grep -q 'OK: EdDSA signature is correct for appcast' "$E2E/sparkle-positive.log"
check "Sparkle checked the DMG's signature (in Autoupdate)" grep -q 'Autoupdate.*OK: EdDSA signature is correct for update' "$E2E/sparkle-positive.log"
grep -F 'OK: EdDSA' "$E2E/sparkle-positive.log" | cut -c1-160 | sed 's/^/    log: /' || true
save_log positive

# requests_ok LOG DMG [show]: every request in LOG is a GET or HEAD of the feed, or of DMG when DMG is not empty,
# with no query string, only the allowed headers (no cookie or authorization), the expected User-Agent and no header
# value holding the user's or the computer's name; the feed was fetched, and the DMG too when named. show prints
# every request with its headers.
requests_ok() {
  python3 -I - "$1" "$USER" "$(scutil --get ComputerName 2>/dev/null || true)" "Transcribe/$OLD_V Sparkle/$SPARKLE_VERSION" \
    "$2" "${3:-}" <<'EOF'
import json, sys
log, user, computer, agent, dmg, show = sys.argv[1:7]
allowed = {"host", "user-agent", "accept", "accept-language", "accept-encoding", "connection", "if-none-match",
           "if-modified-since", "cache-control", "pragma", "priority"}
requests = [json.loads(line) for line in open(log) if line.strip()]
ok = True
def bad(msg):
    global ok
    ok = False
    print("      bad: " + msg)
seen = set()
for r in requests:
    names = [n.lower() for n, _ in r["headers"]]
    if show == "show":
        print("      %s %s%s" % (r["method"], r["path"], ("?" + r["query"]) if r["query"] else ""))
        for n, v in r["headers"]:
            print("        %s: %s" % (n, v))
    if r["method"] not in ("GET", "HEAD"):
        bad("method " + r["method"])
    seen.add((r["method"], r["path"]))
    if r["query"]:
        bad("query string on " + r["path"])
    if r["path"] != "/transcribe/appcast.xml" and not (dmg and r["path"] == "/transcribe/download/" + dmg):
        bad("unexpected path " + r["path"])
    for n in names:
        if n not in allowed:
            bad("header " + n + " is not in the allowed set")
    if "cookie" in names or "authorization" in names:
        bad("cookie or authorization sent")
    ua = dict((n.lower(), v) for n, v in r["headers"]).get("user-agent", "")
    if not ua.startswith(agent):
        bad("user agent " + ua)
    for n, v in r["headers"]:
        for secret in (user, computer):
            if secret and secret.lower() in v.lower():
                bad("header %s carries the user or computer name" % n)
for need in [("GET", "/transcribe/appcast.xml")] + ([("GET", "/transcribe/download/" + dmg)] if dmg else []):
    if need not in seen:
        bad("no %s %s" % need)
sys.exit(0 if ok else 1)
EOF
}

# The request logs: what an update check and a download send.
step "Requests (every header)"
check "positive: the requests are as the privacy wording says" requests_ok "$E2E/requests-positive.log" "Transcribe-$NEW_V.dmg" show

# 9. Negative tests, each from a fresh 0.2.9 install. The feed files are changed in place, then put back.

# no_grace_recorded: Sparkle read SUSignedFeedFailureExpirationInterval as 0, so a failed feed signature never
# starts a grace period (with any other value the first failure records this date). The app's preferences must be
# readable (Sparkle's SUHasLaunchedBefore), so a wrong path cannot pass.
no_grace_recorded() {
  local prefs="$CONTAINER/Data/Library/Preferences/$BID"
  defaults read "$prefs" SUHasLaunchedBefore >/dev/null 2>&1 &&
    ! defaults read "$prefs" SUInitialFailedFeedSigningValidationDate >/dev/null 2>&1
}
not_signed() { ! grep -q sparkle-signatures "$1"; }

# expect_rejected NAME TEXT: Check for Updates… shows TEXT, no update is offered or installed.
expect_rejected() {
  local name="$1" text="$2"
  install_old
  launch
  menu "Check for Updates…"
  if wait_for 120 has_text "$text"; then
    printf '    PASS: %s\n' "$name: Sparkle says '$text'"
  else
    printf '    FAIL: %s\n' "$name: no '$text' within 2 minutes"
    texts | sed 's/^/      text: /'
    FAILS=$((FAILS + 1))
  fi
  shot "$name"
  check "$name: no update offered" eval '! has_button "Install Update"'
  dismiss_error
  check "$name: the installed app is still $OLD_B" is_build "$OLD_B"
  check "$name: no grace period recorded for a bad feed signature" no_grace_recorded
  quit_app
  save_log "$name"
  check "$name: the requests are as the privacy wording says" requests_ok "$E2E/requests-$name.log" ""
}

# dismiss_error: Sparkle's error alert has OK, or Cancel Update once a download started.
dismiss_error() {
  [ "$(click_button OK)" = ok ] || click_button "Cancel Update" >/dev/null || true
}

# flip_byte FILE: inverts the byte in the middle of FILE in place (twice puts it back).
flip_byte() {
  python3 -I -c 'import os, sys
f = open(sys.argv[1], "r+b"); n = os.path.getsize(sys.argv[1]) // 2
f.seek(n); b = f.read(1); f.seek(n); f.write(bytes([b[0] ^ 0xFF])); f.close()' "$1"
}

step "Negative 1: the DMG with one byte changed"
flip_byte "$DMG"
check "the DMG differs, same length" test "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" != "$DMG_SHA"
install_old
launch
menu "Check for Updates…"
if wait_for 90 has_button "Install Update"; then
  click_button "Install Update" >/dev/null
  if wait_for 600 has_text "The update is improperly signed"; then
    printf '    PASS: %s\n' "tampered DMG: Sparkle says 'The update is improperly signed...'"
  else
    printf '    FAIL: %s\n' "tampered DMG: no 'improperly signed' within 10 minutes"
    texts | sed 's/^/      text: /'
    FAILS=$((FAILS + 1))
  fi
  shot tampered-dmg
  check "tampered DMG: never ready to install" eval '! has_button "Install and Relaunch"'
  dismiss_error
else
  printf '    FAIL: %s\n' "tampered DMG: no update offered (the feed is untouched)"
  FAILS=$((FAILS + 1))
fi
sleep 5
check "tampered DMG: the installed app is still $OLD_B" is_build "$OLD_B"
check "tampered DMG: codesign of the installed app still valid" codesign --verify --deep --strict "$INSTALLED"
quit_app
save_log tampered-dmg
check "tampered DMG: the requests are as the privacy wording says" requests_ok "$E2E/requests-tampered-dmg.log" "Transcribe-$NEW_V.dmg"
flip_byte "$DMG"
check "the DMG is back to its signed bytes" test "$(shasum -a 256 "$DMG" | cut -d' ' -f1)" = "$DMG_SHA"

step "Negative 2: the feed with one character changed"
sed 's|<title>Transcribe for Mac</title>|<title>Transcribe for Mbc</title>|' "$E2E/appcast.good.xml" >"$APPCAST"
check "one character changed, same length" test "$(cmp -l "$E2E/appcast.good.xml" "$APPCAST" | wc -l | tr -d ' ')" = 1
expect_rejected tampered-feed "The update feed is improperly signed"

step "Negative 3: the feed without its signature"
python3 -I -c 'import sys
d = open(sys.argv[1], "rb").read(); i = d.rindex(b"<!-- sparkle-signatures:")
open(sys.argv[2], "wb").write(d[:i])' "$E2E/appcast.good.xml" "$APPCAST"
check "the signature block is gone" not_signed "$APPCAST"
expect_rejected unsigned-feed "The update feed is improperly signed"
cp "$E2E/appcast.good.xml" "$APPCAST"

sparkle_log 60m | grep -i -E 'improperly|signature|validat' | tail -8 | cut -c1-220 | sed 's/^/    log: /' || true

step "Result"
if [ "$FAILS" = 0 ]; then
  echo "PASSED: the update end-to-end test (positive and three negatives)"
else
  echo "FAILED: $FAILS check(s)"
  exit 1
fi
