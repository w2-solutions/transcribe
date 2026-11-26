#!/bin/bash
# Builds the Developer ID release of the Mac app: archive, Developer ID export, signature checks, a signed DMG,
# then notarisation, stapling and a Gatekeeper check. The result is dist/Transcribe-<version>.dmg. It never signs
# for Sparkle: scripts/sign-mac-release.sh does that, and the update key is never in this script's environment.
#
#   ./scripts/release-mac.sh                    everything (= make release-mac)
#   ./scripts/release-mac.sh --skip-notarize    stop after the signed, un-notarised DMG (exit 0)
#   ./scripts/release-mac.sh --print-version    print "<version> <build>" for the Mac app and exit (runs on Linux)
#
# Version and build: the version is TranscribeMac's MARKETING_VERSION in project.yml (major.minor.patch, minor and
# patch below 100); the build number (CFBundleVersion, what Sparkle compares) is major*10000 + minor*100 + patch,
# so 0.3.0 is 300. A release needs TranscribeMac's TRANSCRIBE_ED_PUBLIC_KEY in project.yml (the public update key).
#
# TEST builds: with TRANSCRIBE_ED_PUBLIC_KEY set in the environment the build trusts that key instead and is a TEST
# build, never publishable: dist/Transcribe-<version>-TEST.dmg. Only a TEST build also honours
#   TRANSCRIBE_FEED_URL      the update feed baked into the app (default the production feed)
#   TRANSCRIBE_TEST_VERSION  the version to build instead of MARKETING_VERSION
#
# Environment:
#   DERIVED         build folder (default $TMPDIR/transcribe-release): derived data, the archive, the export
#   FROM            passed to make models (copy model files you already have instead of downloading)
#   NOTARY_PROFILE  notarytool keychain profile (default transcribe-notary)
#   RELEASE_PROVISIONING_AUTH=api   archive and export sign in with the App Store Connect API key (ASC_KEY_PATH,
#                   ASC_KEY_ID, ASC_ISSUER_ID; CI sets it). Otherwise they use the Apple account in Xcode.
#   PROJECT         with --print-version only: the project.yml to read (default the repo's)
#
# Notarisation needs a notarytool keychain profile, which only a person can create (an agent never handles the
# password). Create an app-specific password at account.apple.com, then run:
#   xcrun notarytool store-credentials transcribe-notary --apple-id <your Apple ID> --team-id 53FBF5CS9U
# Without the profile the script stops after the signed DMG and exits 3.
#
# Exit codes: 0 done; 1 a step or check failed; 2 bad arguments; 3 stopped before notarisation (no profile).
# Runs on macOS /bin/bash 3.2; needs Xcode, xcodegen, jq (/usr/bin/jq on macOS 15 and later) and python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "$0")"
cd "$ROOT"

TEAM=53FBF5CS9U
IDENTITY="Developer ID Application: Liam Wynne ($TEAM)"
BUNDLE_ID=ai.w2solutions.transcribe.mac
PRODUCTION_FEED=https://w2solutions.ai/transcribe/appcast.xml
SPARKLE_VERSION=2.10.1
SPARKLE_BUILD=2065

usage() {
  sed -n '2,33s/^# \{0,1\}//p' "$SELF" >&2
  exit "${1:-2}"
}

SKIP_NOTARIZE=0
PRINT_VERSION=0
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-notarize) SKIP_NOTARIZE=1 ;;
    --print-version) PRINT_VERSION=1 ;;
    -h | --help) usage 0 ;;
    *)
      echo "error: unknown argument: $1" >&2
      usage
      ;;
  esac
  shift
done

step() { printf '\n==> %s\n' "$*"; }
ok() { printf '    ok: %s\n' "$*"; }
fail() {
  echo "error: $*" >&2
  exit 1
}

PROJECT_FILE="$ROOT/project.yml"
if [ "$PRINT_VERSION" = 1 ] && [ -n "${PROJECT:-}" ]; then PROJECT_FILE="$PROJECT"; fi
[ -f "$PROJECT_FILE" ] || fail "no project file: $PROJECT_FILE"

