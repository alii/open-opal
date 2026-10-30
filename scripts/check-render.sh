#!/bin/bash
# Production renderer checks without app launch, USB, or CMIO connections.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/openopal-render-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

xcrun -sdk macosx metal -mmacosx-version-min=14.0 -c \
    "$ROOT/Sources/OpenOpal/Render/Bokeh.metal" -o "$WORK/Bokeh.air"
xcrun -sdk macosx metallib "$WORK/Bokeh.air" -o "$WORK/default.metallib"
xcrun swiftc -swift-version 6 -target arm64-apple-macosx14.0 -parse-as-library \
    "$ROOT/Sources/OpenOpal/Render/BokehRenderer.swift" \
    "$ROOT/Sources/OpenOpal/Render/DepthProvider.swift" \
    "$ROOT/Sources/OpenOpal/Render/MatteProvider.swift" \
    "$ROOT/Sources/OpenOpal/Camera/CameraSettings.swift" \
    "$ROOT/tools/render_checks.swift" \
    -o "$WORK/render-checks"
"$WORK/render-checks"
