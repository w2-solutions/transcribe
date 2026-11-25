#!/bin/bash
# Downloads the published Mac release through the site, as the base of the next release's delta update
# (make-mac-delta.sh). It trusts nothing the site says: the DMG must have latest.json's size and sha256, and its
# EdDSA signature must verify against project.yml's TRANSCRIBE_ED_PUBLIC_KEY.
#
#   fetch-published-mac.sh <out-dir>
#
# Writes <out-dir>/latest.json and <out-dir>/Transcribe-<version>.dmg. When nothing is published (latest.json
# answers 404) it writes nothing and exits 0.
# Environment: BASE_URL (default https://w2solutions.ai), PROJECT (tests only: the project.yml to read).
# Exit: 0 fetched (or nothing published); 1 failed (nothing left in <out-dir>); 2 usage.
# Runs on macOS /bin/bash 3.2; needs Xcode (xcrun swift), curl and jq.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "$0")"
ED="$ROOT/scripts/ed25519.swift"
BASE_URL="${BASE_URL:-https://w2solutions.ai}"
BASE_URL="${BASE_URL%/}"
PROJECT="${PROJECT:-$ROOT/project.yml}"

usage() {
  sed -n '2,12s/^# \{0,1\}//p' "$SELF" >&2
  exit 2
}
[ $# -eq 1 ] || usage
OUT="$1"
mkdir -p "$OUT"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/fetch-published.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
fail() {
  echo "error: $*" >&2
  rm -f "$OUT/latest.json" "$OUT"/Transcribe-*.dmg
  exit 1
}
step() { printf '==> %s\n' "$*"; }

PUBKEY="$(awk '/^  [^ #]/ { mac = ($0 ~ /^  TranscribeMac:/) }
  mac && $1 == "TRANSCRIBE_ED_PUBLIC_KEY:" { v = $2; gsub(/"/, "", v); print v; exit }' "$PROJECT")"
[ -n "$PUBKEY" ] || fail "TRANSCRIBE_ED_PUBLIC_KEY in project.yml is empty"

step "The published release ($BASE_URL/transcribe/latest.json)"
CODE="$(curl --retry 3 -sS -o "$WORK/latest.json" -w '%{http_code}' "$BASE_URL/transcribe/latest.json")" || CODE=000
case "$CODE" in
  404)
    echo "    nothing is published"
    exit 0
    ;;
  200) ;;
  *) fail "latest.json answered $CODE" ;;
esac
jq -e '
  (.schema == 1)
  and (.version | type == "string" and test("^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$"))
  and (.file == "Transcribe-" + .version + ".dmg") and (.key == "transcribe/" + .file)
  and (.bytes | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
  and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
  and (.edSignature | type == "string" and test("^[A-Za-z0-9+/]{86}==$"))
' "$WORK/latest.json" >/dev/null 2>&1 || fail "latest.json is not a valid release"
FILE="$(jq -r .file "$WORK/latest.json")"
echo "    $(jq -r '"\(.version) (build \(.build)), \(.bytes) bytes"' "$WORK/latest.json")"

step "Download $FILE"
curl --retry 3 -fsS -o "$WORK/$FILE" "$BASE_URL/transcribe/download/$FILE" || fail "could not download $FILE"
[ "$(stat -f %z "$WORK/$FILE")" = "$(jq -r .bytes "$WORK/latest.json")" ] || fail "$FILE is not the size in latest.json"
[ "$(shasum -a 256 "$WORK/$FILE" | cut -d ' ' -f 1)" = "$(jq -r .sha256 "$WORK/latest.json")" ] ||
  fail "$FILE does not have the sha256 in latest.json"
xcrun swift "$ED" verify "$PUBKEY" "$(jq -r .edSignature "$WORK/latest.json")" "$WORK/$FILE" </dev/null ||
  fail "$FILE does not verify against $PUBKEY"
mv "$WORK/$FILE" "$OUT/$FILE"
mv "$WORK/latest.json" "$OUT/latest.json"
step "Fetched $OUT/$FILE (size, sha256 and EdDSA signature checked)"