# mac_setting NAME: a build setting inside the TranscribeMac target in project.yml (the iPhone has its own), quotes
# and spaces removed; empty when absent or "".
mac_setting() {
  awk -v name="$1" '
    /^  [^ #]/ { mac = ($0 ~ /^  TranscribeMac:/) }
    mac && $1 == name ":" { v = $2; gsub(/"/, "", v); print v; exit }
  ' "$PROJECT_FILE"
}

# check_version V: major.minor.patch without leading zeros, minor and patch below 100 (the build number rule).
check_version() {
  printf '%s\n' "$1" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$' ||
    { echo "error: version '$1' is not major.minor.patch with minor and patch below 100" >&2; exit 2; }
}

# A TEST build trusts a throwaway key from the environment; its overrides are refused in any other build.
TEST_BUILD=0
if [ -n "${TRANSCRIBE_ED_PUBLIC_KEY:-}" ]; then
  TEST_BUILD=1
else
  for v in TRANSCRIBE_FEED_URL TRANSCRIBE_TEST_VERSION; do
    if [ -n "${!v:-}" ]; then
      echo "error: $v is only for TEST builds (set TRANSCRIBE_ED_PUBLIC_KEY in the environment too)" >&2
      exit 2
    fi
  done
fi

VERSION="$(mac_setting MARKETING_VERSION)"
[ -n "$VERSION" ] || fail "no MARKETING_VERSION for TranscribeMac in $PROJECT_FILE"
if [ "$TEST_BUILD" = 1 ] && [ -n "${TRANSCRIBE_TEST_VERSION:-}" ]; then VERSION="$TRANSCRIBE_TEST_VERSION"; fi
check_version "$VERSION"
IFS=. read -r V_MAJOR V_MINOR V_PATCH <<<"$VERSION"
BUILD=$((V_MAJOR * 10000 + V_MINOR * 100 + V_PATCH))

if [ "$PRINT_VERSION" = 1 ]; then
  echo "$VERSION $BUILD"
  exit 0
fi

# A base64 Ed25519 public key is 32 bytes: 43 characters and one "=".
KEY_RE='^[A-Za-z0-9+/]{43}=$'
if [ "$TEST_BUILD" = 1 ]; then
  PUBKEY="$TRANSCRIBE_ED_PUBLIC_KEY"
  FEED_URL="${TRANSCRIBE_FEED_URL:-$PRODUCTION_FEED}"
  printf '%s\n' "$FEED_URL" | grep -Eq '^https?://[^/]+/' || { echo "error: TRANSCRIBE_FEED_URL is not an http(s) URL" >&2; exit 2; }
  DMG="$ROOT/dist/Transcribe-$VERSION-TEST.dmg"
else
  PUBKEY="$(mac_setting TRANSCRIBE_ED_PUBLIC_KEY)"
  [ -n "$PUBKEY" ] || fail "set TRANSCRIBE_ED_PUBLIC_KEY in project.yml (owner: generate_keys -p)"
  FEED_URL="$PRODUCTION_FEED"
  DMG="$ROOT/dist/Transcribe-$VERSION.dmg"
fi
printf '%s\n' "$PUBKEY" | grep -Eq "$KEY_RE" || fail "TRANSCRIBE_ED_PUBLIC_KEY is not a base64 Ed25519 public key"

NOTARY_PROFILE="${NOTARY_PROFILE:-transcribe-notary}"
# Notarisation signs in with the App Store Connect API key when its file is there (the same key as
# scripts/testflight.sh; the keychain profile went missing once, on 2026-11-24), otherwise with the keychain profile.
ASC_KEY_ID="${ASC_KEY_ID:-93Y2L9PKNY}"
ASC_ISSUER_ID="${ASC_ISSUER_ID:-b275da4d-ed99-4de7-a5ae-8a8d8254e803}"
ASC_KEY_PATH="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_$ASC_KEY_ID.p8}"
if [ -f "$ASC_KEY_PATH" ]; then
  NOTARY_AUTH=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
  NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
fi
# Archive and export: the Apple account in Xcode, unless the caller (CI) opts in to the API key.
PROVISIONING_AUTH=(-allowProvisioningUpdates)
if [ "${RELEASE_PROVISIONING_AUTH:-}" = api ]; then
  [ -f "$ASC_KEY_PATH" ] || fail "RELEASE_PROVISIONING_AUTH=api, but there is no API key file at $ASC_KEY_PATH"
  PROVISIONING_AUTH+=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID"
    -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi

DD="${DERIVED:-${TMPDIR:-/tmp}/transcribe-release}"
DD="${DD%/}"
ARCHIVE="$DD/TranscribeMac.xcarchive"
EXPORT="$DD/export"
APP="$EXPORT/Transcribe.app"
ENTITLEMENTS_SRC="$ROOT/Apps/Mac/TranscribeMac.entitlements"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-mac.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# notary_state: prints "present", "missing" or "unknown: <message>". notarytool's history call needs the network
# when the profile exists; "missing" is the one answer that needs no network.
notary_state() {
  local out
  if out="$(xcrun notarytool history "${NOTARY_AUTH[@]}" --output-format json 2>&1)"; then
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

echo "Transcribe for Mac $VERSION (build $BUILD), Developer ID release"
if [ "$TEST_BUILD" = 1 ]; then
  echo "TEST BUILD: not publishable (trusts the update key from the environment; feed $FEED_URL)"
fi
echo "build folder: $DD"
# The DMG's background art (scripts/make-dmg.sh), checked now rather than after the archive.
for f in background.png background@2x.png; do
  [ -f "$ROOT/Apps/Mac/DMG/$f" ] || fail "no DMG background art at Apps/Mac/DMG/$f"
done
command -v python3 >/dev/null || fail "needs python3 (scripts/make-dmg.sh writes the DMG's .DS_Store with it)"

# Build settings for the archive. xcodebuild reads "//" in a command-line value as the start of a comment, so the
# feed URL's "//" is written "/$()/" (an empty expansion).
BUILD_SETTINGS=(CURRENT_PROJECT_VERSION="$BUILD")
if [ "$TEST_BUILD" = 1 ]; then
  # In a variable: bash 3.2 keeps backslashes written in a replacement literally.
  # shellcheck disable=SC2016
  NO_COMMENT='/$()/'
  BUILD_SETTINGS+=(MARKETING_VERSION="$VERSION" TRANSCRIBE_ED_PUBLIC_KEY="$PUBKEY"
    TRANSCRIBE_FEED_URL="${FEED_URL//\/\//$NO_COMMENT}")
fi

# 1. Models and project.
step "1/9 Bundled models and project"
make -C "$ROOT" models ${FROM:+FROM="$FROM"}
xcodegen generate

# 2. Release archive (signed automatically; the export re-signs with Developer ID).
step "2/9 Archive (Release)"
rm -rf "$ARCHIVE"
xcodebuild -project Transcribe.xcodeproj -scheme TranscribeMac -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DD" -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM" "${BUILD_SETTINGS[@]}" "${PROVISIONING_AUTH[@]}" archive
[ -d "$ARCHIVE/Products/Applications/Transcribe.app" ] || fail "the archive has no Transcribe.app: $ARCHIVE"

# 3. The models inside the archived app (strict: sizes and sha256).
step "3/9 Models inside the archive"
./scripts/check-models.sh --app "$ARCHIVE/Products/Applications/Transcribe.app"

# 4. Developer ID export.
step "4/9 Developer ID export"
rm -rf "$EXPORT"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$ROOT/scripts/ExportOptions-DeveloperID.plist" "${PROVISIONING_AUTH[@]}"
[ -d "$APP" ] || fail "the export has no Transcribe.app: $EXPORT"

# plist_value FILE KEY: the value, or nothing when the key is absent (PlistBuddy keys may contain dots).
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true; }

# plist_typed FILE KEY: "<type>:<value>" (for example "bool:true", "integer:0"), or nothing when the key is absent.
plist_typed() {
  local type
  type="$(plutil -type "$2" "$1" 2>/dev/null)" || return 0
  printf '%s:%s\n' "$type" "$(plutil -extract "$2" raw -o - "$1")"
}

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

# entitlements_json PATH: the code's entitlements as compact JSON ("{}" when it has none).
entitlements_json() {
  local xml
  xml="$(codesign -d --entitlements - --xml "$1" 2>/dev/null || true)"
  if [ -z "$xml" ]; then
    echo '{}'
  else
    printf '%s' "$xml" | plutil -convert json -o - - | jq -cS .
  fi
}

# 5. Checks on the exported app. Any failure stops the release.
step "5/9 Signature, hardened runtime, entitlements and update settings"
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

PLIST="$APP/Contents/Info.plist"
APP_VERSION="$(plist_value "$PLIST" CFBundleShortVersionString)"
[ "$APP_VERSION" = "$VERSION" ] || fail "the app's version is $APP_VERSION, expected $VERSION"
APP_BUILD="$(plist_value "$PLIST" CFBundleVersion)"
[ "$APP_BUILD" = "$BUILD" ] || fail "the app's build is $APP_BUILD, expected $BUILD (major*10000 + minor*100 + patch)"
ok "version $APP_VERSION (build $APP_BUILD), $(lipo -archs "$APP/Contents/MacOS/Transcribe")"

# Sparkle: the feed and key this release trusts, and the update policy (project.yml, info.properties).
[ "$(plist_typed "$PLIST" SUFeedURL)" = "string:$FEED_URL" ] || fail "Info.plist: SUFeedURL is not $FEED_URL"
[ "$(plist_typed "$PLIST" SUPublicEDKey)" = "string:$PUBKEY" ] || fail "Info.plist: SUPublicEDKey is not the expected key"
for want in SUEnableInstallerLauncherService=bool:true SURequireSignedFeed=bool:true \
  SUSignedFeedFailureExpirationInterval=integer:0 SUVerifyUpdateBeforeExtraction=bool:true \
  SUAllowsAutomaticUpdates=bool:false SUScheduledCheckInterval=integer:86400; do
  [ "$(plist_typed "$PLIST" "${want%%=*}")" = "${want#*=}" ] || fail "Info.plist: ${want%%=*} is not ${want#*=}"
done
for key in SUEnableDownloaderService SUEnableSystemProfiling; do
  case "$(plist_typed "$PLIST" "$key")" in "" | bool:false) ;; *) fail "Info.plist: $key must be false or absent" ;; esac
done
[ -z "$(plist_typed "$PLIST" SUEnableAutomaticChecks)" ] || fail "Info.plist: SUEnableAutomaticChecks must be absent"
ok "Sparkle settings: feed $FEED_URL, key $PUBKEY, signed feed, no automatic install, daily checks"

SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
[ "$(plist_value "$SPARKLE/Resources/Info.plist" CFBundleShortVersionString)" = "$SPARKLE_VERSION" ] &&
  [ "$(plist_value "$SPARKLE/Resources/Info.plist" CFBundleVersion)" = "$SPARKLE_BUILD" ] ||
  fail "Sparkle.framework is not $SPARKLE_VERSION ($SPARKLE_BUILD)"
[ ! -e "$SPARKLE/XPCServices/Downloader.xpc" ] || fail "Sparkle's Downloader.xpc must not be in a release"
ok "Sparkle $SPARKLE_VERSION ($SPARKLE_BUILD); Downloader.xpc removed"

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

# Sparkle needs outgoing connections and the installer launcher's two mach services, exactly these names.
[ "$(plist_value "$ENT" com.apple.security.network.client)" = true ] || fail "entitlements: network.client is not true"
MACH_KEY=com.apple.security.temporary-exception.mach-lookup.global-name
MACH="$(for i in 0 1 2; do plist_value "$ENT" "$MACH_KEY:$i"; done | sort | tr '\n' ' ')"
[ "$MACH" = "$BUNDLE_ID-spki $BUNDLE_ID-spks " ] || fail "entitlements: $MACH_KEY is [$MACH], expected $BUNDLE_ID-spks and -spki"
ok "network.client; mach-lookup $BUNDLE_ID-spks and $BUNDLE_ID-spki"

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

# Every Mach-O file in the bundle (the models are not code, so their folder is skipped): exactly the app, the
# Claude helper and Sparkle's four. Each is Developer ID, timestamped, hardened, and carries no entitlements except
# the app's own and Autoupdate's application identifier.
SPK=Contents/Frameworks/Sparkle.framework/Versions/B
EXPECTED_MACHO="$(printf '%s\n' Contents/MacOS/Transcribe Contents/Helpers/transcribe-mcp "$SPK/Sparkle" \
  "$SPK/Autoupdate" "$SPK/Updater.app/Contents/MacOS/Updater" "$SPK/XPCServices/Installer.xpc/Contents/MacOS/Installer" | sort)"
AUTOUPDATE_ENT='{"com.apple.application-identifier":"org.sparkle-project.Sparkle.Autoupdate"}'
FOUND_MACHO=""
while IFS= read -r -d '' f; do
  case "$(file -b "$f")" in
    Mach-O*)
      rel="${f#"$APP"/}"
      check_signed_code "$f" "nested code"
      FOUND_MACHO="$FOUND_MACHO$rel"$'\n'
      [ "$rel" = Contents/MacOS/Transcribe ] && continue
      ents="$(entitlements_json "$f")"
      if [ "$rel" = "$SPK/Autoupdate" ]; then
        [ "$ents" = "$AUTOUPDATE_ENT" ] || fail "Autoupdate's entitlements are $ents, expected $AUTOUPDATE_ENT"
      else
        [ "$ents" = '{}' ] || fail "nested code must have no entitlements: $rel has $ents"
      fi
      ;;
  esac
