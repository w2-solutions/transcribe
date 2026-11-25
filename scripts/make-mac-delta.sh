#!/bin/bash
# Makes a Sparkle delta update from the published release to the new one, so a copy on the published version
# downloads only what changed (a few MB) instead of the whole DMG (about 657 MB, nearly all of it the speech models,
# which are the same bytes in every version). Needs no key: sign-mac-release.sh --delta signs the result.
#
#   make-mac-delta.sh <old.dmg|old.app> <new.dmg|new.app> <out-dir>
#
# Writes <out-dir>/Transcribe-<old version>-<new version>.delta and prints its path. Before it does, it applies the
# delta to the old app with Sparkle's own BinaryDelta and checks that the result is the new app exactly (every path,
# mode, symlink and byte), and that its code signature verifies when the new app's does.
#
# Environment: BINARY_DELTA (Sparkle's BinaryDelta), else $DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/
# BinaryDelta (DERIVED as for release-mac.sh, default $TMPDIR/transcribe-release). It must come with Sparkle 2.10.1,
# the version inside the app (checked when the artefact's framework is beside it).
# The patch is format 4 (Sparkle 2.10.1 applies it), LZMA.
# Exit: 0 written; 1 failed (nothing written); 2 usage.
# Runs on macOS /bin/bash 3.2; needs hdiutil, codesign and python3.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "$0")"
SPARKLE_VERSION=2.10.1
DELTA_FORMAT=4

usage() {
  sed -n '2,17s/^# \{0,1\}//p' "$SELF" >&2
  exit 2
}
fail() {
  echo "error: $*" >&2
  exit 1
}
step() { printf '==> %s\n' "$*"; }

[ $# -eq 3 ] || usage
OLD="$1"
NEW="$2"
OUT_DIR="$3"
[ -e "$OLD" ] || fail "no such file: $OLD"
[ -e "$NEW" ] || fail "no such file: $NEW"
[ -d "$OUT_DIR" ] || fail "no such folder: $OUT_DIR"

DD="${DERIVED:-${TMPDIR:-/tmp}/transcribe-release}"
BD="${BINARY_DELTA:-$DD/SourcePackages/artifacts/sparkle/Sparkle/bin/BinaryDelta}"
[ -x "$BD" ] || fail "no BinaryDelta at $BD (build the Mac app first, or set BINARY_DELTA)"
FW_PLIST="$(dirname "$BD")/../Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Versions/B/Resources/Info.plist"
if [ -f "$FW_PLIST" ]; then
  got="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$FW_PLIST" 2>/dev/null || true)"
  [ "$got" = "$SPARKLE_VERSION" ] || fail "BinaryDelta comes with Sparkle $got, not $SPARKLE_VERSION"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-delta.XXXXXX")"
MOUNTS=()
cleanup() {
  local m
  for m in ${MOUNTS[@]+"${MOUNTS[@]}"}; do hdiutil detach -quiet "$m" >/dev/null 2>&1 || hdiutil detach -quiet -force "$m" >/dev/null 2>&1 || true; done
  rm -rf "$WORK"
}
trap cleanup EXIT

# app_of PATH NAME: the Transcribe.app in a DMG (attached read-only under $WORK/NAME) or the app itself.
app_of() {
  case "$1" in
    *.dmg)
      mkdir "$WORK/$2"
      hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$WORK/$2" "$1" >&2 || fail "could not attach $1"
      MOUNTS+=("$WORK/$2")
      [ -d "$WORK/$2/Transcribe.app" ] || fail "no Transcribe.app in $1"
      echo "$WORK/$2/Transcribe.app"
      ;;
    *.app) (cd "$1" && pwd -P) ;;
    *) fail "$1 is neither a .dmg nor a .app" ;;
  esac
}

# Not in a $(...): the mounts must be recorded in this shell for the clean-up.
app_of "$OLD" old >"$WORK/old-path"
app_of "$NEW" new >"$WORK/new-path"
OLD_APP="$(cat "$WORK/old-path")"
NEW_APP="$(cat "$WORK/new-path")"

