#!/bin/bash
# Check saved settings and the face exposure policy without opening a camera.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/openopal-settings-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/OpenOpal/Camera/CameraSettings.swift" \
  "$ROOT/Tests/CameraSettingsPersistenceTests.swift" -o "$WORK/settings"
"$WORK/settings"

xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/OpenOpal/Camera/FaceExposure.swift" \
  "$ROOT/Tests/FaceExposureTests.swift" -o "$WORK/face"
"$WORK/face"
