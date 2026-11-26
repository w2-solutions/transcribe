#!/bin/bash
# Builds the Mac DMG with its styled Finder window: the app and an Applications link on a background picture,
# laid out by a .DS_Store that scripts/dmg-dsstore.py writes (no Finder scripting, so it runs on the CI runner).
# It does not sign: release-mac.sh signs, notarises and staples the result.
#
#   make-dmg.sh <app> <out.dmg> [--volname NAME] [--art DIR]
#
#   <app>      the .app to ship; it keeps its name at the root of the DMG (Transcribe.app for a release)
#   --volname  the volume name (default Transcribe)
#   --art      the folder with background.png (660x400) and background@2x.png (1320x800); default Apps/Mac/DMG
#
# The layout (what the background art is drawn for): a window whose content area is 660 x 400 points, icon view,
# icons 128, text 13, labels below; the app's icon centred at (165, 185) and Applications at (495, 185), in points
# from the top left of the content area; no toolbar, sidebar, status, path or tab bar. The two PNGs become one HiDPI
# TIFF, .background/background.tiff. When the app has an icon (CFBundleIconFile), it is also the volume's icon.
#
# How: copy everything into a read-write image, mount it (hidden from Finder), write .DS_Store there, then convert
# to a compressed read-only UDZO image and check the result. .DS_Store points at the background twice, as Finder
# does: a bookmark (pBBk, found by the volume's UUID) and an alias (in icvp, found by the volume's name). Both need
# the volume to exist, and both are fixed in the image, so they resolve on any Mac. Finder uses the bookmark first:
# without it, a second Transcribe DMG mounted while another is open shows the other one's picture (seen 2026-11-26).
# Finder draws icon labels in dark text with no backing over any background picture, in light and dark mode alike.
# Exit: 0 written; 1 failed (nothing written at <out.dmg>); 2 usage.
# Runs on macOS /bin/bash 3.2; needs hdiutil, tiffutil, sips, ditto, xattr, xcrun swift and python3 (standard
# library only). No Finder scripting, no network.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SELF="$ROOT/scripts/$(basename "$0")"

# The layout contract (keep in step with the background art and CLAUDE.md).
WINDOW=660,400
# Finder's WindowBounds is the whole window, title bar included: 32 points on macOS 27 with the toolbar hidden
# (measured 2026-11-26), so the window is 432 high for 400 points of content.
TITLE_BAR=32
ORIGIN=240,320 # where the window opens, from the bottom left of the main screen (Finder keeps it on screen)
ICON_SIZE=128
TEXT_SIZE=13
APP_AT=165,185
APPLICATIONS_AT=495,185

usage() {
  sed -n '2,25s/^# \{0,1\}//p' "$SELF" >&2
  exit 2
}
fail() {
  echo "error: $*" >&2
  exit 1
}

[ $# -ge 2 ] || usage
APP="${1%/}"
OUT="$2"
shift 2
VOLNAME=Transcribe
ART="$ROOT/Apps/Mac/DMG"
while [ $# -gt 0 ]; do
  case "$1" in
    --volname) [ $# -ge 2 ] || usage; VOLNAME="$2"; shift ;;
    --art) [ $# -ge 2 ] || usage; ART="$2"; shift ;;
    -h | --help) usage ;;
    *) echo "error: unknown argument: $1" >&2; usage ;;
  esac
  shift
done

case "$APP" in *.app) ;; *) fail "$APP is not a .app" ;; esac
[ -d "$APP" ] || fail "no app at $APP"
case "$OUT" in *.dmg) ;; *) fail "$OUT does not end in .dmg" ;; esac
[ -d "$(dirname "$OUT")" ] || fail "no folder for $OUT"
[ -n "$VOLNAME" ] && [ "${#VOLNAME}" -le 27 ] || fail "the volume name must be 1 to 27 characters"
for f in background.png background@2x.png; do [ -f "$ART/$f" ] || fail "no $ART/$f"; done
for t in hdiutil tiffutil ditto xattr python3 sips xcrun; do command -v "$t" >/dev/null || fail "needs $t"; done

# The art must be exactly 660x400 and 1320x800 pixels, or Finder draws it at the wrong scale.
px() { sips -g pixelWidth -g pixelHeight "$1" | awk '/pixelWidth/ { w = $2 } /pixelHeight/ { h = $2 } END { print w "x" h }'; }
W="${WINDOW%,*}"
H="${WINDOW#*,}"
[ "$(px "$ART/background.png")" = "${W}x${H}" ] || fail "background.png is $(px "$ART/background.png"), not ${W}x${H}"
[ "$(px "$ART/background@2x.png")" = "$((W * 2))x$((H * 2))" ] ||
  fail "background@2x.png is $(px "$ART/background@2x.png"), not $((W * 2))x$((H * 2))"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/make-dmg.XXXXXX")"
MOUNT=""
cleanup() {
  if [ -n "$MOUNT" ]; then hdiutil detach -quiet "$MOUNT" >/dev/null 2>&1 || hdiutil detach -quiet -force "$MOUNT" >/dev/null 2>&1 || true; fi
  rm -rf "$WORK"
}
trap cleanup EXIT

