#!/bin/bash
# Builds the Developer ID release of the Mac app: archive, Developer ID export, signature checks, a signed DMG,
# then notarisation, stapling and a Gatekeeper check. The result is dist/Transcribe-<version>.dmg.
#
#   ./scripts/release-mac.sh                    everything (= make release-mac)
#   ./scripts/release-mac.sh --skip-notarize    stop after the signed, un-notarised DMG (exit 0)
#
# Environment:
#   DERIVED         build folder (default $TMPDIR/transcribe-release): derived data, the archive, the export
#   FROM            passed to make models (copy model files you already have instead of downloading)
#   NOTARY_PROFILE  notarytool keychain profile (default transcribe-notary)
#
# Notarisation needs a notarytool keychain profile, which only a person can create (an agent never handles the
# password). Create an app-specific password at account.apple.com, then run:
#   xcrun notarytool store-credentials transcribe-notary --apple-id <your Apple ID> --team-id 53FBF5CS9U
# Without the profile the script stops after the signed DMG and exits 3.
#
# Exit codes: 0 done; 1 a step or check failed; 2 bad arguments; 3 stopped before notarisation (no profile).
# Runs on macOS /bin/bash 3.2; needs Xcode, xcodegen and jq (/usr/bin/jq on macOS 15 and later).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "$0")"
cd "$ROOT"

TEAM=53FBF5CS9U
IDENTITY="Developer ID Application: Liam Wynne ($TEAM)"
BUNDLE_ID=ai.w2solutions.transcribe.mac
NOTARY_PROFILE="${NOTARY_PROFILE:-transcribe-notary}"
DD="${DERIVED:-${TMPDIR:-/tmp}/transcribe-release}"
DD="${DD%/}"
ARCHIVE="$DD/TranscribeMac.xcarchive"
EXPORT="$DD/export"
APP="$EXPORT/Transcribe.app"
ENTITLEMENTS_SRC="$ROOT/Apps/Mac/TranscribeMac.entitlements"

usage() {
  sed -n '2,19s/^# \{0,1\}//p' "$SELF" >&2
  exit "${1:-2}"
}

SKIP_NOTARIZE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    -h | --help) usage 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      ;;
  esac
  shift
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-mac.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

step() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }
fail() {
  echo "error: $*" >&2
  exit 1
}

# The Mac app's MARKETING_VERSION in project.yml: the one inside the TranscribeMac target (the iPhone has its own).
VERSION="$(awk '/^  TranscribeMac:/{mac=1} mac && /^[[:space:]]*MARKETING_VERSION:/{gsub(/["[:space:]]/,"",$2); print $2; exit}' project.yml)"
[ -n "$VERSION" ] || fail "no MARKETING_VERSION for TranscribeMac in project.yml"
DMG="$ROOT/dist/Transcribe-$VERSION.dmg"

# notary_state: prints "present", "missing" or "unknown: <message>". notarytool's history call needs the network
# when the profile exists; "missing" is the one answer that needs no network.
notary_state() {
  local out
  if out="$(xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" --output-format json 2>&1)"; then
    echo present
  elif grep -q 'No Keychain password item found' <<<"$out"; then
    echo missing
  else
    echo "unknown: $(printf '%s' "$out" | head -n 3 | tr '\n' ' ')"
  fi
}

notary_missing_message() {
  cat >&2 <<EOF

Stopped before notarisation: there is no notarytool keychain profile named "$NOTARY_PROFILE".
The DMG is signed with Developer ID but NOT notarised, so Gatekeeper on another Mac will block it:
  $DMG
  sha256 $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)

To finish the release (a person must do this; never pass the password through an agent):
  1. Create an app-specific password at https://account.apple.com (Sign-In and Security).
  2. Run, and type the password when asked:
       xcrun notarytool store-credentials $NOTARY_PROFILE --apple-id <your Apple ID> --team-id $TEAM
  3. Run make release-mac again.
EOF
}

NOTARY_EARLY=""
if [ "$SKIP_NOTARIZE" = 0 ]; then
  NOTARY_EARLY="$(notary_state)"
  case "$NOTARY_EARLY" in
    present) ;;
    missing) echo "warning: no notarytool profile \"$NOTARY_PROFILE\"; this run stops after the signed DMG (exit 3)." >&2 ;;
    *) echo "warning: could not check notarytool profile \"$NOTARY_PROFILE\" (${NOTARY_EARLY#unknown: }); trying anyway." >&2 ;;
  esac
fi

echo "Transcribe for Mac $VERSION, Developer ID release"
echo "build folder: $DD"

# 1. Models and project.
step "1/9 Bundled models and project"
make -C "$ROOT" models ${FROM:+FROM="$FROM"}
xcodegen generate

