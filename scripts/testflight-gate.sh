#!/bin/bash
# Decides whether testflight.yml uploads: on a push to main only when the iPhone app's version (the Transcribe
# target's MARKETING_VERSION in project.yml) changed since the commit before the push; always when run by hand.
# Runs on Linux or macOS (bash, git, awk).
#
# Inputs (environment): GITHUB_EVENT_NAME (push or workflow_dispatch), BEFORE (github.event.before on a push),
#   PROJECT (default project.yml; the earlier copy is read with git show BEFORE:project.yml).
# Outputs (to $GITHUB_OUTPUT, or standard output): upload (true or false), version. A one-line reason goes to
# $GITHUB_STEP_SUMMARY (or standard error).
# Exit: 0 decided; 1 failed.
set -euo pipefail

PROJECT="${PROJECT:-project.yml}"
EVENT="${GITHUB_EVENT_NAME:-}"
BEFORE="${BEFORE:-}"

summary() { if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then echo "$*" >>"$GITHUB_STEP_SUMMARY"; else echo "$*" >&2; fi; }
output() { if [ -n "${GITHUB_OUTPUT:-}" ]; then echo "$1=$2" >>"$GITHUB_OUTPUT"; else echo "$1=$2"; fi; }

# iphone_version: the Transcribe (iPhone) target's MARKETING_VERSION from project.yml on standard input.
iphone_version() {
  awk '/^  [^ #]/ { app = ($0 ~ /^  Transcribe:/) }
    app && $1 == "MARKETING_VERSION:" { v = $2; gsub(/"/, "", v); print v; exit }'
}

NOW="$(iphone_version <"$PROJECT")"
[ -n "$NOW" ] || { echo "::error::no MARKETING_VERSION for the Transcribe target in $PROJECT"; exit 1; }
output version "$NOW"

case "$EVENT" in
  workflow_dispatch)
    output upload true
    summary "TestFlight: upload $NOW (run by hand)."
    ;;
  push)
    if [ -z "$BEFORE" ] || [ -z "${BEFORE//0/}" ] || ! git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
      output upload true
      summary "TestFlight: upload $NOW (no earlier commit to compare with)."
    else
      THEN="$(git show "$BEFORE:$PROJECT" 2>/dev/null | iphone_version || true)"
      if [ "$THEN" != "$NOW" ]; then
        output upload true
        summary "TestFlight: upload $NOW (the iPhone version was ${THEN:-unset})."
      else
        output upload false
        summary "TestFlight: no upload; the iPhone version is still $NOW (bump the Transcribe MARKETING_VERSION, or run the workflow by hand)."
      fi
    fi
    ;;
  *)
    echo "::error::unexpected event '$EVENT'"
    exit 1
    ;;
esac
