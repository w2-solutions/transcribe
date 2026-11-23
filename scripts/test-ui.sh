#!/usr/bin/env bash
# XCUITest on the iPhone 15 (iOS 27.0) simulator with the fake engine.
# Example: ./scripts/test-ui.sh -only-testing:TranscribeUITests/SmokeTests
#
# Environment:
#   SIM_UDID  run on this simulator instead of the shared "iPhone 15" (iOS 27.0)
#   WORKERS   parallel simulator clones (default 3; the full suite takes about 5 min, 9 min with WORKERS=1)
#   DERIVED   DerivedData path (default $TMPDIR/transcribe-dd)
set -euo pipefail
cd "$(dirname "$0")/.."
DEST="platform=iOS Simulator,name=iPhone 15,OS=27.0"
[ -n "${SIM_UDID:-}" ] && DEST="platform=iOS Simulator,id=$SIM_UDID"
WORKERS="${WORKERS:-3}"
if [ "$WORKERS" -gt 1 ]; then
  PARALLEL=(-parallel-testing-enabled YES -parallel-testing-worker-count "$WORKERS")
else
  PARALLEL=(-parallel-testing-enabled NO)
fi
xcodebuild -project Transcribe.xcodeproj -scheme Transcribe \
  -destination "$DEST" "${PARALLEL[@]}" \
  -derivedDataPath "${DERIVED:-${TMPDIR:-/tmp}/transcribe-dd}" test "$@"
