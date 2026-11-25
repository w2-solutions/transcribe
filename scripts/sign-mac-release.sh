#!/bin/bash
# Signs a finished Mac release for Sparkle: the EdDSA signature of the DMG, the page pointer latest.json, and the
# signed update feed (appcast). Writes dist/Transcribe-<version>[-TEST].latest.json and .appcast.xml.
#
#   sign-mac-release.sh [--use-keychain] [--delta F]... <dmg>   a release (stapled DMG from make release-mac)
#   sign-mac-release.sh --test [--download-prefix URL] [--delta F]... <dmg>
#                                                               a TEST build's DMG (throwaway key; never published)
#   sign-mac-release.sh --feed-from <latest.json>               resume: rebuild and sign the appcast of a published
#                                                               release (writes dist/resume.appcast.xml); only a
#                                                               file from publish-mac.sh --resume-check, which read
#                                                               it from the bucket and verified its DMG, and only
#                                                               for project.yml's version
#
# --delta F: a delta update to this version from make-mac-delta.sh (Transcribe-<from>-<version>.delta), signed and
# listed in latest.json ("deltas") and in the appcast (<sparkle:deltas>), so a copy on <from> downloads only F.
#
# Key: SPARKLE_ED_PRIVATE_KEY (base64 32-byte seed) in the environment, or --use-keychain (a person approves the
# keychain prompt; refused with --test and in CI). There is no silent keychain fallback. The key reaches
# scripts/ed25519.swift on standard input only; it is never printed or put on a command line.
#
# Environment: DIST (output folder, default <repo>/dist), NOTES_DIR (default <repo>/release-notes/mac), PROJECT
# (tests only: the project.yml to read, default the repo's).
# Every signature is checked against the app's own SUPublicEDKey (read from the DMG), not a key derived from the
# private key; a release also needs the app's key to equal project.yml's and its feed to be the production feed.
#
# Exit: 0 done, 1 failed, 2 usage.
# Runs on macOS /bin/bash 3.2; needs Xcode (xcrun swift), hdiutil, jq and xmllint.
set -euo pipefail

# Take the key out of the environment at once, so no child process inherits it.
KEY="${SPARKLE_ED_PRIVATE_KEY-}"
unset SPARKLE_ED_PRIVATE_KEY

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "$0")"
ED="$ROOT/scripts/ed25519.swift"
DIST="${DIST:-$ROOT/dist}"
NOTES_DIR="${NOTES_DIR:-$ROOT/release-notes/mac}"
PROJECT="${PROJECT:-$ROOT/project.yml}"
PRODUCTION_FEED=https://w2solutions.ai/transcribe/appcast.xml
PRODUCTION_PREFIX=https://w2solutions.ai/transcribe/download/

usage() {
  sed -n '2,28s/^# \{0,1\}//p' "$SELF" >&2
  exit "${1:-2}"
}
fail() {
  echo "error: $*" >&2
  exit 1
}
step() { printf '==> %s\n' "$*"; }

TEST=0
USE_KEYCHAIN=0
PREFIX=""
FEED_FROM=""
DMG=""
DELTAS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --test) TEST=1 ;;
    --use-keychain) USE_KEYCHAIN=1 ;;
    --download-prefix)
      [ $# -ge 2 ] || usage
      PREFIX="$2"
      shift
      ;;
    --feed-from)
      [ $# -ge 2 ] || usage
      FEED_FROM="$2"
      shift
      ;;
    --delta)
      [ $# -ge 2 ] || usage
      DELTAS+=("$2")
      shift
      ;;
    -h | --help) usage 0 ;;
    -*) usage ;;
    *)
      [ -z "$DMG" ] || usage
      DMG="$1"
      ;;
  esac
  shift
done

