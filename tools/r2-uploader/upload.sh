#!/bin/bash
# upload.sh <file> <key> <base url> <token file>: multipart upload in 50 MiB parts through the temporary Worker
# in this folder (worker.js). Refuses a key that already exists. Prints the stored size and etag at the end.
set -euo pipefail
FILE="$1"; KEY="$2"; BASE="$3"; TOKEN="$(cat "$4")"
DIR="$(cd "$(dirname "$0")" && pwd)"
PART=$((50 * 1024 * 1024))
SIZE=$(stat -f %z "$FILE")
COUNT=$(( (SIZE + PART - 1) / PART ))
H=(-H "x-token: $TOKEN")
R=(--retry 5 --retry-all-errors --retry-delay 4 --max-time 600)
existing=$(curl -sS "${R[@]}" "${H[@]}" "$BASE/head?key=$KEY")
if [ "$existing" != "null" ]; then echo "key already exists or worker not ready: $existing" >&2; exit 3; fi
ID=$(curl -sS "${R[@]}" "${H[@]}" "$BASE/create?key=$KEY" | python3 -c 'import sys,json; print(json.load(sys.stdin)["uploadId"])')
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
