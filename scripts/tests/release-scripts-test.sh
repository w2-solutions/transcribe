#!/bin/bash
# Tests for the Mac release scripts (make test-release-scripts). Nothing here touches the network beyond 127.0.0.1,
# the keychain, the real bucket or the real update key: every key is a throwaway made for the run, and every
# output goes to a temporary folder that is deleted at the end.
#
#   scripts/tests/release-scripts-test.sh
#
# Sections: lint (bash -n, shellcheck, actionlint, a .DS_Store round trip); release-mac.sh --print-version; the Mac
# audio privacy string (project.yml everywhere, release-mac.sh --check-info-plist on macOS); then, on macOS only,
# ed25519.swift (with a cross-check against Sparkle's sign_update when $DERIVED holds it),
# sign-mac-release.sh --test and publish-mac.sh --dest dir:, delta updates (make-mac-delta.sh with Sparkle's
# BinaryDelta when $DERIVED holds it, sign and publish with --delta, fetch-published-mac.sh against a local server),
# make-dmg.sh (a styled DMG from a stub app, mounted and checked); finally release-gate.sh against a local server.
# On Linux (release-checks.yml) the macOS-only sections are skipped.
# Exit: 0 all passed; 1 a test failed.
# shellcheck disable=SC2016  # jq programs and sh -c scripts are single-quoted on purpose
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT" || exit 1
FIXTURES="$ROOT/scripts/tests/fixtures"
SCRIPTS="scripts/release-mac.sh scripts/sign-mac-release.sh scripts/publish-mac.sh scripts/release-gate.sh
  scripts/make-mac-delta.sh scripts/fetch-published-mac.sh scripts/ci-mac-delta.sh scripts/testflight-gate.sh
  scripts/make-dmg.sh tools/update-e2e/run.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/release-scripts-test.XXXXXX")"
SERVER=""
DMG_MOUNT=""
cleanup() {
  if [ -n "$SERVER" ]; then
    kill "$SERVER" 2>/dev/null
    wait "$SERVER" 2>/dev/null
  fi
  [ -z "$DMG_MOUNT" ] || hdiutil detach -quiet -force "$DMG_MOUNT" 2>/dev/null
  rm -rf "$T"
}
trap cleanup EXIT
umask 077

PASSED=0
FAILED=0
pass() {
  PASSED=$((PASSED + 1))
  echo "  ok    $1"
}
failed() {
  FAILED=$((FAILED + 1))
  echo "  FAIL  $1"
  [ ! -s "$T/out" ] || sed 's/^/        | /' "$T/out" | tail -n 15
}
section() { printf '\n== %s\n' "$*"; }

# expect_rc NAME CODE COMMAND...: the command exits with CODE (its output is shown on failure).
expect_rc() {
  local name="$1" want="$2" rc
  shift 2
  "$@" >"$T/out" 2>&1
  rc=$?
  if [ "$rc" = "$want" ]; then pass "$name"; else failed "$name (exit $rc, expected $want)"; fi
}

# expect_out NAME WANT COMMAND...: the command's standard output is exactly WANT.
expect_out() {
  local name="$1" want="$2" got
  shift 2
  got="$("$@" 2>"$T/out")"
  if [ "$got" = "$want" ]; then pass "$name"; else failed "$name (got '$got', expected '$want')"; fi
}

# expect NAME COMMAND...: the command (a test) succeeds.
expect() {
  local name="$1"
  shift
  : >"$T/out"
  if "$@" >"$T/out" 2>&1; then pass "$name"; else failed "$name"; fi
}

# project IPHONE MAC KEY: a fixture project.yml; prints its path.
project() {
  local out
  out="$(mktemp "$T/project-$1-$2.XXXXXX")"
  sed -e "s/@IPHONE@/$1/" -e "s/@MAC@/$2/" -e "s|@KEY@|$3|" "$FIXTURES/project.yml" >"$out"
  echo "$out"
}

# print_version PROJECT: release-mac.sh --print-version without any TEST override from this shell.
print_version() {
  env -u TRANSCRIBE_ED_PUBLIC_KEY -u TRANSCRIBE_FEED_URL -u TRANSCRIBE_TEST_VERSION PROJECT="$1" \
    ./scripts/release-mac.sh --print-version
}

# flip_byte FILE OFFSET: changes one byte in place (same length).
flip_byte() {
  python3 -I -c 'import sys
p, o = sys.argv[1], int(sys.argv[2])
b = bytearray(open(p, "rb").read()); b[o] ^= 1; open(p, "wb").write(b)' "$1" "$2"
}

ed() { xcrun swift scripts/ed25519.swift "$@"; }

