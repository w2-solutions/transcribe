#!/bin/bash
# Decides what mac-release.yml does, by comparing the TranscribeMac version in project.yml with what is published
# (/transcribe/latest.json and /transcribe/appcast.xml on the site). Later jobs read only these outputs, never the
# workflow inputs. Runs on Linux or macOS (bash, curl, jq, python3).
#
# Inputs (environment):
#   BASE_URL           the site (default https://w2solutions.ai)
#   PROJECT            project.yml (default the repo's)
#   NOTES_DIR          release notes folder (default <repo>/release-notes/mac)
#   GITHUB_EVENT_NAME  push or workflow_dispatch
#   GITHUB_REF         for example refs/heads/main
#   INPUT_PUBLISH      dispatch input "publish" (true/false)
#   INPUT_NOTARIZE     dispatch input "notarize" (true/false)
#   RUNNER_LABEL       the self-hosted runner's label (vars.TESTFLIGHT_RUNNER)
# Outputs (to $GITHUB_OUTPUT, or standard output): mode (none, dry-run, release, resume), version, build, notarize.
# A one-line reason goes to $GITHUB_STEP_SUMMARY (or standard error).
#
#   push      B > P                                         release
#   push      B = P, and no latest.json or feed build = P    none
#   push      B = P, latest.json present, feed build < P     resume
#   dispatch  publish=false (any ref), B > 200               dry-run
#   dispatch  publish=true on main with notarize             release (B > P), resume (B = P with latest.json),
#                                                            none (B = P, no latest.json)
#   B is this build, P the published build (200, 0.2.0's, when there is no latest.json). Everything else fails.
# Exit: 0 decided; 1 refused or failed.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${BASE_URL:-https://w2solutions.ai}"
BASE_URL="${BASE_URL%/}"
PROJECT="${PROJECT:-$ROOT/project.yml}"
NOTES_DIR="${NOTES_DIR:-$ROOT/release-notes/mac}"
EVENT="${GITHUB_EVENT_NAME:-}"
REF="${GITHUB_REF:-}"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/release-gate.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

summary() {
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >>"$GITHUB_STEP_SUMMARY"; else echo "$*" >&2; fi
}
fail() {
  echo "::error::$*"
  summary "Mac release: refused. $*"
  exit 1
}
output() {
  if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; else echo "$1=$2"; fi
}

# This version and build (release-mac.sh's rule), never a TEST override.
read -r V B < <(env -u TRANSCRIBE_ED_PUBLIC_KEY -u TRANSCRIBE_FEED_URL -u TRANSCRIBE_TEST_VERSION \
  PROJECT="$PROJECT" "$ROOT/scripts/release-mac.sh" --print-version) || fail "could not read the Mac version from $PROJECT"
[ -n "${B:-}" ] || fail "could not read the Mac version from $PROJECT"
PUBKEY="$(awk '/^  [^ #]/ { mac = ($0 ~ /^  TranscribeMac:/) }
  mac && $1 == "TRANSCRIBE_ED_PUBLIC_KEY:" { v = $2; gsub(/"/, "", v); print v; exit }' "$PROJECT")"

# fetch PATH OUT: prints "<http code> <content type>".
fetch() {
  curl --retry 3 -sS -o "$2" -w '%{http_code} %{content_type}\n' "$BASE_URL$1" || echo "000 none"
}

# The published release. Anything but 404 or a valid JSON release (the old Worker answered HTML) stops here.
LATEST=0
P=200
read -r CODE TYPE < <(fetch /transcribe/latest.json "$WORK/latest.json")
case "$CODE ${TYPE:-}" in
  404*) ;;
  "200 application/json"*)
    jq -e '
      (.schema == 1)
      and (.version | type == "string" and test("^[0-9]{1,4}\\.[0-9]{1,4}\\.[0-9]{1,4}$"))
      and (.file == "Transcribe-" + .version + ".dmg") and (.key == "transcribe/" + .file)
      and (.bytes | type == "number" and . > 0 and . == floor and . <= 9007199254740991)
      and (.sha256 | type == "string" and test("^[0-9a-f]{64}$"))
      and (.build | type == "number" and . > 0 and . == floor)
      and ((.version | split(".") | map(tonumber)) as [$a, $b, $c] | $b < 100 and $c < 100 and .build == $a * 10000 + $b * 100 + $c)
      and (.edSignature | type == "string" and test("^[A-Za-z0-9+/]{86}==$"))
    ' "$WORK/latest.json" >/dev/null 2>&1 || fail "$BASE_URL/transcribe/latest.json is not a valid release"
    LATEST=1
    P="$(jq -r .build "$WORK/latest.json")"
    ;;
  *) fail "$BASE_URL/transcribe/latest.json answered $CODE ${TYPE:-} (expected 404 or JSON; is the new site Worker live?)" ;;