APP_NAME="$(basename "$APP")"
STAGE="$WORK/stage"
mkdir -p "$STAGE/.background"
ditto "$APP" "$STAGE/$APP_NAME"
ln -s /Applications "$STAGE/Applications"
tiffutil -cathidpicheck "$ART/background.png" "$ART/background@2x.png" -out "$STAGE/.background/background.tiff" \
  >"$WORK/tiffutil.log" 2>&1 || { cat "$WORK/tiffutil.log" >&2; fail "tiffutil could not combine the background PNGs"; }
ICON_FILE="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null || true)"
if [ -n "$ICON_FILE" ]; then
  case "$ICON_FILE" in *.icns) ;; *) ICON_FILE="$ICON_FILE.icns" ;; esac
  [ ! -f "$APP/Contents/Resources/$ICON_FILE" ] || cp "$APP/Contents/Resources/$ICON_FILE" "$STAGE/.VolumeIcon.icns"
fi
# Room for .DS_Store, which can only be written once the volume exists (an image made from a folder has little
# free space); it is overwritten below.
head -c 32768 /dev/zero >"$STAGE/.DS_Store"

hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -format UDRW -ov "$WORK/rw.dmg"
mkdir "$WORK/mnt"
hdiutil attach -quiet -readwrite -nobrowse -noautoopen -noverify -mountpoint "$WORK/mnt" "$WORK/rw.dmg"
MOUNT="$WORK/mnt"

xcrun swift "$ROOT/scripts/dmg-bookmark.swift" create "$MOUNT/.background/background.tiff" "$WORK/bookmark"
python3 -I "$ROOT/scripts/dmg-dsstore.py" write "$MOUNT" --volname "$VOLNAME" --background .background/background.tiff \
  --bookmark "$WORK/bookmark" \
  --window "$WINDOW" --title-bar "$TITLE_BAR" --origin "$ORIGIN" --icon-size "$ICON_SIZE" --text-size "$TEXT_SIZE" \
  --item "$APP_NAME=$APP_AT" --item "Applications=$APPLICATIONS_AT" \
  --offscreen .background --offscreen .VolumeIcon.icns --offscreen .fseventsd
chflags hidden "$MOUNT/.background"
if [ -f "$MOUNT/.VolumeIcon.icns" ]; then
  chflags hidden "$MOUNT/.VolumeIcon.icns"
  # Finder info of the volume's root folder with kHasCustomIcon (0x0400) set: Finder then uses .VolumeIcon.icns.
  xattr -wx com.apple.FinderInfo 0000000000000000040000000000000000000000000000000000000000000000 "$MOUNT"
fi
rm -rf "$MOUNT/.fseventsd" 2>/dev/null || true
hdiutil detach -quiet "$MOUNT"
MOUNT=""

hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -ov -o "$WORK/out.dmg"

# Check the result as a user will see it.
mkdir "$WORK/check"
hdiutil attach -quiet -readonly -nobrowse -noautoopen -mountpoint "$WORK/check" "$WORK/out.dmg"
MOUNT="$WORK/check"
[ -d "$MOUNT/$APP_NAME" ] || fail "no $APP_NAME in the DMG"
[ "$(readlink "$MOUNT/Applications")" = /Applications ] || fail "no Applications link in the DMG"
[ -f "$MOUNT/.background/background.tiff" ] || fail "no background in the DMG"
python3 -I "$ROOT/scripts/dmg-dsstore.py" dump "$MOUNT/.DS_Store" >"$WORK/ds.json" || fail "the DMG's .DS_Store does not parse"
python3 -I - "$WORK/ds.json" "$MOUNT" "$VOLNAME" "$APP_NAME" "$WORK/bookmark-read" <<'EOF' ||
import json, os, sys
ds, mount, volname, app = json.load(open(sys.argv[1])), sys.argv[2], sys.argv[3], sys.argv[4]
alias = ds['.']['icvp']['backgroundImageAlias']
bg = os.stat(os.path.join(mount, '.background/background.tiff'))
assert alias['volname'] == volname and alias['file_id'] == bg.st_ino, alias
assert alias['voldate'] == int(os.stat(mount).st_birthtime) + 2082844800, alias
assert ds[app]['Iloc'] and ds['Applications']['Iloc']
open(sys.argv[5], 'wb').write(bytes.fromhex(ds['.']['pBBk']))
EOF
  fail "the DMG's .DS_Store does not match the volume"
GOT="$(xcrun swift "$ROOT/scripts/dmg-bookmark.swift" resolve "$WORK/bookmark-read")" || fail "the DMG's background bookmark does not resolve"
[ "$GOT" -ef "$MOUNT/.background/background.tiff" ] || fail "the DMG's background bookmark resolves to $GOT"
hdiutil detach -quiet "$MOUNT"
MOUNT=""

mv -f "$WORK/out.dmg" "$OUT"
echo "$OUT"
