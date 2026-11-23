#!/usr/bin/env bash
# Ad-hoc screenshot loop on the simulator with the fake engine (§8.2).
#
#   ./scripts/sim.sh <seed> [route] [script] [speed]      one screenshot
#   ./scripts/sim.sh --mockups                            the nine mockup screens
#
# Mockup 5 types "Karan" into the focused name field and presses Return (needs axe), as in the mockup.
#
# Builds once (skipped when the app is newer than every source file), installs, launches with
# SIMCTL_CHILD_* variables and -useFakeEngine -uiTesting, waits for the screen, then saves a PNG to
# $SHOTS (default: $TMPDIR/transcribe-shots/<seed>-<route>.png).
#
# Environment: SIM_UDID (default: the shared iPhone 15 on iOS 27.0), DERIVED (DerivedData path),
# SHOTS (output folder), WAIT (seconds to settle after launch, default 3), PREFIX (file-name prefix for
# --mockups, e.g. PREFIX=final- gives final-1-library.png … final-9-settings.png).
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${SIM_UDID:-2BF544DF-B739-4ABD-9457-0C61D9C13E1A}"
DERIVED="${DERIVED:-${TMPDIR:-/tmp}/transcribe-dd}"
SHOTS="${SHOTS:-${TMPDIR:-/tmp}/transcribe-shots}"
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Transcribe.app"
BUNDLE=ai.w2solutions.transcribe
mkdir -p "$SHOTS"

build_if_needed() {
  local stamp="$DERIVED/.sim-built"
  if [ -d "$APP" ] && [ -f "$stamp" ] && [ -z "$(find Apps TranscribeKit/Sources project.yml -newer "$stamp" -type f 2>/dev/null | head -1)" ]; then
    return
  fi
  [ -d Transcribe.xcodeproj ] || xcodegen generate >/dev/null
  echo "Building…" >&2
  xcodebuild -project Transcribe.xcodeproj -scheme Transcribe -destination "platform=iOS Simulator,id=$UDID" \
    -derivedDataPath "$DERIVED" build -quiet >&2
  touch "$stamp"
}

# Waits up to 15 s for an accessibility identifier to appear (axe is optional; without it, sleeps).
wait_for() {
  local id="$1"
  if ! command -v axe >/dev/null; then sleep 3; return; fi
  for _ in $(seq 1 30); do
    # Capture first: with pipefail, grep -q closing the pipe early would fail the whole pipeline.
    local tree
    tree=$(axe describe-ui --udid "$UDID" 2>/dev/null || true)
    if [[ "$tree" == *"\"$id\""* ]]; then return; fi
    sleep 0.5
  done
  echo "warning: $id did not appear" >&2
}

screen_for_route() {
  case "${1:-}" in
    ""|-) echo library.screen ;;
    recording) echo recording.screen ;;
    transcript:*) echo transcript.screen ;;
    name:*) echo nameSpeaker.sheet ;;
    voices) echo voices.screen ;;
    voice:*) echo voiceDetail.screen ;;
    settings) echo settings.screen ;;
    models) echo modelSettings.screen ;;
    attributions) echo attributions.screen ;;
    *) echo library.screen ;;
  esac
}

shoot() {
  local seed="$1" route="${2:--}" script="${3:--}" speed="${4:-instant}" out="${5:-}" typed="${6:-}"
  local env=(SIMCTL_CHILD_TRANSCRIBE_SEED="$seed" SIMCTL_CHILD_TRANSCRIBE_SPEED="$speed"
             SIMCTL_CHILD_TRANSCRIBE_NOW="2026-11-18T14:31:00+11:00")
  [ "$route" != - ] && env+=(SIMCTL_CHILD_TRANSCRIBE_ROUTE="$route")
  [ "$script" != - ] && env+=(SIMCTL_CHILD_TRANSCRIBE_SCRIPT="$script")
  env "${env[@]}" xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE" \
    -useFakeEngine -uiTesting -AppleLocale en_AU -AppleLanguages '(en)' >/dev/null
  wait_for "$(screen_for_route "$route")"
  if [ -n "$typed" ] && command -v axe >/dev/null; then
    sleep 1                                              # the sheet focuses its field once it has settled
    printf '%s' "$typed" | axe type --stdin --udid "$UDID" >/dev/null
    axe key 40 --udid "$UDID" >/dev/null                 # Return: dismisses the keyboard
  fi
  sleep "${WAIT:-3}"
  local name="$seed-${route//[:\/]/_}"
  [ "$route" = - ] && name="$seed"
  [ -n "$out" ] && name="$out"
  xcrun simctl io "$UDID" screenshot "$SHOTS/$name.png" >/dev/null 2>&1
  echo "$SHOTS/$name.png"
}

[ $# -ge 1 ] || { echo "usage: $0 <seed> [route] [script] [speed] | --mockups" >&2; exit 2; }

xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
build_if_needed
xcrun simctl install "$UDID" "$APP"

if [ "$1" = "--mockups" ]; then
  P="${PREFIX:-}"
  # Same order as the mockups.
  shoot library                -                 -                instant "${P}1-library"
  shoot library                recording         -                frozen "${P}2-recording"
  shoot processingHeld         transcript:latest holdAtSeparating instant "${P}3-processing"
  shoot twoSpeakersUnnamed     transcript:latest -                instant "${P}4-transcript-unnamed"
  shoot twoSpeakersUnnamed     name:latest:S2    -                instant "${P}5-name-speaker" Karan
  shoot library                transcript:0      -                instant "${P}6-transcript-labelled"
  shoot library                voices            -                instant "${P}7-voices"
  shoot library                voice:Karan       -                instant "${P}8-voice-detail"
  shoot library                settings          -                instant "${P}9-settings"
else
  shoot "$@"
fi