# 2. Release archive (signed automatically; the export re-signs with Developer ID).
step "2/9 Archive (Release)"
rm -rf "$ARCHIVE"
xcodebuild -project Transcribe.xcodeproj -scheme TranscribeMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates archive
[ -d "$ARCHIVE/Products/Applications/Transcribe.app" ] || fail "the archive has no Transcribe.app: $ARCHIVE"

# 3. The models inside the archived app (strict: sizes and sha256).
step "3/9 Models inside the archive"
./scripts/check-models.sh --app "$ARCHIVE/Products/Applications/Transcribe.app"

# 4. Developer ID export.
step "4/9 Developer ID export"
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions-DeveloperID.plist" -allowProvisioningUpdates
[ -d "$APP" ] || fail "the export has no Transcribe.app: $EXPORT"

# plist_value FILE KEY: the value, or nothing when the key is absent (PlistBuddy keys may contain dots).
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# check_signed_code PATH WHAT: Developer ID authority, our team, a secure timestamp; executables also need the
# hardened runtime. Prints one line per file.
check_signed_code() {
  local path="$1" what="$2" info
  info="$(codesign -dvvv "$path" 2>&1)" || fail "$what is not signed: $path"
  grep -Fxq "Authority=$IDENTITY" <<<"$info" || fail "$what is not signed by $IDENTITY: $path"
  grep -Fxq "TeamIdentifier=$TEAM" <<<"$info" || fail "$what has the wrong team: $path"
  grep -q '^Timestamp=' <<<"$info" || fail "$what has no secure timestamp: $path"
  case "$(file -b "$path")" in
    *executable*)
      grep -q '^CodeDirectory .*flags=0x[0-9a-f]*(.*runtime' <<<"$info" ||
        fail "$what is an executable without the hardened runtime: $path"
      ;;
  esac
}

# 5. Checks on the exported app. Any failure stops the release.
step "5/9 Signature, hardened runtime and entitlements"
codesign --verify --deep --strict -vv "$APP"
ok "codesign --verify --deep --strict"

INFO="$(codesign -dvvv "$APP" 2>&1)"
printf '%s\n' "$INFO" | grep -E '^(Identifier|Format|CodeDirectory|Authority|TeamIdentifier|Timestamp|Runtime Version)=|^CodeDirectory ' | sed 's/^/    /'
grep -Fq 'flags=0x10000(runtime)' <<<"$INFO" || fail "expected flags=0x10000(runtime) on $APP"
ok "flags=0x10000(runtime)"
grep -Fxq "Authority=$IDENTITY" <<<"$INFO" || fail "expected Authority=$IDENTITY"
ok "Authority=$IDENTITY"
grep -Fxq "Identifier=$BUNDLE_ID" <<<"$INFO" || fail "expected Identifier=$BUNDLE_ID"
grep -q '^Timestamp=' <<<"$INFO" || fail "the app signature has no secure timestamp"
ok "identifier $BUNDLE_ID, secure timestamp"

APP_VERSION="$(plist_value "$APP/Contents/Info.plist" CFBundleShortVersionString)"
[ "$APP_VERSION" = "$VERSION" ] || fail "the app's version is $APP_VERSION, project.yml says $VERSION"
ok "version $APP_VERSION (build $(plist_value "$APP/Contents/Info.plist" CFBundleVersion)), $(lipo -archs "$APP/Contents/MacOS/Transcribe")"

ENT="$WORK/entitlements.plist"
codesign -d --entitlements - --xml "$APP" >"$ENT" 2>/dev/null || fail "could not read the app's entitlements"
plutil -convert xml1 -o - "$ENT" | sed -n '/<dict>/,/<\/dict>/p' | sed 's/^/    /'
[ "$(plist_value "$ENT" com.apple.security.app-sandbox)" = true ] || fail "entitlements: app-sandbox is not true"
[ "$(plist_value "$ENT" com.apple.security.device.audio-input)" = true ] || fail "entitlements: audio-input is not true"
for key in com.apple.security.get-task-allow get-task-allow \
  com.apple.security.cs.allow-jit com.apple.security.cs.allow-unsigned-executable-memory \
  com.apple.security.cs.disable-library-validation com.apple.security.cs.allow-dyld-environment-variables \
  com.apple.security.cs.disable-executable-page-protection; do
  [ -z "$(plist_value "$ENT" "$key")" ] || fail "entitlements: $key must not be in a release build"
done
ok "app-sandbox and audio-input; no get-task-allow and no runtime exceptions"

