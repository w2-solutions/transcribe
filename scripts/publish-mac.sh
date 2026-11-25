#!/bin/bash
# Publishes a signed Mac release (from sign-mac-release.sh) to the download bucket, in an order that keeps every
# reader consistent: upload and verify the DMG; switch the page (latest.json) and check it through the public site;
# switch the update feed (appcast.xml) and check it; then delete older DMGs. Needs no private key.
#
#   publish-mac.sh --release <latest.json> --dmg <dmg> --appcast <appcast.xml> [--dest s3|dir:<path>] [--public-key KEY]
#   publish-mac.sh --resume <latest.json> --appcast <appcast.xml> [--dest s3|dir:<path>] [--public-key KEY]
#   publish-mac.sh --resume-check <out.json> [--dest s3|dir:<path>] [--public-key KEY]
#
# --release publishes a new version: its build must be higher than the published one (and than 0.2.0's 200).
# --resume repairs a release that stopped part-way: <latest.json> must equal the bucket's byte for byte and be
# project.yml's version; the feed is written only if the bucket's is missing, badly signed or for another release;
# older DMGs are deleted.
# --resume-check runs before a resume signs a feed, and changes nothing: the bucket's latest.json (read from the
# bucket, never through the site) must be valid and project.yml's version, and its DMG must have that size, sha256
# and signature. Writes that latest.json to <out.json>, the only file sign-mac-release.sh --feed-from may sign.
#
# Destinations: s3 (default) is the R2 bucket through its S3 API, with public checks through the site. dir:<path>
# keeps objects in a local folder (<path>/<key>, metadata in <path>/<key>.meta.json) and makes no network call; it is
# for dry runs and tests. Signatures are checked against project.yml's TRANSCRIBE_ED_PUBLIC_KEY, or --public-key
# (dir: only). A -TEST DMG is refused with s3.
#
# Env (s3): R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_BUCKET; BASE_URL (default https://w2solutions.ai)
# Env (tests only): PROJECT (the project.yml to read; default the repo's), TRANSCRIBE_TEST_AWS_CLI (a stand-in for
# /usr/local/bin/aws)
# Rule: a DMG that latest.json or the appcast refers to is never overwritten.
# Exit: 0 published (or nothing to do); 1 failed (nothing public changed, or the pointer was put back); 2 usage;
#       4 refused
# Runs on macOS /bin/bash 3.2; needs Xcode (xcrun swift), jq, xmllint, curl and (s3) /usr/local/bin/aws.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "$0")"
ED="$ROOT/scripts/ed25519.swift"
BASE_URL="${BASE_URL:-https://w2solutions.ai}"
BASE_URL="${BASE_URL%/}"
PROJECT="${PROJECT:-$ROOT/project.yml}"
AWS_CLI="${TRANSCRIBE_TEST_AWS_CLI:-/usr/local/bin/aws}"
PREFIX=transcribe/
LATEST_KEY=transcribe/latest.json
APPCAST_KEY=transcribe/appcast.xml
RERUN="gh workflow run mac-release.yml --ref main -f publish=true"

usage() {
  sed -n '2,30s/^# \{0,1\}//p' "$SELF" >&2
  exit 2
}
fail() {
  echo "error: $*" >&2
  exit 1
}
refuse() {
  echo "refused: $*" >&2
  exit 4
}
step() { printf '==> %s\n' "$*"; }

MODE=""
RELEASE=""
DMG=""
APPCAST=""
DEST=s3
PUBKEY=""
while [ $# -gt 0 ]; do
  [ $# -ge 2 ] || usage
  case "$1" in
    --release | --resume | --resume-check)
      [ -z "$MODE" ] || usage
      MODE="${1#--}"
      RELEASE="$2"
      ;;
    --dmg) DMG="$2" ;;
    --appcast) APPCAST="$2" ;;
    --dest) DEST="$2" ;;
    --public-key) PUBKEY="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$MODE" ] && [ -n "$RELEASE" ] || usage
if [ "$MODE" = resume-check ]; then [ -z "$APPCAST" ] || usage; else [ -n "$APPCAST" ] || usage; fi
if [ "$MODE" = release ]; then [ -n "$DMG" ] || usage; else [ -z "$DMG" ] || usage; fi
case "$DEST" in
  s3) [ -z "$PUBKEY" ] || { echo "error: --public-key is only for dir: destinations" >&2; exit 2; } ;;
  dir:?*) DIR="${DEST#dir:}" ;;
  *) usage ;;
