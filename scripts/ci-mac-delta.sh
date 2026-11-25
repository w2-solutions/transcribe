#!/bin/bash
# mac-release.yml's delta step: fetches the published release through the site (fetch-published-mac.sh) and makes
# the delta from it to the new DMG (make-mac-delta.sh), in dist/. A delta is an optimisation, so this never fails the
# release: when either step fails it removes any delta, warns (an ::warning:: and the step summary) and exits 0, and
# the release goes out without one (every copy downloads the whole DMG, as before 0.3.2).
#
#   ci-mac-delta.sh <new.dmg> <work-dir> <derived-data>
#
# Exit: 0 (with or without a delta); 2 usage.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -eq 3 ] || { sed -n '2,8s/^# \{0,1\}//p' "$0" >&2; exit 2; }
NEW="$1"
PREV="$2"
DD="$3"

warn() {
  rm -f "$ROOT"/dist/*.delta
  echo "::warning::No delta update in this release: $*. Every copy downloads the whole DMG."
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "Mac release: no delta update ($*)." >>"$GITHUB_STEP_SUMMARY"
  exit 0
}

rm -rf "$PREV"
rm -f "$ROOT"/dist/*.delta
"$ROOT/scripts/fetch-published-mac.sh" "$PREV" || warn "could not fetch the published release"
set -- "$PREV"/Transcribe-*.dmg
if [ ! -f "$1" ]; then
  echo "nothing is published: no delta"
  exit 0
fi
OLD="$1"
DERIVED="$DD" "$ROOT/scripts/make-mac-delta.sh" "$OLD" "$NEW" "$ROOT/dist" || warn "make-mac-delta.sh failed"
rm -rf "$PREV"
for d in "$ROOT"/dist/*.delta; do
  [ -f "$d" ] || continue
  [ -z "${GITHUB_STEP_SUMMARY:-}" ] || echo "Mac release: delta update $(basename "$d"), $(stat -f %z "$d") bytes." >>"$GITHUB_STEP_SUMMARY"
done
exit 0