pv() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }
OLD_V="$(pv "$OLD_APP" CFBundleShortVersionString)"
NEW_V="$(pv "$NEW_APP" CFBundleShortVersionString)"
OLD_B="$(pv "$OLD_APP" CFBundleVersion)"
NEW_B="$(pv "$NEW_APP" CFBundleVersion)"
VERSION_RE='^(0|[1-9][0-9]*)\.(0|[1-9][0-9]?)\.(0|[1-9][0-9]?)$'
printf '%s\n' "$OLD_V" | grep -Eq "$VERSION_RE" || fail "the old app's version '$OLD_V' is not valid"
printf '%s\n' "$NEW_V" | grep -Eq "$VERSION_RE" || fail "the new app's version '$NEW_V' is not valid"
printf '%s\n' "$OLD_B" | grep -Eq '^[1-9][0-9]*$' || fail "the old app's build '$OLD_B' is not a number"
printf '%s\n' "$NEW_B" | grep -Eq '^[1-9][0-9]*$' || fail "the new app's build '$NEW_B' is not a number"
[ "$OLD_B" -lt "$NEW_B" ] || fail "the old build $OLD_B is not lower than the new build $NEW_B"
[ "$(pv "$OLD_APP" CFBundleIdentifier)" = "$(pv "$NEW_APP" CFBundleIdentifier)" ] ||
  fail "the two apps have different bundle ids"
NAME="Transcribe-$OLD_V-$NEW_V.delta"

step "Delta $OLD_V ($OLD_B) → $NEW_V ($NEW_B)"
"$BD" create --version "$DELTA_FORMAT" "$OLD_APP" "$NEW_APP" "$WORK/$NAME" >"$WORK/create.log" 2>&1 ||
  { cat "$WORK/create.log" >&2; fail "BinaryDelta create failed"; }

# The patch must rebuild the new app exactly. BinaryDelta checks its own tree hashes; this checks every entry too.
step "Apply it to $OLD_V and compare with $NEW_V"
"$BD" apply "$OLD_APP" "$WORK/applied.app" "$WORK/$NAME" >"$WORK/apply.log" 2>&1 ||
  { cat "$WORK/apply.log" >&2; fail "BinaryDelta apply failed"; }
manifest() {
  python3 -I - "$1" <<'EOF'
import hashlib, os, stat, sys
root = sys.argv[1]
for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
    dirnames.sort()
    for name in sorted(dirnames + filenames):
        p = os.path.join(dirpath, name)
        rel = os.path.relpath(p, root)
        st = os.lstat(p)
        mode = oct(stat.S_IMODE(st.st_mode))
        if stat.S_ISLNK(st.st_mode):
            print("link", rel, os.readlink(p))
        elif stat.S_ISDIR(st.st_mode):
            print("dir", rel, mode)
        else:
            h = hashlib.sha256()
            with open(p, "rb") as f:
                for chunk in iter(lambda: f.read(1 << 20), b""):
                    h.update(chunk)
            print("file", rel, mode, st.st_size, h.hexdigest())
EOF
}
manifest "$NEW_APP" >"$WORK/new.manifest"
manifest "$WORK/applied.app" >"$WORK/applied.manifest"
if ! cmp -s "$WORK/new.manifest" "$WORK/applied.manifest"; then
  diff "$WORK/new.manifest" "$WORK/applied.manifest" | head -20 >&2
  fail "the patched app differs from $NEW_V"
fi
echo "    $(wc -l <"$WORK/new.manifest" | tr -d ' ') entries identical"
if codesign --verify --deep --strict "$NEW_APP" 2>/dev/null; then
  codesign --verify --deep --strict "$WORK/applied.app" || fail "the patched app's code signature does not verify"
  echo "    code signature verifies"
fi

mv "$WORK/$NAME" "$OUT_DIR/$NAME"
BYTES="$(stat -f %z "$OUT_DIR/$NAME")"
step "Wrote $OUT_DIR/$NAME ($BYTES bytes, $(awk -v b="$BYTES" 'BEGIN { printf "%.1f", b / 1e6 }') MB)"
echo "$OUT_DIR/$NAME"
