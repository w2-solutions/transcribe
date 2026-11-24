#!/bin/bash
# Archives the iPhone app (Release) and uploads it to App Store Connect for TestFlight.
#
# Signs and uploads with an App Store Connect API key, never the Apple account signed in to Xcode
# (that sign-in expires without warning). The key file is read by Apple's tools only:
#   ASC_KEY_ID      key id                     (default 93Y2L9PKNY, the "Transcribe CI" key)
#   ASC_ISSUER_ID   issuer id                  (default: the W2 team's)
#   ASC_KEY_PATH    path to AuthKey_<id>.p8    (default ~/.appstoreconnect/private_keys/AuthKey_<id>.p8)
#   BUILD_NUMBER    CFBundleVersion; must be higher than the last upload of this version
#                   (default: UTC date and time, e.g. 202611240412)
#   ARCHIVE         an existing .xcarchive to upload instead of building one
set -euo pipefail
cd "$(dirname "$0")/.."

TEAM=53FBF5CS9U
ASC_KEY_ID=${ASC_KEY_ID:-93Y2L9PKNY}
ASC_ISSUER_ID=${ASC_ISSUER_ID:-b275da4d-ed99-4de7-a5ae-8a8d8254e803}
ASC_KEY_PATH=${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}
BUILD_NUMBER=${BUILD_NUMBER:-$(date -u +%Y%m%d%H%M)}
WORK=${WORK:-${TMPDIR:-/tmp}/transcribe-testflight}
AUTH=(-allowProvisioningUpdates -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

[ -f "$ASC_KEY_PATH" ] || { echo "error: no API key file at $ASC_KEY_PATH" >&2; exit 2; }
mkdir -p "$WORK"

if [ -z "${ARCHIVE:-}" ]; then
  ARCHIVE="$WORK/Transcribe.xcarchive"
  # The archive's own pre-build phase (scripts/check-models.sh) fails it if the bundled models are missing or wrong.
  echo "==> 1/2 Archiving build $BUILD_NUMBER"
  xcodegen generate >/dev/null
  rm -rf "$ARCHIVE"
  xcodebuild -project Transcribe.xcodeproj -scheme Transcribe -configuration Release \
    -destination 'generic/platform=iOS' -derivedDataPath "$WORK/dd" -archivePath "$ARCHIVE" \
    DEVELOPMENT_TEAM=$TEAM CURRENT_PROJECT_VERSION="$BUILD_NUMBER" "${AUTH[@]}" archive > "$WORK/archive.log" 2>&1 \
    || { grep -E "error:|ARCHIVE" "$WORK/archive.log" | tail -20; echo "error: archive failed, see $WORK/archive.log" >&2; exit 1; }
fi

echo "==> 2/2 Uploading $(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' "$ARCHIVE/Info.plist") ($(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' "$ARCHIVE/Info.plist")) to App Store Connect"
rm -rf "$WORK/export"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist scripts/ExportOptions-TestFlight.plist \
  -exportPath "$WORK/export" "${AUTH[@]}" > "$WORK/upload.log" 2>&1 \
  || { grep -iE "^error|EXPORT|required|expired" "$WORK/upload.log" | tail -20; echo "error: upload failed, see $WORK/upload.log" >&2; exit 1; }
grep -iE "EXPORT SUCCEEDED|Upload succeeded|uploaded" "$WORK/upload.log" | tail -3
echo "Done. The build shows in TestFlight after Apple has processed it (10 to 30 minutes)."