done < <(find "$APP/Contents" -path "$APP/Contents/Resources/BundledModels" -prune -o -type f -print0)
FOUND_MACHO="$(printf '%s' "$FOUND_MACHO" | sort)"
if [ "$FOUND_MACHO" != "$EXPECTED_MACHO" ]; then
  echo "expected Mach-O files:" >&2
  printf '%s\n' "$EXPECTED_MACHO" | sed 's/^/  /' >&2
  echo "found:" >&2
  printf '%s\n' "$FOUND_MACHO" | sed 's/^/  /' >&2
  fail "the app's Mach-O files are not exactly the expected six"
fi
ok "6 Mach-O files: Developer ID, team $TEAM, timestamped, hardened; nested entitlements as expected"

# The Claude helper: present, executable, and signed with no entitlements (unsandboxed, no get-task-allow).
HELPER="$APP/Contents/Helpers/transcribe-mcp"
[ -x "$HELPER" ] || fail "no Claude helper at Contents/Helpers/transcribe-mcp"
if codesign -d --entitlements - --xml "$HELPER" 2>/dev/null | grep -q '<key>'; then
  fail "the Claude helper must have no entitlements"
fi
ok "Claude helper: present, hardened runtime (checked above), no entitlements"

# Entitlement allowlist: any new key must be added here on purpose.
ALLOWED=" com.apple.security.app-sandbox com.apple.security.device.audio-input com.apple.security.device.microphone com.apple.security.files.user-selected.read-write com.apple.security.network.server com.apple.security.network.client com.apple.security.temporary-exception.mach-lookup.global-name com.apple.developer.icloud-container-identifiers com.apple.developer.icloud-services com.apple.developer.icloud-container-environment com.apple.developer.aps-environment com.apple.application-identifier com.apple.developer.team-identifier "
while IFS= read -r key; do
  [ -z "$key" ] && continue
  case "$ALLOWED" in *" $key "*) ;; *) fail "entitlements: unexpected key $key" ;; esac
