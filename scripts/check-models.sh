#!/bin/bash
# Checks a BundledModels folder against scripts/models.lock. Runs as the Transcribe target's pre-build phase.
#
#   ./scripts/check-models.sh              <repo>/BundledModels; mode from Xcode's environment (below)
#   ./scripts/check-models.sh --hash       also compare sha256 (= make check-models)
#   ./scripts/check-models.sh --app PATH   PATH/BundledModels inside a built Transcribe.app; always strict
#
# Modes (without --app):
#   PLATFORM_NAME=iphonesimulator                 skip silently (simulator builds leave the models out)
#   CONFIGURATION=Release or ACTION=install       strict: any problem is an error and fails the build;
#                                                 sha256 is always checked (archives set ACTION=install)
#   anything else (Debug device builds, by hand)  a problem is only a warning
#
# Problems: a lock file missing, of the wrong size or (when hashing) the wrong sha256; a symlink; or a file the
# lock does not list. Allowed extras are the top-level README.md and any .DS_Store (Xcode strips those).
# Runs on macOS /bin/bash 3.2.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/scripts/models.lock"

usage() {
  echo "usage: $0 [--app PATH] [--hash]" >&2
  exit 2
}

APP=""
HASH=0
while [ $# -gt 0 ]; do
  case "$1" in
    --app)
      [ $# -ge 2 ] || usage
      APP="$2"
      shift 2
      ;;
    --hash)
      HASH=1
      shift
      ;;
    *) usage ;;
  esac
done

STRICT=0
if [ -n "$APP" ]; then
  DIR="$APP/BundledModels"
  STRICT=1
else
  DIR="$ROOT/BundledModels"
  [ "${PLATFORM_NAME:-}" != iphonesimulator ] || exit 0
  if [ "${CONFIGURATION:-}" = Release ] || [ "${ACTION:-}" = install ]; then
    STRICT=1
  fi
fi
[ "$STRICT" = 0 ] || HASH=1

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-models.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PROBLEMS="$WORK/problems"
: >"$PROBLEMS"

problem() { echo "$*" >>"$PROBLEMS"; }

# finish: report and exit. Xcode shows lines starting "error:" / "warning:" as build issues.
finish() {
  local count first
  count="$(wc -l <"$PROBLEMS" | tr -d ' ')"
  [ "$count" != 0 ] || return 0
  first="$(head -n 1 "$PROBLEMS")"
  if [ "$count" -gt 1 ]; then
    first="$first (and $((count - 1)) more problem(s) in $DIR)"
  fi
  sed -n '1,20s/^/  /p' "$PROBLEMS" >&2
  if [ "$STRICT" = 1 ]; then
    echo "error: bundled models: $first — run ./scripts/fetch-models.sh" >&2
    exit 1
  fi
  echo "warning: bundled models: $first (device builds of the real engine need ./scripts/fetch-models.sh)" >&2
  exit 0
}

if [ ! -f "$LOCK" ]; then
  problem "scripts/models.lock is missing"
  finish
fi
if [ ! -d "$DIR" ]; then
  problem "$DIR does not exist"
  finish
fi

TAB="$(printf '\t')"
files=0
bytes=0
echo "README.md" >"$WORK/wanted"
while IFS="$TAB" read -r local_path _repo _rev _remote size sha <&3; do
  case "$local_path" in "" | "#"* | "@"*) continue ;; esac
  echo "$local_path" >>"$WORK/wanted"
  files=$((files + 1))
  bytes=$((bytes + size))
  path="$DIR/$local_path"
  if [ -L "$path" ]; then
    problem "$local_path is a symlink"
  elif [ ! -f "$path" ]; then
    problem "$local_path is missing"
  elif [ "$(stat -f %z "$path")" != "$size" ]; then
    problem "$local_path has the wrong size ($(stat -f %z "$path") bytes, lock says $size)"
  elif [ "$HASH" = 1 ] && [ "$(shasum -a 256 "$path" | cut -d ' ' -f 1)" != "$sha" ]; then
    problem "$local_path has the wrong sha256"
  fi
done 3<"$LOCK"

# Everything that is not a folder must be a lock file, the top-level README.md or a .DS_Store.
LC_ALL=C sort -u "$WORK/wanted" >"$WORK/wanted.sorted"
(cd "$DIR" && find . ! -type d ! -name .DS_Store | sed 's|^\./||' | LC_ALL=C sort) >"$WORK/present"
LC_ALL=C comm -23 "$WORK/present" "$WORK/wanted.sorted" | while IFS= read -r extra; do
  if [ -L "$DIR/$extra" ]; then
    problem "$extra is a symlink"
  else
    problem "unexpected file $extra (not in scripts/models.lock)"
  fi
done

finish
how="sizes"
[ "$HASH" = 0 ] || how="sizes and sha256"
echo "Bundled models OK ($files files, $((bytes / 1048576)) MB, $how checked) in $DIR"
