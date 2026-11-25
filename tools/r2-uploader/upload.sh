#!/bin/bash
# upload.sh <file> <key> <base url> <token file> <latest.json>: multipart upload in 50 MiB parts through the temporary
# Worker in this folder (worker.js). <latest.json> is the release's (dist/Transcribe-<v>.latest.json): the file must
# have its size and sha256 and the key must be its key, and the DMG gets the same metadata as publish-mac.sh writes
# (sha256, version, build, edsignature), which a later resume needs. Refuses a key that already exists. Prints the
# stored size, etag and metadata at the end.
set -euo pipefail
[ $# -eq 5 ] || { sed -n '2,6s/^# \{0,1\}//p' "$0" >&2; exit 2; }
FILE="$1"; KEY="$2"; BASE="$3"; TOKEN="$(cat "$4")"; RELEASE="$5"
DIR="$(cd "$(dirname "$0")" && pwd)"
PART=$((50 * 1024 * 1024))
SIZE=$(stat -f %z "$FILE")
[ "$KEY" = "$(jq -r .key "$RELEASE")" ] || { echo "$KEY is not the key in $RELEASE" >&2; exit 2; }
[ "$SIZE" = "$(jq -r .bytes "$RELEASE")" ] || { echo "$FILE is not the size in $RELEASE" >&2; exit 2; }
SHA="$(shasum -a 256 "$FILE" | cut -d ' ' -f 1)"
[ "$SHA" = "$(jq -r .sha256 "$RELEASE")" ] || { echo "$FILE does not have the sha256 in $RELEASE" >&2; exit 2; }
COUNT=$(( (SIZE + PART - 1) / PART ))
H=(-H "x-token: $TOKEN")
R=(--retry 5 --retry-all-errors --retry-delay 4 --max-time 600)
existing=$(curl -sS "${R[@]}" "${H[@]}" "$BASE/head?key=$KEY")
if [ "$existing" != "null" ]; then echo "key already exists or worker not ready: $existing" >&2; exit 3; fi
# The signature holds + / and =: send every value URL-encoded.
ID=$(curl -sS --fail-with-body "${R[@]}" "${H[@]}" -G "$BASE/create" --data-urlencode "key=$KEY" \
  --data-urlencode "sha256=$SHA" --data-urlencode "version=$(jq -r .version "$RELEASE")" \
  --data-urlencode "build=$(jq -r .build "$RELEASE")" --data-urlencode "edsignature=$(jq -r .edSignature "$RELEASE")" |
  python3 -c 'import sys,json; print(json.load(sys.stdin)["uploadId"])')
echo "upload started; $COUNT parts"
PARTS="["
for n in $(seq 1 "$COUNT"); do
  dd if="$FILE" of="$DIR/part.bin" bs=$PART skip=$((n - 1)) count=1 2>/dev/null
  out=$(curl -sS --fail-with-body "${R[@]}" "${H[@]}" -X PUT -H "content-type: application/octet-stream" \
    --data-binary @"$DIR/part.bin" "$BASE/part?key=$KEY&uploadId=$ID&n=$n") || {
      echo "part $n failed: $out" >&2; curl -sS "${H[@]}" "$BASE/abort?key=$KEY&uploadId=$ID"; rm -f "$DIR/part.bin"; exit 1; }
  echo "part $n/$COUNT ok"
  PARTS="$PARTS$out,"
done
rm -f "$DIR/part.bin"
PARTS="${PARTS%,}]"
curl -sS --fail-with-body "${R[@]}" "${H[@]}" -X POST -H "content-type: application/json" --data "$PARTS" "$BASE/complete?key=$KEY&uploadId=$ID"
echo
curl -sS "${R[@]}" "${H[@]}" "$BASE/head?key=$KEY"; echo