done < <(plutil -convert xml1 -o - "$ENT" | sed -n '/^\t<key>/s/.*<key>\(.*\)<\/key>.*/\1/p')
ok "entitlements match the allowlist"

# 6. The DMG: the app plus an Applications link in a styled Finder window (scripts/make-dmg.sh, art in
# Apps/Mac/DMG), signed with Developer ID.
step "6/9 DMG"
mkdir -p "$ROOT/dist"
"$ROOT/scripts/make-dmg.sh" "$APP" "$DMG" --volname Transcribe
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
[ -f "$MOUNT/.background/background.tiff" ] || fail "the DMG has no background picture"
python3 -I "$ROOT/scripts/dmg-dsstore.py" dump "$MOUNT/.DS_Store" >/dev/null || fail "the DMG has no readable .DS_Store"
hdiutil detach -quiet "$MOUNT"
MOUNT=""
ok "DMG checksum, the app inside it, the Applications link, the background and the window layout"

if [ "$SKIP_NOTARIZE" = 1 ]; then
  echo
  echo "Skipped notarisation (--skip-notarize). The DMG is signed with Developer ID but NOT notarised:"
  echo "  $DMG"
  echo "  sha256 $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
  echo "  build $BUILD"
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
xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait --output-format json >"$SUBMIT"
SUBMIT_RC=$?
set -e
cat "$SUBMIT"
echo
ID="$(jq -r '.id // empty' "$SUBMIT" 2>/dev/null || true)"
STATUS="$(jq -r '.status // empty' "$SUBMIT" 2>/dev/null || true)"
if [ -n "$ID" ]; then
  xcrun notarytool log "$ID" "${NOTARY_AUTH[@]}" "$DD/notary-log.json" || true
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

# 9. Result. Sparkle signing is a separate step: scripts/sign-mac-release.sh (make sign-mac, or CI).
step "9/9 Done"
echo "$DMG"
echo "sha256 $(shasum -a 256 "$DMG" | cut -d ' ' -f 1)"
echo "build $BUILD"