# ---------------------------------------------------------------------------------------------------------------
section "Lint"
for s in $SCRIPTS scripts/tests/release-scripts-test.sh; do expect_rc "bash -n $s" 0 bash -n "$s"; done
# shellcheck disable=SC2086
expect_rc "shellcheck" 0 shellcheck $SCRIPTS scripts/tests/release-scripts-test.sh
expect_rc "actionlint" 0 actionlint .github/workflows/*.yml
expect_rc "bash -n and shellcheck tools/r2-uploader/upload.sh" 0 sh -c 'bash -n "$1" && shellcheck "$1"' _ tools/r2-uploader/upload.sh
# Under bash -e a failing $(...) inside echo's arguments is ignored: the output would be written empty.
expect_rc "no command substitution in an echo to GITHUB_OUTPUT" 1 grep -nE 'echo .*\$\(.*>> *"?\$GITHUB_OUTPUT' .github/workflows/*.yml
# The .DS_Store writer's file format, without a volume (runs on Linux too): what it writes, it reads back.
expect_rc "dmg-dsstore.py: a .DS_Store round trip" 0 python3 -I -B -c 'import importlib.util, plistlib, struct, sys
spec = importlib.util.spec_from_file_location("ds", sys.argv[1]); ds = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ds)
recs = [("Transcribe.app", "Iloc", "blob", struct.pack(">IIII", 165, 185, 0xffffffff, 0xffff0000)),
        (".", "vSrn", "long", 1), ("Applications", "Iloc", "blob", struct.pack(">IIII", 495, 185, 0xffffffff, 0xffff0000)),
        (".", "bwsp", "blob", plistlib.dumps({"ShowToolbar": False}, fmt=plistlib.FMT_BINARY))]
data = ds.build_ds_store(recs)
assert data[:8] == b"\0\0\0\1Bud1" and len(data) == 8196, len(data)
got = ds.parse_ds_store(data)
assert got == sorted(recs, key=lambda r: (r[0].lower(), r[1])), got
assert ds.decode_value("Iloc", "blob", got[2][3]) == {"x": 495, "y": 185}' scripts/dmg-dsstore.py
if command -v node >/dev/null; then
  expect_rc "tools/r2-uploader/worker.js (node --test)" 0 node --test tools/r2-uploader/worker.test.mjs
else
  echo "  skip  tools/r2-uploader/worker.test.mjs (no node)"
fi

# ---------------------------------------------------------------------------------------------------------------
section "release-mac.sh --print-version"
K="$(head -c 32 /dev/urandom | base64)"
expect_out "0.3.0 is build 300 (the iPhone's 9.9.9 is ignored)" "0.3.0 300" print_version "$(project 9.9.9 0.3.0 "$K")"
expect_out "1.2.3 is build 10203" "1.2.3 10203" print_version "$(project 0.2.0 1.2.3 "$K")"
expect_out "0.2.0 is build 200" "0.2.0 200" print_version "$(project 0.2.0 0.2.0 "")"
expect_out "99.99.99 is build 999999" "99.99.99 999999" print_version "$(project 0.2.0 99.99.99 "")"
expect_rc "0.100.0 is refused" 2 print_version "$(project 0.2.0 0.100.0 "$K")"
expect_rc "0.3 is refused" 2 print_version "$(project 0.2.0 0.3 "$K")"
expect_rc "0.03.0 is refused" 2 print_version "$(project 0.2.0 0.03.0 "$K")"
P300="$(project 0.2.0 0.3.0 "$K")"
expect_rc "TRANSCRIBE_TEST_VERSION without a test key is refused" 2 \
  env -u TRANSCRIBE_ED_PUBLIC_KEY TRANSCRIBE_TEST_VERSION=0.3.1 PROJECT="$P300" ./scripts/release-mac.sh --print-version
expect_rc "TRANSCRIBE_FEED_URL without a test key is refused" 2 \
  env -u TRANSCRIBE_ED_PUBLIC_KEY TRANSCRIBE_FEED_URL=http://127.0.0.1:8788/transcribe/appcast.xml PROJECT="$P300" \
  ./scripts/release-mac.sh --print-version
expect_out "a TEST build honours TRANSCRIBE_TEST_VERSION" "0.3.1 301" \
  env TRANSCRIBE_ED_PUBLIC_KEY="$K" TRANSCRIBE_TEST_VERSION=0.3.1 PROJECT="$P300" ./scripts/release-mac.sh --print-version

# ---------------------------------------------------------------------------------------------------------------
section "Mac audio privacy string"
# info_key TARGET KEY: TARGET's block in project.yml has KEY (the Info.plist properties live inside the target).
info_key() {
  awk -v target="$1" -v key="$2" '
    /^  [^ #]/ { t = ($0 ~ ("^  " target ":")) }
    t && $1 == key ":" { found = 1 }
    END { exit !found }
  ' project.yml
}
expect_rc "project.yml: TranscribeMac has NSAudioCaptureUsageDescription" 0 info_key TranscribeMac NSAudioCaptureUsageDescription
expect_rc "project.yml: the iPhone app (no Mac audio) does not" 1 info_key Transcribe NSAudioCaptureUsageDescription
expect_rc "project.yml: no system-audio entitlement anywhere" 1 grep -rn 'system-audio' project.yml Apps/Mac/TranscribeMac.entitlements \
  Apps/Mac/TranscribeMac.local.entitlements
expect_rc "release-mac.sh --check-info-plist needs a file" 2 ./scripts/release-mac.sh --check-info-plist
if [ "$(uname -s)" = Darwin ]; then
  # info_plist FILE KEY=VALUE...: a minimal Info.plist with string values ("KEY=" is an empty string).
  info_plist() {
    local file="$1" kv
    shift
    {
      printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0">\n<dict>\n'
      for kv in "$@"; do printf '<key>%s</key><string>%s</string>\n' "${kv%%=*}" "${kv#*=}"; done
      printf '</dict>\n</plist>\n'
    } >"$file"
  }
  info_plist "$T/info-ok.plist" NSMicrophoneUsageDescription=mic NSAudioCaptureUsageDescription="Mac audio"
  info_plist "$T/info-missing.plist" NSMicrophoneUsageDescription=mic
  info_plist "$T/info-empty.plist" NSMicrophoneUsageDescription=mic NSAudioCaptureUsageDescription=
  info_plist "$T/info-nomic.plist" NSAudioCaptureUsageDescription="Mac audio"
  cp "$T/info-ok.plist" "$T/info-bool.plist"
  plutil -replace NSAudioCaptureUsageDescription -bool true "$T/info-bool.plist"
  expect_rc "--check-info-plist accepts both privacy strings" 0 ./scripts/release-mac.sh --check-info-plist "$T/info-ok.plist"
  expect_rc "--check-info-plist refuses a missing NSAudioCaptureUsageDescription" 1 \
    ./scripts/release-mac.sh --check-info-plist "$T/info-missing.plist"
  expect_rc "--check-info-plist refuses an empty NSAudioCaptureUsageDescription" 1 \
    ./scripts/release-mac.sh --check-info-plist "$T/info-empty.plist"
  expect_rc "--check-info-plist refuses a NSAudioCaptureUsageDescription that is not a string" 1 \
    ./scripts/release-mac.sh --check-info-plist "$T/info-bool.plist"
  expect_rc "--check-info-plist refuses a missing NSMicrophoneUsageDescription" 1 \
    ./scripts/release-mac.sh --check-info-plist "$T/info-nomic.plist"
  expect_rc "--check-info-plist refuses a missing file" 1 ./scripts/release-mac.sh --check-info-plist "$T/nothing.plist"
fi

# ---------------------------------------------------------------------------------------------------------------
if [ "$(uname -s)" = Darwin ]; then
  section "ed25519.swift"
  openssl rand -base64 32 >"$T/seed"
  openssl rand -base64 32 >"$T/seed2"
  PUB="$(ed public-key <"$T/seed")"
  PUB2="$(ed public-key <"$T/seed2")"
  head -c 300000 /dev/urandom >"$T/blob"
  SIG="$(ed sign "$T/blob" <"$T/seed")"
  expect_rc "public-key is base64 of 32 bytes" 0 test "$(printf '%s' "$PUB" | base64 -D | wc -c | tr -d ' ')" = 32
  expect_rc "sign then verify" 0 ed verify "$PUB" "$SIG" "$T/blob"
  cp "$T/blob" "$T/blob-flipped"
  flip_byte "$T/blob-flipped" 150000
  expect_rc "a flipped byte fails" 1 ed verify "$PUB" "$SIG" "$T/blob-flipped"
  expect_rc "a wrong key fails" 1 ed verify "$PUB2" "$SIG" "$T/blob"
  expect_rc "a 31-byte seed exits 2" 2 sh -c 'head -c 31 /dev/urandom | base64 | xcrun swift scripts/ed25519.swift public-key'
  expect_rc "no seed exits 2" 2 sh -c 'xcrun swift scripts/ed25519.swift sign /dev/null </dev/null'
  expect_rc "a bad seed is not echoed" 1 sh -c 'echo not-a-seed-1234 | xcrun swift scripts/ed25519.swift public-key 2>&1 | grep -q not-a-seed-1234'

  printf '<?xml version="1.0" encoding="utf-8"?>\n<rss><channel><title>Version 1</title></channel></rss>\n' >"$T/feed.xml"
  expect_rc "sign-feed" 0 sh -c 'xcrun swift scripts/ed25519.swift sign-feed "$1" "$2" <"$3"' _ "$T/feed.xml" "$T/feed-signed.xml" "$T/seed"
  expect_rc "verify-feed" 0 ed verify-feed "$PUB" "$T/feed-signed.xml"
  expect_rc "verify-feed with a wrong key fails" 1 ed verify-feed "$PUB2" "$T/feed-signed.xml"
  sed 's/Version 1/Version 2/' "$T/feed-signed.xml" >"$T/feed-changed.xml"
  expect_rc "a changed character fails" 1 ed verify-feed "$PUB" "$T/feed-changed.xml"
  awk '/^length: / { $2 = $2 + 1 } { print }' "$T/feed-signed.xml" >"$T/feed-length.xml"
  expect_rc "a wrong length fails" 1 ed verify-feed "$PUB" "$T/feed-length.xml"
  expect_rc "a stripped signature block fails" 1 ed verify-feed "$PUB" "$T/feed.xml"
  expect_rc "sign-feed on a signed feed exits 2" 2 sh -c 'xcrun swift scripts/ed25519.swift sign-feed "$1" "$2" <"$3"' _ "$T/feed-signed.xml" "$T/feed-twice.xml" "$T/seed"

  SIGN_UPDATE="${DERIVED:-${TMPDIR:-/tmp}/transcribe-dd}/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update"
  if [ -x "$SIGN_UPDATE" ]; then
    # Sparkle's own tool, with the throwaway key as a file (never the keychain): both directions must agree.
    expect_rc "sign_update's archive signature verifies with ours" 0 ed verify "$PUB" "$("$SIGN_UPDATE" --ed-key-file "$T/seed" -p "$T/blob")" "$T/blob"
    expect_rc "our archive signature verifies with sign_update" 0 "$SIGN_UPDATE" --ed-key-file "$T/seed" --verify "$T/blob" "$SIG"
    cp "$T/feed.xml" "$T/feed-sparkle.xml"
    "$SIGN_UPDATE" --ed-key-file "$T/seed" "$T/feed-sparkle.xml" >/dev/null
    expect_rc "a feed signed by sign_update verifies with ours" 0 ed verify-feed "$PUB" "$T/feed-sparkle.xml"
    cp "$T/feed-signed.xml" "$T/feed-ours.xml"
    expect_rc "our signed feed verifies with sign_update" 0 "$SIGN_UPDATE" --ed-key-file "$T/seed" --verify "$T/feed-ours.xml"
  else
    echo "  skip  the sign_update cross-check (no $SIGN_UPDATE; build the Mac app with DERIVED set to see it)"
  fi

  # -------------------------------------------------------------------------------------------------------------
  section "sign-mac-release.sh --test"
  mkdir -p "$T/notes" "$T/dist" "$T/dmg"
  printf 'First line & <notes>.\nSecond line.\n' >"$T/notes/0.3.0.txt"
  printf 'Fixes.\n' >"$T/notes/0.3.1.txt"
  # make_dmg VERSION BUILD KEY: a small UDZO DMG holding a stub Transcribe.app (just its Info.plist).
  make_dmg() {
    local src="$T/dmgsrc-$1"
    mkdir -p "$src/Transcribe.app/Contents"
    plutil -create xml1 "$src/Transcribe.app/Contents/Info.plist"
    plutil -insert CFBundleShortVersionString -string "$1" "$src/Transcribe.app/Contents/Info.plist"
    plutil -insert CFBundleVersion -string "$2" "$src/Transcribe.app/Contents/Info.plist"
    plutil -insert SUPublicEDKey -string "$3" "$src/Transcribe.app/Contents/Info.plist"
    plutil -insert SUFeedURL -string "http://127.0.0.1:8788/transcribe/appcast.xml" "$src/Transcribe.app/Contents/Info.plist"
    plutil -insert LSMinimumSystemVersion -string "27.0" "$src/Transcribe.app/Contents/Info.plist"
    head -c 200000 /dev/urandom >"$src/Transcribe.app/Contents/filler"
    hdiutil create -quiet -volname Transcribe -srcfolder "$src" -format UDZO -ov "$T/dmg/Transcribe-$1-TEST.dmg"
  }
  make_dmg 0.3.0 300 "$PUB"
  make_dmg 0.3.1 301 "$PUB"
  sign_test() {
    env SPARKLE_ED_PRIVATE_KEY="$(cat "$1")" DIST="$T/dist" NOTES_DIR="$T/notes" ./scripts/sign-mac-release.sh --test \
      --download-prefix http://127.0.0.1:8788/transcribe/download/ "$T/dmg/Transcribe-$2-TEST.dmg"
  }
  expect_rc "sign --test 0.3.0" 0 sign_test "$T/seed" 0.3.0
  R30="$T/dist/Transcribe-0.3.0-TEST.latest.json"
  A30="$T/dist/Transcribe-0.3.0-TEST.appcast.xml"
  expect "it writes the latest.json, with the DMG's size and sha256" jq -e --argjson bytes "$(stat -f %z "$T/dmg/Transcribe-0.3.0-TEST.dmg")" \
    --arg sha "$(shasum -a 256 "$T/dmg/Transcribe-0.3.0-TEST.dmg" | cut -d ' ' -f 1)" \
    '.schema == 1 and .version == "0.3.0" and .build == 300 and .file == "Transcribe-0.3.0.dmg" and .key == "transcribe/Transcribe-0.3.0.dmg" and .bytes == $bytes and .sha256 == $sha and .minimumSystemVersion == "27.0" and (keys_unsorted == ["schema","version","build","file","key","bytes","sha256","edSignature","minimumSystemVersion","published"])' "$R30"
  expect "the appcast is well-formed" xmllint --noout "$A30"
  expect_rc "the appcast is signed with the app's key" 0 ed verify-feed "$PUB" "$A30"
  expect "the appcast escapes the notes and adds the trailer" grep -q 'First line &amp; &lt;notes&gt;\.' "$A30"
  expect "the appcast has the download size line" grep -q 'The download is under 1 MB because the speech models are inside the app\.' "$A30"
  expect "  and no deltas" grep -vq 'sparkle:deltas' "$A30"
  expect "the appcast's enclosure uses the test prefix" grep -q 'url="http://127.0.0.1:8788/transcribe/download/Transcribe-0.3.0.dmg"' "$A30"
  expect "the appcast's minimumSystemVersion is 27.0.0" grep -q '<sparkle:minimumSystemVersion>27.0.0<' "$A30"
  expect_rc "a seed that is not the app's key fails" 1 sign_test "$T/seed2" 0.3.0
  expect_rc "--use-keychain --test exits 2" 2 ./scripts/sign-mac-release.sh --use-keychain --test "$T/dmg/Transcribe-0.3.0-TEST.dmg"
  expect_rc "no key exits 2" 2 env -u SPARKLE_ED_PRIVATE_KEY DIST="$T/dist" ./scripts/sign-mac-release.sh --test "$T/dmg/Transcribe-0.3.0-TEST.dmg"
  expect_rc "sign --test 0.3.1" 0 sign_test "$T/seed" 0.3.1
  R31="$T/dist/Transcribe-0.3.1-TEST.latest.json"
  A31="$T/dist/Transcribe-0.3.1-TEST.appcast.xml"
  mkdir -p "$T/blank-notes"
  printf '   \n\t\n' >"$T/blank-notes/0.3.1.txt"
  expect_rc "notes of only white space are refused" 1 env SPARKLE_ED_PRIVATE_KEY="$(cat "$T/seed")" DIST="$T/dist-blank" \
    NOTES_DIR="$T/blank-notes" ./scripts/sign-mac-release.sh --test "$T/dmg/Transcribe-0.3.1-TEST.dmg"

  # --feed-from (resume) with a fixture project.yml that trusts the throwaway key.
  P30PUB="$(project 0.2.0 0.3.0 "$PUB")"
  P31PUB="$(project 0.2.0 0.3.1 "$PUB")"
  feed_from() {
    env SPARKLE_ED_PRIVATE_KEY="$(cat "$T/seed")" DIST="$T/dist-resume" NOTES_DIR="$T/notes" PROJECT="$1" \
      ./scripts/sign-mac-release.sh --feed-from "$2"
  }
  expect_rc "--feed-from for project.yml's version" 0 feed_from "$P31PUB" "$R31"
  expect_rc "  signs a feed that verifies" 0 ed verify-feed "$PUB" "$T/dist-resume/resume.appcast.xml"
  expect "  with the production enclosure" grep -q 'url="https://w2solutions.ai/transcribe/download/Transcribe-0.3.1.dmg"' "$T/dist-resume/resume.appcast.xml"
  rm -f "$T/dist-resume/resume.appcast.xml"
  expect_rc "--feed-from for another version is refused" 1 feed_from "$P31PUB" "$R30"
  expect_rc "  and signs nothing" 0 test ! -e "$T/dist-resume/resume.appcast.xml"
  expect_rc "--feed-from with a key that is not project.yml's is refused" 1 feed_from "$(project 0.2.0 0.3.1 "$PUB2")" "$R31"

  # -------------------------------------------------------------------------------------------------------------
  section "publish-mac.sh --dest dir:"
  B="$T/bucket"
  # publish ARGS...: publish-mac.sh to a folder, project.yml being 0.3.1 (a resume repairs only that version).
  publish() { env PROJECT="$P31PUB" ./scripts/publish-mac.sh "$@" --public-key "$PUB"; }
  listing() { (cd "$1" && find . -type f ! -name '*.meta.json' | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' '); }
  snapshot() { (cd "$1" && find . -type f -exec shasum -a 256 {} + | LC_ALL=C sort); }
  expect_rc "first release" 0 publish --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$A30" --dest "dir:$B"
  expect_out "it holds the DMG, latest.json and appcast.xml" "transcribe/Transcribe-0.3.0.dmg transcribe/appcast.xml transcribe/latest.json " listing "$B"
  expect "the stored latest.json is valid" jq -e '.schema == 1 and .build == 300' "$B/transcribe/latest.json"
  expect "the stored appcast is well-formed" xmllint --noout "$B/transcribe/appcast.xml"
  expect_rc "the stored appcast verifies" 0 ed verify-feed "$PUB" "$B/transcribe/appcast.xml"
  expect "the DMG's metadata carries its sha256" jq -e --arg sha "$(jq -r .sha256 "$R30")" '.metadata.sha256 == $sha and .contentType == "application/x-apple-diskimage"' "$B/transcribe/Transcribe-0.3.0.dmg.meta.json"
  expect_rc "a second version" 0 publish --release "$R31" --dmg "$T/dmg/Transcribe-0.3.1-TEST.dmg" --appcast "$A31" --dest "dir:$B"
  expect_out "it deleted the first DMG" "transcribe/Transcribe-0.3.1.dmg transcribe/appcast.xml transcribe/latest.json " listing "$B"
  expect_rc "the same version again is refused" 4 publish --release "$R31" --dmg "$T/dmg/Transcribe-0.3.1-TEST.dmg" --appcast "$A31" --dest "dir:$B"
  expect_rc "an older version is refused" 4 publish --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$A30" --dest "dir:$B"
  rm -f "$B/transcribe/appcast.xml" "$B/transcribe/appcast.xml.meta.json"
  cp "$T/dmg/Transcribe-0.3.0-TEST.dmg" "$B/transcribe/Transcribe-0.2.0.dmg"
  expect_rc "--resume after deleting the appcast" 0 publish --resume "$R31" --appcast "$A31" --dest "dir:$B"
  expect_rc "it put the appcast back" 0 cmp "$B/transcribe/appcast.xml" "$A31"
  expect_out "and deleted the leftover DMG" "transcribe/Transcribe-0.3.1.dmg transcribe/appcast.xml transcribe/latest.json " listing "$B"
  snapshot "$B" >"$T/before"
  expect_rc "--resume again" 0 publish --resume "$R31" --appcast "$A31" --dest "dir:$B"
  snapshot "$B" >"$T/after"
  expect_rc "changes nothing" 0 cmp "$T/before" "$T/after"
  expect_rc "--resume with another latest.json is refused" 1 publish --resume "$R30" --appcast "$A30" --dest "dir:$B"

  # --resume-check: what a resume may sign comes from the bucket and is verified first.
  expect_rc "--resume-check of the published release" 0 publish --resume-check "$T/rc/latest.json" --dest "dir:$B"
  expect_rc "  writes the bucket's latest.json" 0 cmp "$T/rc/latest.json" "$B/transcribe/latest.json"
  snapshot "$B" >"$T/after-check"
  expect_rc "  and changes nothing" 0 cmp "$T/before" "$T/after-check"
  expect_rc "--resume-check when project.yml is another version is refused" 1 \
    env PROJECT="$P30PUB" ./scripts/publish-mac.sh --resume-check "$T/rc/latest.json" --dest "dir:$B" --public-key "$PUB"
  expect_rc "  and leaves no file to sign" 0 test ! -e "$T/rc/latest.json"
  B3="$T/bucket3"
  cp -R "$B" "$B3"
  jq --arg sig "$(ed sign "$T/blob" <"$T/seed")" '.edSignature = $sig' "$B/transcribe/latest.json" >"$B3/transcribe/latest.json"
  expect_rc "--resume-check of a latest.json whose signature is not of its DMG is refused" 1 \
    publish --resume-check "$T/rc/latest.json" --dest "dir:$B3"
  expect_rc "  and leaves no file to sign" 0 test ! -e "$T/rc/latest.json"
  rm -rf "$B3"
  cp -R "$B" "$B3"
  flip_byte "$B3/transcribe/Transcribe-0.3.1.dmg" 100000
  expect_rc "--resume-check with a changed DMG is refused" 1 publish --resume-check "$T/rc/latest.json" --dest "dir:$B3"
  expect_rc "--resume-check of an empty bucket is refused" 1 publish --resume-check "$T/rc/latest.json" --dest "dir:$T/nothing"
  expect_rc "--resume-check with an appcast is a usage error" 2 publish --resume-check "$T/rc/latest.json" --appcast "$A31" --dest "dir:$B"

  # The bucket went back to 0.3.0 (a failed publish of 0.3.1 put the old pointer back) after the gate chose resume.
  B4="$T/bucket4"
  expect_rc "a bucket at 0.3.0" 0 publish --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$A30" --dest "dir:$B4"
  cp "$T/dmg/Transcribe-0.3.1-TEST.dmg" "$B4/transcribe/Transcribe-0.3.1.dmg"
  expect_rc "--resume of 0.3.0 while project.yml is 0.3.1 is refused" 1 publish --resume "$R30" --appcast "$A30" --dest "dir:$B4"
  expect_rc "  and deletes nothing" 0 test -f "$B4/transcribe/Transcribe-0.3.1.dmg"

  B2="$T/bucket2"
  cp "$T/dmg/Transcribe-0.3.0-TEST.dmg" "$T/tampered.dmg"
  flip_byte "$T/tampered.dmg" 100000
  expect_rc "a tampered DMG is refused at P1" 1 publish --release "$R30" --dmg "$T/tampered.dmg" --appcast "$A30" --dest "dir:$B2"
  sed 's/<title>Version 0.3.0</<title>Version 0.3.9</' "$A30" >"$T/tampered.xml"
  expect_rc "a tampered appcast is refused at P1" 1 publish --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$T/tampered.xml" --dest "dir:$B2"
  expect_rc "an appcast for another release is refused at P1" 1 publish --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$A31" --dest "dir:$B2"
  expect_rc "nothing was written by the refusals" 0 test ! -e "$B2"
  expect_rc "--public-key with s3 exits 2" 2 ./scripts/publish-mac.sh --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$A30" --public-key "$PUB"
  expect_rc "a -TEST DMG with s3 is refused before any network call" 4 \
    env -u R2_ACCESS_KEY_ID -u R2_SECRET_ACCESS_KEY -u R2_ACCOUNT_ID -u R2_BUCKET BASE_URL=http://127.0.0.1:9 \
    ./scripts/publish-mac.sh --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$A30"

  # -------------------------------------------------------------------------------------------------------------
  section "Delta updates"
  printf 'More fixes.\n' >"$T/notes/0.3.2.txt"
  make_dmg 0.3.2 302 "$PUB"
  BINARY_DELTA="${DERIVED:-${TMPDIR:-/tmp}/transcribe-dd}/SourcePackages/artifacts/sparkle/Sparkle/bin/BinaryDelta"
  mkdir -p "$T/deltas"
  if [ -x "$BINARY_DELTA" ]; then
    mkdelta() { env BINARY_DELTA="$BINARY_DELTA" ./scripts/make-mac-delta.sh "$@"; }
    expect_rc "make-mac-delta.sh 0.3.0 → 0.3.1 (DMGs)" 0 mkdelta "$T/dmg/Transcribe-0.3.0-TEST.dmg" "$T/dmg/Transcribe-0.3.1-TEST.dmg" "$T/deltas"
    cp "$T/out" "$T/mkdelta.out"
    expect "  is named for both versions" test -s "$T/deltas/Transcribe-0.3.0-0.3.1.delta"
    expect "  and was checked by applying it" grep -q 'entries identical' "$T/mkdelta.out"
    expect_rc "make-mac-delta.sh 0.3.1 → 0.3.2 (apps)" 0 mkdelta "$T/dmgsrc-0.3.1/Transcribe.app" "$T/dmgsrc-0.3.2/Transcribe.app" "$T/deltas"
    expect_rc "a delta to an older build is refused" 1 mkdelta "$T/dmg/Transcribe-0.3.1-TEST.dmg" "$T/dmg/Transcribe-0.3.0-TEST.dmg" "$T/deltas"
    expect_rc "  and writes nothing" 0 test ! -e "$T/deltas/Transcribe-0.3.1-0.3.0.delta"
    expect_rc "a missing BinaryDelta is refused" 1 env BINARY_DELTA="$T/nothing" ./scripts/make-mac-delta.sh "$T/dmg/Transcribe-0.3.0-TEST.dmg" "$T/dmg/Transcribe-0.3.1-TEST.dmg" "$T/deltas"
  else
    echo "  skip  make-mac-delta.sh (no $BINARY_DELTA; build the Mac app with DERIVED set to see it); stand-in deltas"
    head -c 5000 /dev/urandom >"$T/deltas/Transcribe-0.3.0-0.3.1.delta"
    head -c 6000 /dev/urandom >"$T/deltas/Transcribe-0.3.1-0.3.2.delta"
  fi
  D01="$T/deltas/Transcribe-0.3.0-0.3.1.delta"
  D12="$T/deltas/Transcribe-0.3.1-0.3.2.delta"
  sign_delta() {
    env SPARKLE_ED_PRIVATE_KEY="$(cat "$1")" DIST="$T/dist-d" NOTES_DIR="$T/notes" ./scripts/sign-mac-release.sh --test \
      --download-prefix http://127.0.0.1:8788/transcribe/download/ "${@:3}" "$T/dmg/Transcribe-$2-TEST.dmg"
  }
  expect_rc "sign --test 0.3.1 --delta 0.3.0-0.3.1" 0 sign_delta "$T/seed" 0.3.1 --delta "$D01"
  RD1="$T/dist-d/Transcribe-0.3.1-TEST.latest.json"
  AD1="$T/dist-d/Transcribe-0.3.1-TEST.appcast.xml"
  expect "latest.json lists the delta with its size, sha256 and signature" jq -e --argjson bytes "$(stat -f %z "$D01")" \
    --arg sha "$(shasum -a 256 "$D01" | cut -d ' ' -f 1)" \
    '.deltas == [{from: "0.3.0", fromBuild: 300, file: "Transcribe-0.3.0-0.3.1.delta", key: "transcribe/Transcribe-0.3.0-0.3.1.delta", bytes: $bytes, sha256: $sha, edSignature: .deltas[0].edSignature}]' "$RD1"
  expect_rc "  whose signature verifies" 0 ed verify "$PUB" "$(jq -r '.deltas[0].edSignature' "$RD1")" "$D01"
  expect "the appcast is well-formed" xmllint --noout "$AD1"
  expect_rc "  and signed" 0 ed verify-feed "$PUB" "$AD1"
  expect "  with the delta under <sparkle:deltas>, from build 300" test "$(xmllint --xpath "string(//*[local-name()='deltas']/*[local-name()='enclosure']/@*[local-name()='deltaFrom'])" "$AD1")" = 300
  expect "  at the test prefix" test "$(xmllint --xpath "string(//*[local-name()='deltas']/*[local-name()='enclosure']/@url)" "$AD1")" = http://127.0.0.1:8788/transcribe/download/Transcribe-0.3.0-0.3.1.delta
  expect "  and the size line names both downloads" grep -q 'From version 0.3.0 the download is under 1 MB. From older versions it is under 1 MB because the speech models are inside the app\.' "$AD1"
  expect_rc "a delta to another version is refused" 1 sign_delta "$T/seed" 0.3.0 --delta "$D01"
  cp "$D01" "$T/deltas/Transcribe-0.3.1-0.3.1.delta"
  expect_rc "a delta from the same version is refused" 1 sign_delta "$T/seed" 0.3.1 --delta "$T/deltas/Transcribe-0.3.1-0.3.1.delta"
  rm -f "$T/deltas/Transcribe-0.3.1-0.3.1.delta"
  expect_rc "--feed-from with --delta is a usage error" 2 env SPARKLE_ED_PRIVATE_KEY="$(cat "$T/seed")" DIST="$T/dist-d" \
    NOTES_DIR="$T/notes" PROJECT="$P31PUB" ./scripts/sign-mac-release.sh --feed-from "$RD1" --delta "$D01"
  expect_rc "--feed-from keeps the deltas of the published release" 0 env SPARKLE_ED_PRIVATE_KEY="$(cat "$T/seed")" \
    DIST="$T/dist-dr" NOTES_DIR="$T/notes" PROJECT="$P31PUB" ./scripts/sign-mac-release.sh --feed-from "$RD1"
  expect "  (the resumed feed has the delta at the production prefix)" test "$(xmllint --xpath "string(//*[local-name()='deltas']/*[local-name()='enclosure']/@url)" "$T/dist-dr/resume.appcast.xml")" = https://w2solutions.ai/transcribe/download/Transcribe-0.3.0-0.3.1.delta
  expect_rc "sign --test 0.3.2 --delta 0.3.1-0.3.2" 0 sign_delta "$T/seed" 0.3.2 --delta "$D12"
  RD2="$T/dist-d/Transcribe-0.3.2-TEST.latest.json"
  AD2="$T/dist-d/Transcribe-0.3.2-TEST.appcast.xml"

  BD="$T/bucket-d"
  expect_rc "publish 0.3.0 (no delta)" 0 publish --release "$R30" --dmg "$T/dmg/Transcribe-0.3.0-TEST.dmg" --appcast "$A30" --dest "dir:$BD"
  snapshot "$BD" >"$T/d-before"
  expect_rc "0.3.1 without its --delta is refused" 1 publish --release "$RD1" --dmg "$T/dmg/Transcribe-0.3.1-TEST.dmg" --appcast "$AD1" --dest "dir:$BD"
  expect_rc "0.3.1 with a delta latest.json does not list is refused" 1 publish --release "$RD1" --dmg "$T/dmg/Transcribe-0.3.1-TEST.dmg" --delta "$D01" --delta "$D12" --appcast "$AD1" --dest "dir:$BD"
  cp "$D01" "$T/tampered.delta"
  flip_byte "$T/tampered.delta" 100
  mkdir -p "$T/tampered-d"
  cp "$T/tampered.delta" "$T/tampered-d/Transcribe-0.3.0-0.3.1.delta"
  expect_rc "0.3.1 with a tampered delta is refused" 1 publish --release "$RD1" --dmg "$T/dmg/Transcribe-0.3.1-TEST.dmg" --delta "$T/tampered-d/Transcribe-0.3.0-0.3.1.delta" --appcast "$AD1" --dest "dir:$BD"
  expect_rc "0.3.1 with the feed of the release without the delta is refused" 1 publish --release "$RD1" --dmg "$T/dmg/Transcribe-0.3.1-TEST.dmg" --delta "$D01" --appcast "$A31" --dest "dir:$BD"
  snapshot "$BD" >"$T/d-after"
  expect_rc "  and the refusals changed nothing" 0 cmp "$T/d-before" "$T/d-after"
  expect_rc "publish 0.3.1 with its delta" 0 publish --release "$RD1" --dmg "$T/dmg/Transcribe-0.3.1-TEST.dmg" --delta "$D01" --appcast "$AD1" --dest "dir:$BD"
  expect_out "the bucket holds the DMG, the delta and the pointers" "transcribe/Transcribe-0.3.0-0.3.1.delta transcribe/Transcribe-0.3.1.dmg transcribe/appcast.xml transcribe/latest.json " listing "$BD"
  expect "the delta's metadata carries its sha256" jq -e --arg sha "$(shasum -a 256 "$D01" | cut -d ' ' -f 1)" '.metadata.sha256 == $sha and .metadata.from == "0.3.0" and .contentType == "application/octet-stream"' "$BD/transcribe/Transcribe-0.3.0-0.3.1.delta.meta.json"
  expect_rc "--resume-check verifies the delta too" 0 publish --resume-check "$T/rc-d/latest.json" --dest "dir:$BD"
  B5="$T/bucket5"
  cp -R "$BD" "$B5"
  flip_byte "$B5/transcribe/Transcribe-0.3.0-0.3.1.delta" 100
  expect_rc "--resume-check with a changed delta is refused" 1 publish --resume-check "$T/rc-d/latest.json" --dest "dir:$B5"
  rm -rf "$B5"
  cp -R "$BD" "$B5"
  rm -f "$B5/transcribe/Transcribe-0.3.0-0.3.1.delta" "$B5/transcribe/Transcribe-0.3.0-0.3.1.delta.meta.json"
  expect_rc "--resume with the delta gone is refused" 1 publish --resume "$RD1" --appcast "$AD1" --dest "dir:$B5"
  rm -rf "$B5"
  rm -f "$BD/transcribe/appcast.xml" "$BD/transcribe/appcast.xml.meta.json"
  expect_rc "--resume after deleting the appcast (with the delta)" 0 publish --resume "$RD1" --appcast "$AD1" --dest "dir:$BD"
  expect_rc "  put the appcast back" 0 cmp "$BD/transcribe/appcast.xml" "$AD1"
  expect_out "  and kept the delta" "transcribe/Transcribe-0.3.0-0.3.1.delta transcribe/Transcribe-0.3.1.dmg transcribe/appcast.xml transcribe/latest.json " listing "$BD"
  expect_rc "publish 0.3.2 with its delta" 0 publish --release "$RD2" --dmg "$T/dmg/Transcribe-0.3.2-TEST.dmg" --delta "$D12" --appcast "$AD2" --dest "dir:$BD"
  expect_out "it deleted the old DMG and the old delta" "transcribe/Transcribe-0.3.1-0.3.2.delta transcribe/Transcribe-0.3.2.dmg transcribe/appcast.xml transcribe/latest.json " listing "$BD"
  expect_rc "--resume with --delta is a usage error" 2 publish --resume "$RD2" --delta "$D12" --appcast "$AD2" --dest "dir:$BD"

  # fetch-published-mac.sh: the published DMG through a local stand-in for the site.
  PUBSITE="$T/pubsite"
  mkdir -p "$PUBSITE/ok/transcribe/download" "$PUBSITE/bad/transcribe/download" "$PUBSITE/none"
  cp "$R31" "$PUBSITE/ok/transcribe/latest.json"
  cp "$T/dmg/Transcribe-0.3.1-TEST.dmg" "$PUBSITE/ok/transcribe/download/Transcribe-0.3.1.dmg"
  cp "$R31" "$PUBSITE/bad/transcribe/latest.json"
  cp "$T/tampered.dmg" "$PUBSITE/bad/transcribe/download/Transcribe-0.3.1.dmg"
  PPORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
  python3 -I "$FIXTURES/serve.py" "$PUBSITE" "$PPORT" &
  PSERVER=$!
  for _ in $(seq 1 50); do
    curl -s -o /dev/null "http://127.0.0.1:$PPORT/none/x" && break
    sleep 0.1
  done
  fetch() { env BASE_URL="http://127.0.0.1:$PPORT/$1" PROJECT="$P31PUB" ./scripts/fetch-published-mac.sh "$2"; }
  expect_rc "fetch-published-mac.sh fetches the published DMG" 0 fetch ok "$T/prev-ok"
  expect_rc "  byte for byte" 0 cmp "$T/prev-ok/Transcribe-0.3.1.dmg" "$T/dmg/Transcribe-0.3.1-TEST.dmg"
  expect_rc "  with its latest.json" 0 cmp "$T/prev-ok/latest.json" "$R31"
  expect_rc "a DMG that does not match latest.json is refused" 1 fetch bad "$T/prev-bad"
  expect_rc "  and leaves nothing" 0 test ! -e "$T/prev-bad/Transcribe-0.3.1.dmg"
  expect_rc "with a key that is not project.yml's it is refused" 1 env BASE_URL="http://127.0.0.1:$PPORT/ok" \
    PROJECT="$(project 0.2.0 0.3.1 "$PUB2")" ./scripts/fetch-published-mac.sh "$T/prev-key"
  expect_rc "nothing published: exit 0" 0 fetch none "$T/prev-none"
  expect_rc "  and nothing written" 0 test ! -e "$T/prev-none/latest.json"
  kill "$PSERVER" 2>/dev/null
  wait "$PSERVER" 2>/dev/null

  # -------------------------------------------------------------------------------------------------------------
  section "publish-mac.sh with s3 (a stand-in AWS CLI on a folder; no network)"
  FAKE="$T/fake-aws"
  printf '#!/bin/sh\nexec python3 -I "%s" "$@"\n' "$FIXTURES/fake-aws.py" >"$FAKE"
  chmod +x "$FAKE"
  # s3 ROOT COMMAND...: COMMAND with the stand-in CLI on ROOT, project.yml at 0.3.1, and a site that never answers.
  s3() {
    local root="$1"
    shift
    env TRANSCRIBE_TEST_AWS_CLI="$FAKE" FAKE_AWS_ROOT="$root" FAKE_AWS_LOG="$root.log" FAKE_AWS_FAIL_GET="${FAIL_GET:-}" PROJECT="$P31PUB" \
      R2_ACCESS_KEY_ID=x R2_SECRET_ACCESS_KEY=x R2_ACCOUNT_ID=x R2_BUCKET=b BASE_URL=http://127.0.0.1:9 "$@"
  }
  # s3_seed ROOT RELEASE DMG APPCAST: a bucket holding that release, written as publish-mac.sh writes it.
  s3_seed() {
    mkdir -p "$1"
    FAKE_AWS_ROOT="$1" "$FAKE" s3 cp "$3" "s3://b/$(jq -r .key "$2")" --content-type application/x-apple-diskimage \
      --metadata "$(jq -c '{sha256, version, build: (.build | tostring), edsignature: .edSignature}' "$2")"
    FAKE_AWS_ROOT="$1" "$FAKE" s3api put-object --bucket b --key transcribe/latest.json --body "$2" --content-type application/json >/dev/null
    FAKE_AWS_ROOT="$1" "$FAKE" s3api put-object --bucket b --key transcribe/appcast.xml --body "$4" --content-type application/xml >/dev/null
  }
  # The 0.3.1 release again, with enclosures under the (unanswering) site, as an s3 release needs; not a -TEST name.
  env SPARKLE_ED_PRIVATE_KEY="$(cat "$T/seed")" DIST="$T/dist9" NOTES_DIR="$T/notes" ./scripts/sign-mac-release.sh --test \
    --download-prefix http://127.0.0.1:9/transcribe/download/ "$T/dmg/Transcribe-0.3.1-TEST.dmg" >/dev/null
  mkdir -p "$T/s3dmg"
  cp "$T/dmg/Transcribe-0.3.1-TEST.dmg" "$T/s3dmg/Transcribe-0.3.1.dmg"
  S3A="$T/s3-a"
  s3_seed "$S3A" "$R30" "$T/dmg/Transcribe-0.3.0-TEST.dmg" "$A30"
  snapshot "$S3A" >"$T/s3-before"
  for key in transcribe/latest.json transcribe/appcast.xml; do
    : >"$S3A.log"
    FAIL_GET="$key"; expect_rc "a failed read of $key (not a missing one) stops the release" 1 \
      s3 "$S3A" ./scripts/publish-mac.sh --release "$T/dist9/Transcribe-0.3.1-TEST.latest.json" \
      --dmg "$T/s3dmg/Transcribe-0.3.1.dmg" --appcast "$T/dist9/Transcribe-0.3.1-TEST.appcast.xml"
    cp "$T/out" "$T/s3.out"
    expect "  with the reason" grep -q "could not read $key in the bucket" "$T/s3.out"
    snapshot "$S3A" >"$T/s3-after"
    expect_rc "  before anything is written" 0 cmp "$T/s3-before" "$T/s3-after"
    expect_rc "  (no upload, write or delete was sent)" 1 grep -Eq '^(cp|put-object|delete-object) ' "$S3A.log"
  done
  FAIL_GET=""
  S3B="$T/s3-b"
  s3_seed "$S3B" "$R31" "$T/dmg/Transcribe-0.3.1-TEST.dmg" "$A31"
  expect_rc "--resume-check through the S3 API" 0 s3 "$S3B" ./scripts/publish-mac.sh --resume-check "$T/rc-s3/latest.json"
  expect_rc "  writes the bucket's latest.json" 0 cmp "$T/rc-s3/latest.json" "$R31"
  FAIL_GET=transcribe/Transcribe-0.3.1.dmg; expect_rc "--resume-check with a failed read of the DMG is refused" 1 \
    s3 "$S3B" ./scripts/publish-mac.sh --resume-check "$T/rc-s3/latest.json"
  FAIL_GET=""
  expect_rc "  and leaves no file to sign" 0 test ! -e "$T/rc-s3/latest.json"

  # -------------------------------------------------------------------------------------------------------------
  section "make-dmg.sh (the styled DMG, from a stub app)"
  # A stub Transcribe.app (another bundle id) with the real app icon, so the volume gets an icon too.
  STUB="$T/stub/Transcribe.app"
  mkdir -p "$STUB/Contents/MacOS" "$STUB/Contents/Resources" "$T/stub/AppIcon.iconset"
  ICONS=Apps/Mac/Resources/Assets.xcassets/AppIcon.appiconset
  for pair in 16x16:16 16x16@2x:32 32x32:32 32x32@2x:64 128x128:128 128x128@2x:256 256x256:256 256x256@2x:512 \
    512x512:512 512x512@2x:1024; do
    cp "$ICONS/icon_${pair#*:}.png" "$T/stub/AppIcon.iconset/icon_${pair%:*}.png"
  done
  iconutil -c icns -o "$STUB/Contents/Resources/AppIcon.icns" "$T/stub/AppIcon.iconset"
  printf '#!/bin/sh\nexit 0\n' >"$STUB/Contents/MacOS/Transcribe"
  chmod +x "$STUB/Contents/MacOS/Transcribe"
  plutil -create xml1 "$STUB/Contents/Info.plist"
  for kv in CFBundleIdentifier=ai.example.dmg-stub CFBundleExecutable=Transcribe CFBundleIconFile=AppIcon \
    CFBundlePackageType=APPL; do
    plutil -insert "${kv%%=*}" -string "${kv#*=}" "$STUB/Contents/Info.plist"
  done
  SDMG="$T/styled/Transcribe-TEST.dmg"
  mkdir -p "$T/styled"
  expect_rc "make-dmg.sh builds a DMG from the stub" 0 ./scripts/make-dmg.sh "$STUB" "$SDMG"
  SMNT="$T/styled/mnt"
  mkdir -p "$SMNT"
  if hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$SMNT" "$SDMG"; then
    DMG_MOUNT="$SMNT"
    expect_out "its root holds the app, the link and only hidden helpers" \
      ".DS_Store .VolumeIcon.icns .background Applications Transcribe.app " sh -c 'LC_ALL=C ls -A "$1" | tr "\n" " "' _ "$SMNT"
    expect_rc "  the app is the stub" 0 cmp "$STUB/Contents/Info.plist" "$SMNT/Transcribe.app/Contents/Info.plist"
    expect_out "  Applications links to /Applications" /Applications readlink "$SMNT/Applications"
    expect_out "  .background and .VolumeIcon.icns are hidden" "hidden hidden" \
      sh -c 'stat -f %Sf "$1/.background" "$1/.VolumeIcon.icns" | tr "\n" " " | sed "s/ $//"' _ "$SMNT"
    expect_out "  the volume has the custom-icon flag" "0400" \
      sh -c 'xattr -px com.apple.FinderInfo "$1" | tr -d " \n" | cut -c 17-20' _ "$SMNT"
    expect_out "background.tiff holds the 1x and 2x pictures" "660x400 1320x800 " \
      sh -c 'tiffutil -info "$1" | awk "/Image Width:/ { printf \"%sx%s \", \$3, \$6 }"' _ "$SMNT/.background/background.tiff"
    expect_rc ".DS_Store parses" 0 sh -c 'python3 -I scripts/dmg-dsstore.py dump "$1" >"$2"' _ "$SMNT/.DS_Store" "$T/styled/ds.json"
    DS="$T/styled/ds.json"
    expect "  the window: 660 x 400 of content under a 32-point title bar, no bars" jq -e \
      '.["."].bwsp | .WindowBounds == "{{240, 320}, {660, 432}}" and ([.ShowToolbar, .ShowSidebar, .ShowStatusBar,
        .ShowPathbar, .ShowTabView, .ContainerShowSidebar] | all(. == false))' "$DS"
    expect "  icon view: icons 128, text 13, labels below, a picture background" jq -e \
      '.["."].icvp | .iconSize == 128 and .textSize == 13 and .labelOnBottom == true and .backgroundType == 2
        and .arrangeBy == "none"' "$DS"
    expect "  the app at (165, 185) and Applications at (495, 185)" jq -e \
      '.["Transcribe.app"].Iloc == {"x": 165, "y": 185} and .Applications.Iloc == {"x": 495, "y": 185}' "$DS"
    expect "  the background alias names this volume and file" jq -e \
      --argjson id "$(stat -f %i "$SMNT/.background/background.tiff")" \
      --argjson vd "$(python3 -I -c 'import os, sys; print(int(os.stat(sys.argv[1]).st_birthtime) + 2082844800)' "$SMNT")" \
      '.["."].icvp.backgroundImageAlias | .volname == "Transcribe" and .file_id == $id and .voldate == $vd
        and .tags["18"] == "/.background/background.tiff" and .tags["19"] == "/Volumes/Transcribe"' "$DS"
    jq -r '.["."].pBBk' "$DS" | xxd -r -p >"$T/styled/bookmark"
    expect_out "  the background bookmark resolves to the picture" "$(cd "$SMNT/.background" && pwd -P)/background.tiff" \
      sh -c 'p="$(xcrun swift scripts/dmg-bookmark.swift resolve "$1")" && echo "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")"' \
      _ "$T/styled/bookmark"
    hdiutil detach -quiet "$SMNT"
    DMG_MOUNT=""
  else
    failed "attach the styled DMG"
  fi
  mkdir -p "$T/art-small"
  sips -z 300 500 Apps/Mac/DMG/background.png --out "$T/art-small/background.png" >/dev/null
  cp Apps/Mac/DMG/background@2x.png "$T/art-small/"
  expect_rc "art of the wrong size is refused" 1 ./scripts/make-dmg.sh "$STUB" "$T/styled/small.dmg" --art "$T/art-small"
  expect_rc "  and nothing is written" 0 test ! -e "$T/styled/small.dmg"
  expect_rc "missing art is refused" 1 ./scripts/make-dmg.sh "$STUB" "$T/styled/none.dmg" --art "$T/stub"
  expect_rc "a folder that is not an .app is refused" 1 ./scripts/make-dmg.sh "$T/stub" "$T/styled/x.dmg"
  expect_rc "no arguments exits 2" 2 ./scripts/make-dmg.sh
else
  section "ed25519.swift, sign-mac-release.sh, publish-mac.sh, make-dmg.sh"
  echo "  skip  (macOS only)"
fi

# ---------------------------------------------------------------------------------------------------------------
section "release-gate.sh"
SITE="$T/site"
mkdir -p "$SITE"
# latest SCENARIO VERSION: a valid latest.json for VERSION under SITE/SCENARIO.
latest() {
  local a b c
  IFS=. read -r a b c <<<"$2"
  mkdir -p "$SITE/$1/transcribe"
  jq -n --arg v "$2" --argjson build $((a * 10000 + b * 100 + c)) --arg sig "$(head -c 64 /dev/urandom | base64 | tr -d '\n')" \
    --arg sha "$(head -c 32 /dev/urandom | shasum -a 256 | cut -d ' ' -f 1)" \
    '{schema: 1, version: $v, build: $build, file: "Transcribe-\($v).dmg", key: "transcribe/Transcribe-\($v).dmg",
      bytes: 655599589, sha256: $sha, edSignature: $sig, minimumSystemVersion: "27.0", published: "2026-11-26T03:12:00Z"}' \
    >"$SITE/$1/transcribe/latest.json"
}
# appcast SCENARIO BUILD: a feed (with a signature block, which the gate ignores) offering BUILD.
appcast() {
  mkdir -p "$SITE/$1/transcribe"
  printf '<?xml version="1.0" encoding="utf-8"?>\n<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item><sparkle:version>%s</sparkle:version></item></channel></rss>\n<!-- sparkle-signatures:\nedSignature: x\nlength: 1\n-->\n' "$2" \
    >"$SITE/$1/transcribe/appcast.xml"
}
mkdir -p "$SITE/empty"
latest l300 0.3.0
latest l300a300 0.3.0
appcast l300a300 300
latest l301a301 0.3.1
appcast l301a301 301
mkdir -p "$SITE/html/transcribe"
echo '<!doctype html><title>W2</title>' >"$SITE/html/transcribe/latest.json"
echo 'text/html; charset=utf-8' >"$SITE/html/transcribe/latest.json.type"
mkdir -p "$SITE/badjson/transcribe"
echo '{"schema": 1, "version": "0.3.0"}' >"$SITE/badjson/transcribe/latest.json"

PORT="$(python3 -I -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
python3 -I "$FIXTURES/serve.py" "$SITE" "$PORT" &
SERVER=$!
for _ in $(seq 1 50); do
  curl -s -o /dev/null "http://127.0.0.1:$PORT/empty/x" && break
  sleep 0.1
done

mkdir -p "$T/gate-notes"
echo "Notes." >"$T/gate-notes/0.3.0.txt"
G200="$(project 0.2.0 0.2.0 "$K")"
G300="$(project 0.2.0 0.3.0 "$K")"
G301="$(project 0.2.0 0.3.1 "$K")"
G200NOKEY="$(project 0.2.0 0.2.0 "")"
G300NOKEY="$(project 0.2.0 0.3.0 "")"

# gate SCENARIO PROJECT EVENT REF PUBLISH NOTARIZE [RUNNER_LABEL]: runs the gate; outputs and summary in $T/gate.
gate() {
  : >"$T/gate.out"
  : >"$T/gate.summary"
  env -u TRANSCRIBE_ED_PUBLIC_KEY -u TRANSCRIBE_FEED_URL -u TRANSCRIBE_TEST_VERSION \
    BASE_URL="http://127.0.0.1:$PORT/$1" PROJECT="$2" NOTES_DIR="$T/gate-notes" GITHUB_EVENT_NAME="$3" GITHUB_REF="$4" \
    INPUT_PUBLISH="$5" INPUT_NOTARIZE="$6" RUNNER_LABEL="${7-transcribe-mac}" \
    GITHUB_OUTPUT="$T/gate.out" GITHUB_STEP_SUMMARY="$T/gate.summary" ./scripts/release-gate.sh
}
# expect_gate NAME WANT ARGS...: WANT is "fail" or "<mode> <notarize>".
expect_gate() {
  local name="$1" want="$2" rc got
  shift 2
  gate "$@" >"$T/out" 2>&1
  rc=$?
  cat "$T/gate.summary" >>"$T/out"
  cp "$T/out" "$T/gate.log"
  if [ "$want" = fail ]; then
    if [ "$rc" = 1 ]; then pass "$name"; else failed "$name (exit $rc, expected a refusal)"; fi
    return
  fi
  got="$(sed -n 's/^mode=//p' "$T/gate.out") $(sed -n 's/^notarize=//p' "$T/gate.out")"
  if [ "$rc" = 0 ] && [ "$got" = "$want" ]; then pass "$name"; else failed "$name (exit $rc, got '$got', expected '$want')"; fi
}
M=refs/heads/main
F=refs/heads/feature
expect_gate "push, newer than published: release" "release true" empty "$G300" push "$M" "" ""
expect_gate "push, 0.2.0 and nothing published: none" "none true" empty "$G200" push "$M" "" ""
expect_gate "push, published and the feed matches: none" "none true" l300a300 "$G300" push "$M" "" ""
expect_gate "push, published but the feed is behind: resume" "resume true" l300 "$G300" push "$M" "" ""
expect_gate "push, behind the published build: fail" fail l301a301 "$G300" push "$M" "" ""
expect_gate "push yields notarize=true whatever the inputs say" "release true" empty "$G300" push "$M" "" false
expect_gate "dispatch, publish=false on any ref: dry-run" "dry-run true" l300a300 "$G300" workflow_dispatch "$F" false true
expect "  and a dry run of a published build warns" grep -q '::warning::0.3.0 (300) is not newer' "$T/gate.log"
expect_gate "dispatch dry run without notarising" "dry-run false" empty "$G300" workflow_dispatch "$F" false false
expect_gate "dispatch dry run with an empty key" "dry-run true" empty "$G300NOKEY" workflow_dispatch "$F" false true
expect_gate "dispatch, publish=true off main: fail" fail empty "$G300" workflow_dispatch "$F" true true
expect_gate "dispatch, publish=true with notarize=false: fail" fail empty "$G300" workflow_dispatch "$M" true false
expect_gate "dispatch, publish=true, newer: release" "release true" empty "$G300" workflow_dispatch "$M" true true
expect_gate "dispatch, publish=true, published: resume" "resume true" l300a300 "$G300" workflow_dispatch "$M" true true
expect_gate "dispatch, publish=true, 0.2.0 and nothing published: none" "none true" empty "$G200" workflow_dispatch "$M" true true
expect_gate "dispatch, publish=true, behind: fail" fail l301a301 "$G300" workflow_dispatch "$M" true true
expect_gate "latest.json served as HTML (the old Worker): fail" fail html "$G300" push "$M" "" ""
expect_gate "an invalid latest.json: fail" fail badjson "$G300" push "$M" "" ""
expect_gate "an empty key with nothing to do: none" "none true" empty "$G200NOKEY" push "$M" "" ""
expect "  and the summary warns about the key" grep -q 'Warning: TRANSCRIBE_ED_PUBLIC_KEY in project.yml is empty' "$T/gate.summary"
expect_gate "an empty key with a release: fail" fail empty "$G300NOKEY" push "$M" "" ""
expect_gate "an empty runner label: fail" fail empty "$G300" push "$M" "" "" ""
expect_gate "no release notes for the version: fail" fail empty "$G301" push "$M" "" ""
expect_gate "an unknown event: fail" fail empty "$G300" pull_request "$M" "" ""
# A dry run of 0.2.0 would build for two hours and then be refused by its own publish step (build 200 is the floor).
echo "Notes." >"$T/gate-notes/0.2.0.txt"
expect_gate "dispatch dry run of 0.2.0 (even with notes): fail" fail empty "$G200" workflow_dispatch "$M" false true
expect "  and says to dispatch from the version-bump branch" grep -q 'a dry run needs a TranscribeMac version above 0.2.0' "$T/gate.log"
rm -f "$T/gate-notes/0.2.0.txt"
expect_gate "dispatch dry run of 0.2.0 without notes: fail" fail empty "$G200" workflow_dispatch "$M" false true
printf '  \n\t\n' >"$T/gate-notes/0.3.2.txt"
G302="$(project 0.2.0 0.3.2 "$K")"
expect_gate "release notes of only white space: fail" fail empty "$G302" push "$M" "" ""
expect "  and says they are empty" grep -q 'the release notes for 0.3.2 are empty' "$T/gate.log"
expect_gate "a dry run with white-space notes: fail" fail empty "$G302" workflow_dispatch "$F" false true
# The release job decides again with the outputs on standard output (GITHUB_OUTPUT empty).
expect_out "with GITHUB_OUTPUT empty the mode is on standard output" "release" \
  env -u TRANSCRIBE_ED_PUBLIC_KEY -u TRANSCRIBE_FEED_URL -u TRANSCRIBE_TEST_VERSION BASE_URL="http://127.0.0.1:$PORT/empty" \
  PROJECT="$G300" NOTES_DIR="$T/gate-notes" GITHUB_EVENT_NAME=push GITHUB_REF="$M" RUNNER_LABEL=transcribe-mac \
  GITHUB_OUTPUT="" GITHUB_STEP_SUMMARY="" sh -c './scripts/release-gate.sh 2>/dev/null | sed -n "s/^mode=//p"'

# ---------------------------------------------------------------------------------------------------------------
section "testflight-gate.sh"
G="$T/tf-repo"
mkdir -p "$G"
git -C "$G" init -q
tf_commit() {
  sed -e "s/@IPHONE@/$1/" -e "s/@MAC@/$2/" -e "s|@KEY@|$K|" "$FIXTURES/project.yml" >"$G/project.yml"
  git -C "$G" add project.yml
  git -C "$G" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m "$1 $2"
  git -C "$G" rev-parse HEAD
}
C1="$(tf_commit 0.2.0 0.3.1)"
C2="$(tf_commit 0.2.0 0.3.2)"
C3="$(tf_commit 0.3.2 0.3.2)"
tf_gate() {
  (cd "$G" && env GITHUB_EVENT_NAME="$1" BEFORE="$2" GITHUB_OUTPUT="" GITHUB_STEP_SUMMARY="" "$ROOT/scripts/testflight-gate.sh" 2>/dev/null |
    sed -n 's/^upload=//p')
}
git -C "$G" checkout -q "$C2"
expect_out "push, only the Mac version changed: no upload" false tf_gate push "$C1"
git -C "$G" checkout -q "$C3"
expect_out "push, the iPhone version changed: upload" true tf_gate push "$C2"
expect_out "push from nothing (all zeros): upload" true tf_gate push 0000000000000000000000000000000000000000
expect_out "push with an unknown earlier commit: upload" true tf_gate push 1234567890123456789012345678901234567890
expect_out "run by hand with no change: upload" true tf_gate workflow_dispatch ""
expect_rc "an unknown event fails" 1 sh -c 'cd "$1" && GITHUB_OUTPUT= GITHUB_STEP_SUMMARY= GITHUB_EVENT_NAME=pull_request "$2/scripts/testflight-gate.sh"' _ "$G" "$ROOT"
expect_out "the iPhone version in the outputs" "version=0.3.2" sh -c 'cd "$1" && GITHUB_OUTPUT= GITHUB_STEP_SUMMARY= GITHUB_EVENT_NAME=workflow_dispatch "$2/scripts/testflight-gate.sh" 2>/dev/null | grep "^version="' _ "$G" "$ROOT"

printf '\n%d passed, %d failed\n' "$PASSED" "$FAILED"
[ "$FAILED" = 0 ]