# iCloud (stages 8a and 9): checked once the entitlements file asks for it.
if grep -q 'com.apple.developer.icloud-container-identifiers' "$ENTITLEMENTS_SRC"; then
  grep -q 'iCloud.ai.w2solutions.transcribe' "$ENT" ||
    fail "entitlements: no iCloud.ai.w2solutions.transcribe container"
  [ "$(plist_value "$ENT" com.apple.developer.icloud-container-environment)" = Production ] ||
    fail "entitlements: icloud-container-environment is not Production"
  # The archive carries "development" (its development profile allows nothing else); the export sets production.
  [ "$(plist_value "$ENT" com.apple.developer.aps-environment)" = production ] ||
    fail "entitlements: aps-environment is not production (the Developer ID export should set it from its profile)"
  [ -f "$APP/Contents/embedded.provisionprofile" ] || fail "no embedded.provisionprofile (iCloud needs one)"
  security cms -D -i "$APP/Contents/embedded.provisionprofile" >"$WORK/profile.plist" ||
    fail "could not decode embedded.provisionprofile"
  grep -q 'iCloud.ai.w2solutions.transcribe' "$WORK/profile.plist" ||
    fail "the embedded provisioning profile does not list iCloud.ai.w2solutions.transcribe"
  grep -q CloudKit.framework <<<"$(otool -L "$APP/Contents/MacOS/Transcribe")" ||
    fail "the binary does not link CloudKit.framework"
  ok "iCloud container (Production), push (production), provisioning profile and CloudKit link"
fi

# Every Mach-O file in the bundle (the models are not code, so their folder is skipped).
COUNT=0
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in
    Mach-O*)
      check_signed_code "$f" "nested code"
      COUNT=$((COUNT + 1))
      ;;
  esac
done < <(find "$APP/Contents" -path "$APP/Contents/Resources/BundledModels" -prune -o -type f -print0)
[ "$COUNT" -gt 0 ] || fail "found no Mach-O files in $APP"
ok "$COUNT Mach-O file(s): Developer ID, team $TEAM, timestamped; executables have the hardened runtime"

# 6. The DMG: the app plus an Applications link, signed with Developer ID.
step "6/9 DMG"
rm -rf "$DD/dmg"
mkdir -p "$DD/dmg" "$ROOT/dist"
ditto "$APP" "$DD/dmg/Transcribe.app"
ln -s /Applications "$DD/dmg/Applications"
hdiutil create -volname Transcribe -srcfolder "$DD/dmg" -ov -format UDZO "$DMG"
codesign --sign "$IDENTITY" --timestamp "$DMG"
codesign --verify -vv "$DMG"
check_signed_code "$DMG" "the DMG"
ok "DMG signed with Developer ID and timestamped"
hdiutil verify -quiet "$DMG" || fail "hdiutil verify failed on $DMG"
mkdir "$WORK/mnt"
hdiutil attach -quiet -nobrowse -readonly -noautoopen -mountpoint "$WORK/mnt" "$DMG"
MOUNT="$WORK/mnt"
codesign --verify --deep --strict "$MOUNT/Transcribe.app" || fail "the app inside the DMG does not verify"
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || fail "the DMG has no Applications link"
hdiutil detach -quiet "$MOUNT"
MOUNT=""
ok "DMG checksum, the app inside it and the Applications link"

if [ "$SKIP_NOTARIZE" = 1 ]; then
  echo
  echo "Skipped notarisation (--skip-notarize). The DMG is signed with Developer ID but NOT notarised:"
  echo "  $DMG"
  echo "  sha256 $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
  exit 0
fi

# 7. Notarise.
step "7/9 Notarise"
NOTARY_NOW="$(notary_state)"
if [ "$NOTARY_NOW" = missing ]; then
  notary_missing_message
  exit 3
fi
SUBMIT="$DD/notary-submit.json"
set +e
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json >"$SUBMIT"
SUBMIT_RC=$?
set -e
cat "$SUBMIT"
echo
ID="$(jq -r '.id // empty' "$SUBMIT" 2>/dev/null || true)"
STATUS="$(jq -r '.status // empty' "$SUBMIT" 2>/dev/null || true)"
if [ -n "$ID" ]; then
  xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" "$DD/notary-log.json" || true
  [ ! -f "$DD/notary-log.json" ] || cat "$DD/notary-log.json"
  echo
fi
[ "$STATUS" = Accepted ] ||
  fail "notarisation was not accepted (status: ${STATUS:-none}, id: ${ID:-none}, notarytool exit $SUBMIT_RC); see the log above"
ok "notarisation accepted ($ID)"

# 8. Staple and assess.
step "8/9 Staple and Gatekeeper"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
spctl -a -t open --context context:primary-signature -vv "$DMG"
spctl -a -vv "$APP"
ok "stapled; Gatekeeper accepts the DMG and the app"

# 9. Result.
step "9/9 Done"
echo "$DMG"
echo "sha256 $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
