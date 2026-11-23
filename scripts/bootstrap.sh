#!/usr/bin/env bash
# Generates the Xcode project, seeds the NeMo binary artifact cache (xcodebuild can hang downloading it),
# and pre-boots the shared iPhone 15 (iOS 27.0) simulator.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodegen generate

CACHE="$HOME/Library/Caches/org.swift.swiftpm/artifacts/https___github_com_FluidInference_text_processing_rs_releases_download_v0_3_4_NemoTextProcessing_xcframework_zip"
URL="https://github.com/FluidInference/text-processing-rs/releases/download/v0.3.4/NemoTextProcessing.xcframework.zip"
if [ ! -e "$CACHE" ]; then
  echo "Seeding the NemoTextProcessing artifact cache…"
  # The checksum comes from FluidAudio's manifest (resolve the package first if it is missing).
  MANIFEST=$(find "$HOME/Library/Caches/org.swift.swiftpm" TranscribeKit/.build -path '*FluidAudio*' -name 'Package*.swift' 2>/dev/null | head -1 || true)
  SUM=""
  if [ -n "$MANIFEST" ]; then
    SUM=$(grep -A3 'NemoTextProcessing.xcframework.zip' "$MANIFEST" | grep -o 'checksum: *"[0-9a-f]*"' | grep -o '[0-9a-f]\{64\}' | head -1 || true)
  fi
  TMP=$(mktemp -d)
  curl -fL "$URL" -o "$TMP/NemoTextProcessing.xcframework.zip"
  if [ -n "$SUM" ]; then
    echo "$SUM  $TMP/NemoTextProcessing.xcframework.zip" | shasum -a 256 -c -
  else
    echo "warning: could not find the manifest checksum; skipping verification" >&2
  fi
  mkdir -p "$(dirname "$CACHE")"
  cp "$TMP/NemoTextProcessing.xcframework.zip" "$CACHE"
  rm -rf "$TMP"
fi

UDID="${SIM_UDID:-2BF544DF-B739-4ABD-9457-0C61D9C13E1A}"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || true
echo "bootstrap done"
