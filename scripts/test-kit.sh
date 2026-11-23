#!/usr/bin/env bash
# Swift Testing for TranscribeKit on the macOS host (no simulator).
set -euo pipefail
cd "$(dirname "$0")/../TranscribeKit"
swift test --parallel "$@"