esac

# A TEST build is never published, and this is decided before any network call.
if [ "$DEST" = s3 ] && [ -n "$DMG" ]; then
  case "$(basename "$DMG")" in *-TEST*) refuse "$DMG is a TEST build; TEST builds are never published" ;; esac
fi

if [ -z "$PUBKEY" ]; then
  PUBKEY="$(awk '/^  [^ #]/ { mac = ($0 ~ /^  TranscribeMac:/) }
    mac && $1 == "TRANSCRIBE_ED_PUBLIC_KEY:" { v = $2; gsub(/"/, "", v); print v; exit }' "$PROJECT")"
  [ -n "$PUBKEY" ] || fail "TRANSCRIBE_ED_PUBLIC_KEY in project.yml is empty"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/publish-mac.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

if [ "$DEST" = s3 ]; then
  for v in R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_ACCOUNT_ID R2_BUCKET; do
    [ -n "${!v:-}" ] || { echo "error: $v is not set (environment mac-release)" >&2; exit 2; }
  done
  # The AWS CLI sees only R2: its own config file, no shared credentials or profiles, no instance metadata.
  cat >"$WORK/aws-config" <<'EOF'
[default]
region = auto
request_checksum_calculation = when_required
response_checksum_validation = when_required
s3 =
  multipart_chunksize = 64MB
  multipart_threshold = 64MB
  max_concurrent_requests = 8
EOF
  export AWS_CONFIG_FILE="$WORK/aws-config" AWS_SHARED_CREDENTIALS_FILE=/dev/null AWS_EC2_METADATA_DISABLED=true
  unset AWS_PROFILE AWS_DEFAULT_PROFILE AWS_SESSION_TOKEN AWS_ENDPOINT_URL
  export AWS_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID" AWS_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY" AWS_PAGER=""
  export AWS_ENDPOINT_URL_S3="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com"
  BUCKET="$R2_BUCKET"
fi
# --only-show-errors is an option of the s3 transfer commands only (aws s3 cp); before s3api it is a usage error.
aws_() { "$AWS_CLI" --no-cli-pager "$@"; }

# --- Storage: the same five operations on R2 and on a local folder. -------------------------------------------

# s3_absent STDERR_FILE: true when the failed call said the key does not exist.
s3_absent() { grep -Eq '\((404|NoSuchKey)\)|Not Found' "$1"; }

# store_put FILE KEY CONTENT_TYPE [METADATA_JSON]
store_put() {
  if [ "$DEST" = s3 ]; then
    if [ -n "${4:-}" ]; then
      aws_ s3 cp "$1" "s3://$BUCKET/$2" --only-show-errors --no-progress --content-type "$3" --metadata "$4"
    else
      aws_ s3api put-object --bucket "$BUCKET" --key "$2" --body "$1" --content-type "$3" >/dev/null
    fi
  else
    local meta="${4:-}"
    [ -n "$meta" ] || meta='{}'
    mkdir -p "$(dirname "$DIR/$2")"
    cp "$1" "$DIR/$2.partial" && mv "$DIR/$2.partial" "$DIR/$2"
    jq -n --arg ct "$3" --argjson meta "$meta" '{contentType: $ct, metadata: $meta}' >"$DIR/$2.meta.json"
  fi
}

# store_get KEY OUT: 1 only when the key is absent. Any other failed read exits 1, so a caller never takes a read
# error for "not published yet", and OUT is never left half-written.
store_get() {
  if [ "$DEST" = s3 ]; then
    rm -f "$2" "$2.partial"
    store_head "$1" >/dev/null || return 1
    if ! aws_ s3api get-object --bucket "$BUCKET" --key "$1" "$2.partial" >/dev/null 2>"$WORK/get.err"; then
      rm -f "$2.partial"
      s3_absent "$WORK/get.err" && return 1
      cat "$WORK/get.err" >&2
      fail "could not read $1 in the bucket"
    fi
    mv "$2.partial" "$2"
  else
    [ -f "$DIR/$1" ] || return 1
    cp "$DIR/$1" "$2"
  fi
}

# store_head KEY: prints "<bytes> <metadata sha256>"; 1 when the key is absent.
store_head() {
  if [ "$DEST" = s3 ]; then
    local out
    if ! out="$(aws_ s3api head-object --bucket "$BUCKET" --key "$1" --output json 2>"$WORK/head.err")"; then
      s3_absent "$WORK/head.err" && return 1
      cat "$WORK/head.err" >&2
      fail "could not read $1 in the bucket"
    fi
    jq -r '"\(.ContentLength) \(.Metadata.sha256 // "")"' <<<"$out"
  else
    [ -f "$DIR/$1" ] || return 1
    echo "$(stat -f %z "$DIR/$1") $(jq -r '.metadata.sha256 // ""' "$DIR/$1.meta.json" 2>/dev/null || true)"
  fi
}

# store_list PREFIX: one key per line.
store_list() {
  if [ "$DEST" = s3 ]; then
    local out
    out="$(aws_ s3api list-objects-v2 --bucket "$BUCKET" --prefix "$1" --query 'Contents[].Key' --output text)" || return 1
    printf '%s\n' "$out" | tr '\t' '\n' | grep -v -e '^None$' -e '^$' || true
  else
    [ -d "$DIR" ] || return 0
    (cd "$DIR" && find . -type f ! -name '*.meta.json' ! -name '*.partial' | sed 's|^\./||' | grep "^$1" | sort) || true
  fi
}

# store_delete KEY
store_delete() {
  if [ "$DEST" = s3 ]; then
    aws_ s3api delete-object --bucket "$BUCKET" --key "$1" >/dev/null
  else
    rm -f "$DIR/$1" "$DIR/$1.meta.json"
  fi
}

# --- Checks -------------------------------------------------------------------------------------------------------

# is_project_version VERSION BUILD: project.yml's TranscribeMac version and build (release-mac.sh's rule).
is_project_version() {
  [ "$(env -u TRANSCRIBE_ED_PUBLIC_KEY -u TRANSCRIBE_FEED_URL -u TRANSCRIBE_TEST_VERSION PROJECT="$PROJECT" \
    "$ROOT/scripts/release-mac.sh" --print-version)" = "$1 $2" ]
}

ed() { xcrun swift "$ED" "$@" </dev/null; }

# valid_release FILE: the latest.json rules (as sign-mac-release.sh writes them).
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
  ' "$1" >/dev/null 2>&1
}

# appcast_agrees APPCAST RELEASE_JSON: a single item whose version, build, length, signature and enclosure URL are
# the release's (the enclosure is $BASE_URL/transcribe/download/<file> with s3; it ends in /<file> with dir:).
# Prints what disagrees.
appcast_agrees() {
  local xml="$1" json="$2" url
  xp() { xmllint --xpath "$1" "$xml" 2>/dev/null || true; }
  [ "$(xp "count(//*[local-name()='item'])")" = 1 ] || { echo "the appcast must have exactly one item"; return 1; }
  [ "$(xp "string(//*[local-name()='item']/*[local-name()='shortVersionString'])")" = "$(jq -r .version "$json")" ] ||
    { echo "version differs"; return 1; }
  [ "$(xp "string(//*[local-name()='item']/*[local-name()='version'])")" = "$(jq -r .build "$json")" ] ||
    { echo "build differs"; return 1; }
  [ "$(xp "string(//*[local-name()='enclosure']/@length)")" = "$(jq -r .bytes "$json")" ] ||
    { echo "length differs"; return 1; }
  [ "$(xp "string(//*[local-name()='enclosure']/@*[local-name()='edSignature'])")" = "$(jq -r .edSignature "$json")" ] ||
    { echo "edSignature differs"; return 1; }
  url="$(xp "string(//*[local-name()='enclosure']/@url)")"
  if [ "$DEST" = s3 ]; then
    [ "$url" = "$BASE_URL/transcribe/download/$(jq -r .file "$json")" ] || { echo "enclosure URL is $url"; return 1; }
  else
    case "$url" in */"$(jq -r .file "$json")") ;; *) echo "enclosure URL is $url"; return 1 ;; esac
  fi
}

# check_feed APPCAST RELEASE_JSON WHAT: signed with the key and agreeing with the release, or exit 1.
check_feed() {
  local why
  ed verify-feed "$PUBKEY" "$1" || fail "$3: the feed signature does not verify against $PUBKEY"
  why="$(appcast_agrees "$1" "$2")" || fail "$3 does not match the release: $why"
}

# verify_stored_dmg KEY RELEASE_JSON: head (size, metadata) and a full read-back (sha256, Ed25519).
verify_stored_dmg() {
  local head bytes sha
  head="$(store_head "$1")" || fail "$1 is not in the bucket"
  bytes="$(jq -r .bytes "$2")"
  sha="$(jq -r .sha256 "$2")"
  [ "${head%% *}" = "$bytes" ] || fail "$1 is ${head%% *} bytes in the bucket, expected $bytes"
  [ "${head#* }" = "$sha" ] || fail "$1 has metadata sha256 '${head#* }', expected $sha"
  store_get "$1" "$WORK/readback.dmg" || fail "could not read back $1"
  [ "$(shasum -a 256 "$WORK/readback.dmg" | cut -d ' ' -f 1)" = "$sha" ] || fail "the read-back of $1 has the wrong sha256"
  ed verify "$PUBKEY" "$(jq -r .edSignature "$2")" "$WORK/readback.dmg" ||
    fail "the read-back of $1 does not verify against $PUBKEY"
  rm -f "$WORK/readback.dmg"
  echo "    $1: $bytes bytes, sha256 $sha, EdDSA verified on the read-back"
}

# public_page_ok RELEASE_JSON: through the site, latest.json is these bytes, the page shows the version, and
# /transcribe/download redirects to this DMG, whose bytes hash right. s3 only.
public_page_ok() {
  local json="$1" version file code
  version="$(jq -r .version "$json")"
  file="$(jq -r .file "$json")"
  curl --retry 3 -fsS "$BASE_URL/transcribe/latest.json" -o "$WORK/public.json" || { echo "latest.json not served"; return 1; }
  cmp -s "$WORK/public.json" "$json" || { echo "the public latest.json differs"; return 1; }
  # To a file first: grep -q stops reading early, and with pipefail curl's broken pipe would fail the check.
  curl --retry 3 -fsS "$BASE_URL/transcribe" -o "$WORK/public.html" || { echo "the page is not served"; return 1; }
  grep -Fq "Version $version ·" "$WORK/public.html" || { echo "the page does not show Version $version"; return 1; }
  code="$(curl --retry 3 -sSI -o /dev/null -w '%{http_code} %{redirect_url}' "$BASE_URL/transcribe/download")"
  case "$code" in "302 "*"/transcribe/download/$file") ;; *) echo "/transcribe/download answered '$code'"; return 1 ;; esac
  [ "$(curl --retry 3 -fsSL "$BASE_URL/transcribe/download" | shasum -a 256 | cut -d ' ' -f 1)" = "$(jq -r .sha256 "$json")" ] ||
    { echo "the public download has the wrong sha256"; return 1; }
  echo "    public: latest.json, page 'Version $version', 302 to $file, download sha256"
}

# public_feed_ok APPCAST: the public feed is these bytes and verifies. s3 only.
public_feed_ok() {
  curl --retry 3 -fsS "$BASE_URL/transcribe/appcast.xml" -o "$WORK/public.xml" || { echo "appcast.xml not served"; return 1; }
  cmp -s "$WORK/public.xml" "$1" || { echo "the public appcast differs"; return 1; }
  ed verify-feed "$PUBKEY" "$WORK/public.xml" || { echo "the public appcast does not verify"; return 1; }
  echo "    public: appcast.xml bytes and signature"
}

# restore_pointer KEY PREVIOUS_FILE CONTENT_TYPE: put the previous object back, or delete the key if there was none.
# Always returns 0, so the caller still exits 1; a failed restore is reported for a person to repair.
restore_pointer() {
  if [ -f "$2" ]; then
    if store_put "$2" "$1" "$3"; then echo "    put back the previous $1" >&2; return 0; fi
  else
    if store_delete "$1"; then echo "    deleted $1 (there was none before)" >&2; return 0; fi
  fi
  echo "::error::Could not put back the previous $1: the bucket now holds the new one. Repair it by hand or re-run: $RERUN"
}

# write_feed: P7. Writes the appcast and checks it; on failure puts the previous one back and exits 1.
write_feed() {
  local why
  step "Write $APPCAST_KEY"
  store_put "$APPCAST" "$APPCAST_KEY" "application/xml" || { restore_pointer "$APPCAST_KEY" "$WORK/prev.appcast.xml" application/xml; fail "could not write $APPCAST_KEY"; }
  if [ "$DEST" = s3 ]; then
    if ! why="$(public_feed_ok "$APPCAST")"; then
      echo "error: public check of the feed failed: $why" >&2
      restore_pointer "$APPCAST_KEY" "$WORK/prev.appcast.xml" application/xml
      exit 1
    fi
    echo "$why"
  else
    store_get "$APPCAST_KEY" "$WORK/stored.xml" || fail "could not read back $APPCAST_KEY"
    cmp -s "$WORK/stored.xml" "$APPCAST" || fail "the stored appcast differs"
  fi
}

# clean_up: P8. Deletes every older DMG, then asserts the final set.
clean_up() {
  local current="$1" key left="" others=""
  step "Delete older DMGs"
  store_list "${PREFIX}Transcribe-" >"$WORK/list" || fail "could not list the bucket"
  while IFS= read -r key; do
    case "$key" in
      "$current") ;;
      transcribe/Transcribe-*.dmg)
        if store_delete "$key"; then echo "    deleted $key"; else left="$left $key"; fi
        ;;
    esac
  done <"$WORK/list"
  store_list "$PREFIX" >"$WORK/list" || fail "could not list the bucket"
  while IFS= read -r key; do
    case "$key" in
      "$current" | "$LATEST_KEY" | "$APPCAST_KEY") ;;
      transcribe/Transcribe-*.dmg) left="$left $key" ;;
      *) others="$others $key" ;;
    esac
  done <"$WORK/list"
  [ -z "$others" ] || echo "warning: other keys under $PREFIX left alone:$others" >&2
  for key in "$current" "$LATEST_KEY" "$APPCAST_KEY"; do
    store_head "$key" >/dev/null || left="$left (missing $key)"
  done
  if [ -n "$left" ]; then
    echo "::error::Old DMG(s) left in the bucket:$left. Re-run: $RERUN"
    exit 1
  fi
  echo "    the bucket holds $current, $LATEST_KEY and $APPCAST_KEY"
}

# --- Resume check: what a resume may sign, read from the bucket itself and verified. Writes only <out.json>. -----
if [ "$MODE" = resume-check ]; then
  rm -f "$RELEASE"
  step "Resume check: the bucket's $LATEST_KEY"
  store_get "$LATEST_KEY" "$WORK/bucket.json" || fail "the bucket has no $LATEST_KEY to resume"
  valid_release "$WORK/bucket.json" || fail "the bucket's $LATEST_KEY is not a valid latest.json"
  VERSION="$(jq -r .version "$WORK/bucket.json")"
  BUILD="$(jq -r .build "$WORK/bucket.json")"
  is_project_version "$VERSION" "$BUILD" ||
    fail "the bucket's $LATEST_KEY is $VERSION ($BUILD), not the version in project.yml; nothing to resume"
  echo "    Transcribe $VERSION (build $BUILD), key $PUBKEY"
  verify_stored_dmg "$(jq -r .key "$WORK/bucket.json")" "$WORK/bucket.json"
  mkdir -p "$(dirname "$RELEASE")"
  cp "$WORK/bucket.json" "$RELEASE"
  step "Checked: $RELEASE"
  exit 0
fi

# --- P1: validate everything local. ---------------------------------------------------------------------------
step "Check $(basename "$RELEASE") and $(basename "$APPCAST")"
valid_release "$RELEASE" || fail "$RELEASE is not a valid latest.json"
VERSION="$(jq -r .version "$RELEASE")"
BUILD="$(jq -r .build "$RELEASE")"
KEY="$(jq -r .key "$RELEASE")"
echo "    Transcribe $VERSION (build $BUILD), $KEY, key $PUBKEY"
# A resume only ever repairs project.yml's version (the bucket may have gone back to an older release since the gate
# decided). A release to the bucket must be it too; a dry run or a test release to a folder may be a TEST version.
if [ "$MODE" = resume ] || [ "$DEST" = s3 ]; then
  is_project_version "$VERSION" "$BUILD" || fail "$VERSION ($BUILD) is not the version in project.yml"
fi

if [ "$MODE" = resume ]; then
  step "Resume: compare with the bucket's latest.json"
  store_get "$LATEST_KEY" "$WORK/bucket.json" || fail "the bucket has no $LATEST_KEY to resume"
  cmp -s "$WORK/bucket.json" "$RELEASE" || fail "$RELEASE is not the bucket's $LATEST_KEY"
  verify_stored_dmg "$KEY" "$RELEASE"
  if [ "$DEST" = s3 ]; then
    step "Public check of the page"
    why="$(public_page_ok "$RELEASE")" || fail "public check of the page failed: $why"
    echo "$why"
  fi
  step "The bucket's feed"
  if store_get "$APPCAST_KEY" "$WORK/prev.appcast.xml" && ed verify-feed "$PUBKEY" "$WORK/prev.appcast.xml" &&
    appcast_agrees "$WORK/prev.appcast.xml" "$RELEASE" >/dev/null; then
    echo "    $APPCAST_KEY is signed and matches; left as it is"
  else
    check_feed "$APPCAST" "$RELEASE" "$APPCAST"
    write_feed
  fi
  clean_up "$KEY"
  step "Done: $VERSION is published"
  exit 0
fi

[ -f "$DMG" ] || fail "no such DMG: $DMG"
[ "$(stat -f %z "$DMG")" = "$(jq -r .bytes "$RELEASE")" ] || fail "$DMG is not the size in $RELEASE"
[ "$(shasum -a 256 "$DMG" | cut -d ' ' -f 1)" = "$(jq -r .sha256 "$RELEASE")" ] || fail "$DMG does not have the sha256 in $RELEASE"
ed verify "$PUBKEY" "$(jq -r .edSignature "$RELEASE")" "$DMG" || fail "$DMG does not verify against $PUBKEY"
check_feed "$APPCAST" "$RELEASE" "$APPCAST"
echo "    DMG size, sha256 and EdDSA signature; feed signature and contents"

# --- P2: what is published now. --------------------------------------------------------------------------------
step "Read the bucket"
PREV_BUILD=200
if store_get "$LATEST_KEY" "$WORK/prev.latest.json"; then
  valid_release "$WORK/prev.latest.json" || fail "the bucket's $LATEST_KEY is not valid; repair it by hand first"
  PREV_BUILD="$(jq -r .build "$WORK/prev.latest.json")"
  [ "$PREV_BUILD" -ge 200 ] || PREV_BUILD=200
  echo "    published: $(jq -r .version "$WORK/prev.latest.json") (build $(jq -r .build "$WORK/prev.latest.json"))"
else
  rm -f "$WORK/prev.latest.json"
  echo "    no $LATEST_KEY yet"
fi
store_get "$APPCAST_KEY" "$WORK/prev.appcast.xml" || rm -f "$WORK/prev.appcast.xml"
[ "$BUILD" -gt "$PREV_BUILD" ] ||
  refuse "build $BUILD is not higher than $PREV_BUILD; a published version is never rebuilt (ship a higher version, or --resume)"

# --- P3, P4: the DMG under its own key (unreferenced, so it may be overwritten), then verified. ------------------
step "Upload $KEY"
META="$(jq -cn --arg sha256 "$(jq -r .sha256 "$RELEASE")" --arg version "$VERSION" --arg build "$BUILD" \
  --arg edsignature "$(jq -r .edSignature "$RELEASE")" '{sha256: $sha256, version: $version, build: $build, edsignature: $edsignature}')"
store_put "$DMG" "$KEY" application/x-apple-diskimage "$META" || fail "the upload of $KEY failed (nothing public changed)"
step "Verify $KEY"
verify_stored_dmg "$KEY" "$RELEASE"

# --- P5, P6: the page pointer, then the public check (put back on failure). -------------------------------------
step "Write $LATEST_KEY"
store_put "$RELEASE" "$LATEST_KEY" application/json ||
  { restore_pointer "$LATEST_KEY" "$WORK/prev.latest.json" application/json; fail "could not write $LATEST_KEY"; }
if [ "$DEST" = s3 ]; then
  step "Public check of the page"
  if ! why="$(public_page_ok "$RELEASE")"; then
    echo "error: public check of the page failed: $why" >&2
    restore_pointer "$LATEST_KEY" "$WORK/prev.latest.json" application/json
    if [ -f "$WORK/prev.latest.json" ]; then
      if curl --retry 3 -fsS "$BASE_URL/transcribe/latest.json" -o "$WORK/public.json" &&
        cmp -s "$WORK/public.json" "$WORK/prev.latest.json"; then
        echo "    the public latest.json is the previous one again" >&2
      else
        echo "warning: the public latest.json is not the previous one yet" >&2
      fi
    fi
    exit 1
  fi
  echo "$why"
fi

# --- P7, P8. -----------------------------------------------------------------------------------------------------
write_feed
clean_up "$KEY"
step "Done: $VERSION (build $BUILD) is published"