if [ -n "$FEED_FROM" ]; then
  [ -z "$DMG" ] && [ "$TEST" = 0 ] && [ -z "$PREFIX" ] && [ ${#DELTAS[@]} -eq 0 ] || usage
else
  [ -n "$DMG" ] || usage
fi
if [ -n "$PREFIX" ] && [ "$TEST" = 0 ]; then
  echo "error: --download-prefix is only for --test" >&2
  exit 2
fi
if [ "$USE_KEYCHAIN" = 1 ]; then
  if [ "$TEST" = 1 ] || [ -n "${CI:-}" ]; then
    echo "error: --use-keychain is refused with --test and in CI" >&2
    exit 2
  fi
  if [ -n "$KEY" ]; then
    echo "error: give the key either in SPARKLE_ED_PRIVATE_KEY or with --use-keychain, not both" >&2
    exit 2
  fi
  # A person approves the keychain prompt (Allow, never Always Allow).
  KEY="$(security find-generic-password -s https://sparkle-project.org -a ed25519 -w)" ||
    { echo "error: could not read the update key from the keychain" >&2; exit 2; }
fi
if [ -z "$KEY" ]; then
  echo "error: no key: set SPARKLE_ED_PRIVATE_KEY or pass --use-keychain" >&2
  exit 2
fi
PREFIX="${PREFIX:-$PRODUCTION_PREFIX}"
printf '%s\n' "$PREFIX" | grep -Eq '^https?://[^/]+/(.*/)?$' || { echo "error: the download prefix must be an http(s) URL ending in /" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/sign-mac.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

# ed CMD ARGS...: scripts/ed25519.swift with the key on standard input (printf is a builtin: no command line).
ed_with_key() { printf '%s' "$KEY" | xcrun swift "$ED" "$@"; }
ed() { xcrun swift "$ED" "$@" </dev/null; }

# build_for VERSION: major*10000 + minor*100 + patch (release-mac.sh's rule).
build_for() {
  local a b c
  IFS=. read -r a b c <<<"$1"
  echo $((a * 10000 + b * 100 + c))
}

# The TranscribeMac TRANSCRIBE_ED_PUBLIC_KEY in project.yml.
committed_key() {
  awk '/^  [^ #]/ { mac = ($0 ~ /^  TranscribeMac:/) }
    mac && $1 == "TRANSCRIBE_ED_PUBLIC_KEY:" { v = $2; gsub(/"/, "", v); print v; exit }' "$PROJECT"
}

# valid_release FILE: the latest.json rules (schema, names, sizes, the build number rule, a 64-byte signature).
valid_release() {
  jq -e '
    (.schema == 1)
    and (.version | type == "string" and test("^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$"))
    and (.file == "Transcribe-" + .version + ".dmg") and (.key == "transcribe/" + .file)
    and (.bytes | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
    and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
    and (.build | type == "number" and . > 0 and . == floor)
    and ((.version | split(".") | map(tonumber)) as [$a, $b, $c] | $b < 100 and $c < 100 and .build == $a * 10000 + $b * 100 + $c)
    and (.edSignature | type == "string" and test("^[A-Za-z0-9+/]{86}==$"))
    and (.minimumSystemVersion | type == "string" and test("^[0-9]+(\\.[0-9]+){1,2}$"))
    and (.published | type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
    and ((has("deltas") | not) or (.version as $v | .build as $b | .deltas | type == "array" and length > 0
      and (([.[].fromBuild] | unique | length) == length)
      and all(.[];
        (.from | type == "string" and test("^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$"))
        and (.fromBuild | type == "number" and . > 0 and . == floor and . < $b)
        and ((.from | split(".") | map(tonumber)) as [$x, $y, $z] | $y < 100 and $z < 100 and .fromBuild == $x * 10000 + $y * 100 + $z)
        and (.file == "Transcribe-" + .from + "-" + $v + ".delta") and (.key == "transcribe/" + .file)
        and (.bytes | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
        and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
        and (.edSignature | type == "string" and test("^[A-Za-z0-9+/]{86}==$")))))
  ' "$1" >/dev/null 2>&1
}

# about_mb BYTES: "about N MB", or "under 1 MB".
about_mb() { awk -v b="$1" 'BEGIN { if (b < 1e6) print "under 1 MB"; else printf "about %d MB\n", b / 1e6 + 0.5 }'; }

# xml_escape: &, <, > and " for text and attribute values.
xml_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g'; }

# write_appcast RELEASE_JSON PREFIX PUBKEY OUT: the one-item feed (a pure function of latest.json, the notes and the
# prefix), checked with xmllint, signed, and verified against PUBKEY.
write_appcast() {
  local json="$1" prefix="$2" pubkey="$3" out="$4"
  local version build file bytes sig minsys published pubdate notes size url deltas="" from fbuild dbytes dsig dfile
  version="$(jq -r .version "$json")"
  build="$(jq -r .build "$json")"
  file="$(jq -r .file "$json")"
  bytes="$(jq -r .bytes "$json")"
  sig="$(jq -r .edSignature "$json")"
  minsys="$(jq -r .minimumSystemVersion "$json")"
  case "$minsys" in *.*.*) ;; *) minsys="$minsys.0" ;; esac
  published="$(jq -r .published "$json")"
  pubdate="$(LC_ALL=C date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$published" '+%a, %d %b %Y %H:%M:%S +0000')"
  [ -f "$NOTES_DIR/$version.txt" ] || fail "no release notes: $NOTES_DIR/$version.txt"
  # The same rule as release-gate.sh: at least one character that is not white space.
  grep -q '[^[:space:]]' "$NOTES_DIR/$version.txt" || fail "the release notes are empty: $NOTES_DIR/$version.txt"
  notes="$(xml_escape <"$NOTES_DIR/$version.txt")"
  size="The download is $(about_mb "$bytes") because the speech models are inside the app."
  # One enclosure per delta: a copy whose build is fromBuild downloads that file instead of the DMG (Sparkle falls
  # back to the DMG by itself if the delta fails to download, verify or apply).
  while read -r from fbuild dbytes dsig dfile; do
    [ -n "$from" ] || continue
    deltas="$deltas
        <enclosure url=\"$(printf '%s' "$prefix$dfile" | xml_escape)\" sparkle:deltaFrom=\"$fbuild\" length=\"$dbytes\" type=\"application/octet-stream\" sparkle:edSignature=\"$dsig\"/>"
    size="From version $from the download is $(about_mb "$dbytes"). $size"
  done < <(jq -r '.deltas // [] | .[] | "\(.from) \(.fromBuild) \(.bytes) \(.edSignature) \(.file)"' "$json")
  [ -z "$deltas" ] || size="${size/The download is/From older versions it is}"
  [ -z "$deltas" ] || deltas="
      <sparkle:deltas>$deltas
      </sparkle:deltas>"
  url="$(printf '%s' "$prefix$file" | xml_escape)"
  cat >"$WORK/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Transcribe for Mac</title>
    <link>https://w2solutions.ai/transcribe</link>
    <description>Updates to Transcribe for Mac.</description>
    <language>en</language>
    <item>
      <title>Version $version</title>
      <pubDate>$pubdate</pubDate>
      <sparkle:version>$build</sparkle:version>
      <sparkle:shortVersionString>$version</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$minsys</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <link>https://w2solutions.ai/transcribe</link>
      <description sparkle:format="plain-text">$notes

$size After it installs, Transcribe prepares its speech models again, which takes about a minute. If the download keeps failing, get the latest version at w2solutions.ai/transcribe.</description>
      <enclosure url="$url" length="$bytes" type="application/octet-stream" sparkle:edSignature="$sig"/>$deltas
    </item>
  </channel>
</rss>
EOF
  xmllint --noout "$WORK/appcast.xml" || fail "the appcast is not well-formed XML"
  rm -f "$out"
  ed_with_key sign-feed "$WORK/appcast.xml" "$out" || fail "could not sign the appcast"
  ed verify-feed "$pubkey" "$out" || fail "the signed appcast does not verify against the app's key"
}

mkdir -p "$DIST"
DERIVED_KEY="$(ed_with_key public-key)" || fail "the key is not a valid update key"

# Resume: the appcast for an already published latest.json (no DMG, no new signature of it).
if [ -n "$FEED_FROM" ]; then
  step "Appcast for the published release in $FEED_FROM"
  valid_release "$FEED_FROM" || fail "$FEED_FROM is not a valid latest.json"
  [ "$(env -u TRANSCRIBE_ED_PUBLIC_KEY -u TRANSCRIBE_FEED_URL -u TRANSCRIBE_TEST_VERSION PROJECT="$PROJECT" \
    "$ROOT/scripts/release-mac.sh" --print-version)" = "$(jq -r '"\(.version) \(.build)"' "$FEED_FROM")" ] ||
    fail "$FEED_FROM is not the version in project.yml"
  APP_PUBKEY="$(committed_key)"
  [ -n "$APP_PUBKEY" ] || fail "TRANSCRIBE_ED_PUBLIC_KEY in project.yml is empty"
  [ "$DERIVED_KEY" = "$APP_PUBKEY" ] || fail "this key does not belong to this app (project.yml's TRANSCRIBE_ED_PUBLIC_KEY)"
  write_appcast "$FEED_FROM" "$PRODUCTION_PREFIX" "$APP_PUBKEY" "$DIST/resume.appcast.xml"
  echo "$DIST/resume.appcast.xml"
  exit 0
fi

[ -f "$DMG" ] || fail "no such DMG: $DMG"

# 2. A release DMG must be stapled (notarised).
if [ "$TEST" = 0 ]; then
  step "Stapled ticket"
  xcrun stapler validate "$DMG" || fail "the DMG is not stapled: run make release-mac to the end first"
fi

# 3. What the app inside trusts.
step "The app inside $(basename "$DMG")"
mkdir "$WORK/mnt"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$WORK/mnt" "$DMG" || fail "could not attach $DMG"
MOUNT="$WORK/mnt"
PLIST="$MOUNT/Transcribe.app/Contents/Info.plist"
[ -f "$PLIST" ] || fail "no Transcribe.app in $DMG"
pv() { /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || true; }
VERSION="$(pv CFBundleShortVersionString)"
BUILD="$(pv CFBundleVersion)"
APP_PUBKEY="$(pv SUPublicEDKey)"
APP_FEED="$(pv SUFeedURL)"
MINSYS="$(pv LSMinimumSystemVersion)"
hdiutil detach -quiet "$MOUNT"
MOUNT=""
printf '%s\n' "$VERSION" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$' || fail "the app's version '$VERSION' is not valid"
[ "$BUILD" = "$(build_for "$VERSION")" ] || fail "the app's build $BUILD is not $(build_for "$VERSION") (the rule for $VERSION)"
[ -n "$MINSYS" ] || fail "the app has no LSMinimumSystemVersion"
echo "    version $VERSION (build $BUILD), feed $APP_FEED, key $APP_PUBKEY"

# 4. The key must be the one this build trusts; a release also needs the committed key and the production feed.
[ -n "$APP_PUBKEY" ] || fail "the app has no SUPublicEDKey"
[ "$DERIVED_KEY" = "$APP_PUBKEY" ] || fail "this key does not belong to this build (the app's SUPublicEDKey differs)"
if [ "$TEST" = 0 ]; then
  [ "$APP_PUBKEY" = "$(committed_key)" ] || fail "the app's SUPublicEDKey is not project.yml's TRANSCRIBE_ED_PUBLIC_KEY"
  [ "$APP_FEED" = "$PRODUCTION_FEED" ] || fail "the app's SUFeedURL is not $PRODUCTION_FEED"
fi

# 5. The archive signature, checked against the app's key.
step "EdDSA signature of the DMG"
SIG="$(ed_with_key sign "$DMG")" || fail "could not sign $DMG"
ed verify "$APP_PUBKEY" "$SIG" "$DMG" || fail "the DMG signature does not verify against the app's key"
echo "    $SIG"

# 6. The deltas (make-mac-delta.sh): named for this version, signed, and checked against the app's key.
echo '[]' >"$WORK/deltas.json"
for d in ${DELTAS[@]+"${DELTAS[@]}"}; do
  [ -f "$d" ] || fail "no such delta: $d"
  dname="$(basename "$d")"
  dfrom="${dname#Transcribe-}"
  dfrom="${dfrom%-"$VERSION".delta}"
  [ "$dname" = "Transcribe-$dfrom-$VERSION.delta" ] || fail "$dname is not a delta to $VERSION (Transcribe-<from>-$VERSION.delta)"
  printf '%s\n' "$dfrom" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$' || fail "$dname: '$dfrom' is not a version"
  [ "$(build_for "$dfrom")" -lt "$BUILD" ] || fail "$dname: $dfrom is not older than $VERSION"
  step "EdDSA signature of $dname"
  DSIG="$(ed_with_key sign "$d")" || fail "could not sign $d"
  ed verify "$APP_PUBKEY" "$DSIG" "$d" || fail "the signature of $dname does not verify against the app's key"
  jq --arg from "$dfrom" --argjson fromBuild "$(build_for "$dfrom")" --arg file "$dname" --arg key "transcribe/$dname" \
    --argjson bytes "$(stat -f %z "$d")" --arg sha256 "$(shasum -a 256 "$d" | cut -d ' ' -f 1)" --arg edSignature "$DSIG" \
    '. + [{from: $from, fromBuild: $fromBuild, file: $file, key: $key, bytes: $bytes, sha256: $sha256, edSignature: $edSignature}]' \
    "$WORK/deltas.json" >"$WORK/deltas.next" && mv "$WORK/deltas.next" "$WORK/deltas.json"
  echo "    $dfrom → $VERSION: $(stat -f %z "$d") bytes, $DSIG"
done

# 7. latest.json ("deltas" only when there are any).
SUFFIX=""
[ "$TEST" = 0 ] || SUFFIX="-TEST"
RELEASE="$DIST/Transcribe-$VERSION$SUFFIX.latest.json"
FILE="Transcribe-$VERSION.dmg"
jq -n --arg version "$VERSION" --argjson build "$BUILD" --arg file "$FILE" --arg key "transcribe/$FILE" \
  --argjson bytes "$(stat -f %z "$DMG")" --arg sha256 "$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)" \
  --arg edSignature "$SIG" --arg minimumSystemVersion "$MINSYS" --arg published "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --slurpfile deltas "$WORK/deltas.json" \
  '{schema: 1, version: $version, build: $build, file: $file, key: $key, bytes: $bytes, sha256: $sha256,
    edSignature: $edSignature, minimumSystemVersion: $minimumSystemVersion, published: $published}
    + (if ($deltas[0] | length) > 0 then {deltas: $deltas[0]} else {} end)' >"$RELEASE"
valid_release "$RELEASE" || fail "wrote an invalid $RELEASE"
step "Wrote $RELEASE"

# 8. The signed appcast.
APPCAST="$DIST/Transcribe-$VERSION$SUFFIX.appcast.xml"
write_appcast "$RELEASE" "$PREFIX" "$APP_PUBKEY" "$APPCAST"
step "Wrote $APPCAST (signed; verified against the app's key)"
