#!/bin/bash
# Check stream ownership, timestamps, and producer trust without opening a camera.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/openopal-sink-checks.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

for name in Session Timing; do
  xcrun swiftc -swift-version 6 -parse-as-library \
    "$ROOT/Sources/OpenOpalCameraExtension/Sink$name.swift" \
    "$ROOT/Tests/CameraSink${name}Tests.swift" -o "$WORK/$name"
  "$WORK/$name"
done

HOST_ID="local.openopal.sink-fixture"
cat > "$WORK/host.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$HOST_ID</string>
<key>CFBundleExecutable</key><string>authorization</string>
</dict></plist>
PLIST
xcrun swiftc -swift-version 6 -parse-as-library \
  "$ROOT/Sources/OpenOpalCameraExtension/SinkClientAuthorizer.swift" \
  "$ROOT/Tests/CameraSinkAuthorizationTests.swift" \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker "$WORK/host.plist" \
  -o "$WORK/authorization"
codesign --force --sign - --identifier "$HOST_ID" "$WORK/authorization"
"$WORK/authorization" "$HOST_ID" TESTTEAM00 "$WORK/host.plist"
