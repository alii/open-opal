#!/usr/bin/env bash
# Signs the app and its embedded camera extension with the Developer ID
# identity. Signing must proceed INSIDE-OUT: nested code first, the app last,
# or the outer signature seals a bundle whose contents then change.
set -euo pipefail

APP="${1:?usage: sign.sh /path/to/OpenOpal.app}"
IDENTITY="${IDENTITY:-Developer ID Application: Alistair Smith (RD994J874S)}"
EXT="$APP/Contents/Library/SystemExtensions/sh.alistair.open-opal.camera.systemextension"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "==> embedding provisioning profiles"
# Restricted entitlements (system-extension.install) are only honored when a
# provisioning profile in the bundle grants them. Developer ID signing alone
# isn't enough: AMFI rejects the launch outright (spawn error 163).
cp "$ROOT/Provisioning/OpenOpal.provisionprofile" "$APP/Contents/embedded.provisionprofile"
cp "$ROOT/Provisioning/OpenOpalCameraExtension.provisionprofile" "$EXT/Contents/embedded.provisionprofile"

echo "==> dylibs"
for LIB in "$APP"/Contents/Frameworks/*.dylib; do
  codesign --force --timestamp --options runtime --sign "$IDENTITY" "$LIB"
done

echo "==> camera extension"
codesign --force --timestamp --options runtime \
  --entitlements "$ROOT/Sources/OpenOpalCameraExtension/OpenOpalCameraExtension.entitlements" \
  --sign "$IDENTITY" "$EXT"

echo "==> app"
codesign --force --timestamp --options runtime \
  --entitlements "$ROOT/Sources/OpenOpal/OpenOpal.entitlements" \
  --sign "$IDENTITY" "$APP"

echo "==> verify"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -o "system-extension.install" || true