esac

# The published feed's build (0 when there is none), read from the content before the signature block.
A=0
read -r CODE TYPE < <(fetch /transcribe/appcast.xml "$WORK/appcast.xml")
case "$CODE ${TYPE:-}" in
  404*) ;;
  "200 application/xml"*)
    A="$(python3 -I - "$WORK/appcast.xml" <<'EOF'
import sys, xml.etree.ElementTree as ET
data = open(sys.argv[1], "rb").read()
cut = data.rfind(b"<!-- sparkle-signatures:\n")
root = ET.fromstring(data if cut < 0 else data[:cut])
ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
builds = [int(e.text.strip()) for e in root.iter(ns + "version")]
print(max(builds) if builds else 0)
EOF
)" || fail "$BASE_URL/transcribe/appcast.xml is not a readable feed"
    ;;
  *) fail "$BASE_URL/transcribe/appcast.xml answered $CODE ${TYPE:-} (expected 404 or XML)" ;;
esac

MODE=""
REASON=""
NOTARIZE=true
case "$EVENT" in
  push)
    if [ "$B" -gt "$P" ]; then
      MODE=release REASON="push: $V ($B) is newer than the published build $P"
    elif [ "$B" -eq "$P" ] && { [ "$LATEST" = 0 ] || [ "$A" -eq "$P" ]; }; then
      MODE=none REASON="push: $V ($B) is already published, nothing to do"
    elif [ "$B" -eq "$P" ] && [ "$A" -lt "$P" ]; then
      MODE=resume REASON="push: the page has $V ($B) but the feed has build $A; resuming"
    elif [ "$B" -eq "$P" ]; then
      fail "the feed's build $A is ahead of the page's $P; repair the bucket by hand"
    else
      fail "project.yml's $V ($B) is behind the published build $P"
    fi
    ;;
  workflow_dispatch)
    [ "${INPUT_NOTARIZE:-true}" = false ] && NOTARIZE=false
    if [ "${INPUT_PUBLISH:-false}" != true ]; then
      MODE=dry-run REASON="dry run of $V ($B) with a throwaway key; nothing is uploaded"
      # The dry run's own publish step refuses anything at or below 0.2.0's build, so stop before a 2-hour build.
      if [ "$B" -le 200 ]; then
        fail "a dry run needs a TranscribeMac version above 0.2.0 (build 200), with release-notes/mac/<version>.txt: dispatch it from a branch with the version bumped (gh workflow run mac-release.yml --ref <branch> -f publish=false)"
      fi
      if [ "$B" -le "$P" ]; then
        echo "::warning::$V ($B) is not newer than the published build $P; the dry run goes ahead, but publishing this version would be refused"
        summary "Warning: $V ($B) is not newer than the published build $P; the dry run goes ahead, but publishing it would be refused."
      fi
    else
      [ "$REF" = refs/heads/main ] || fail "publishing runs only from main (this run is on $REF)"
      [ "$NOTARIZE" = true ] || fail "a published release is always notarised (notarize=false is for dry runs)"
      if [ "$B" -gt "$P" ]; then
        MODE=release REASON="dispatch: $V ($B) is newer than the published build $P"
      elif [ "$B" -eq "$P" ] && [ "$LATEST" = 1 ]; then
        MODE=resume REASON="dispatch: $V ($B) is published; repairing the feed and cleaning up"
      elif [ "$B" -eq "$P" ]; then
        MODE=none REASON="dispatch: nothing is published and $V ($B) is 0.2.0's build; nothing to do"
      else
        fail "project.yml's $V ($B) is behind the published build $P"
      fi
    fi
    ;;
  *) fail "unexpected event '$EVENT'" ;;
esac

if [ "$MODE" != none ]; then
  [ -n "${RUNNER_LABEL:-}" ] || fail "the repo variable TESTFLIGHT_RUNNER (the self-hosted Mac's label) is not set"
  [ -f "$NOTES_DIR/$V.txt" ] || fail "no release notes for $V: add release-notes/mac/$V.txt"
  # The same rule as sign-mac-release.sh, so empty notes fail here and not after the build.
  grep -q '[^[:space:]]' "$NOTES_DIR/$V.txt" || fail "the release notes for $V are empty: release-notes/mac/$V.txt"
  if [ "$MODE" != dry-run ] && [ -z "$PUBKEY" ]; then
    fail "TRANSCRIBE_ED_PUBLIC_KEY in project.yml is empty (owner checklist: create the update key)"
  fi
elif [ -z "$PUBKEY" ]; then
  summary "Warning: TRANSCRIBE_ED_PUBLIC_KEY in project.yml is empty, so no release can be published yet."
fi

output mode "$MODE"
output version "$V"
output build "$B"
output notarize "$NOTARIZE"
summary "Mac release: $MODE. $REASON (published: build $P, feed build $A)."
