#!/usr/bin/env bash
# Build -> sign -> notarize -> staple -> install.
#
# Notarization is NOT optional here. A CoreMediaIO system extension will only
# load if macOS can validate it, and outside the App Store the only paths are
# (a) SIP disabled + `systemextensionsctl developer on`, which recent macOS
# betas refuse while SIP is on, or (b) Developer ID + notarization. So (b).
#
# Without the notarization ticket, OSSystemExtensionManager rejects the
# extension and — misleadingly — reports "Extension not found in App bundle",
# even though the bundle is present and correctly formed.
#
# Requires a keychain profile created once with:
#   xcrun notarytool store-credentials openopal \
#     --apple-id <you@example.com> --team-id RD994J874S
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${NOTARY_PROFILE:-openopal}"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/OpenOpal.app"
ZIP="build/OpenOpal.zip"

echo "==> building (Release)"
xcodegen generate >/dev/null
xcodebuild -project OpenOpal.xcodeproj -scheme OpenOpal \
  -configuration Release -derivedDataPath "$DERIVED" build \
  > build/xcodebuild.log 2>&1 || { tail -25 build/xcodebuild.log; exit 1; }

echo "==> signing"
./scripts/sign.sh "$APP" >/dev/null

echo "==> zipping for notarization"
rm -f "$ZIP"
# ditto (not zip) — it preserves the bundle's symlinks and extended attributes,
# which the signature depends on.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> submitting to Apple (this usually takes 1-5 minutes)"
if [ -n "${NOTARY_APPLE_ID:-}" ]; then
  # CI path: credentials come from the environment, not a stored profile.
  xcrun notarytool submit "$ZIP" \
    --apple-id "$NOTARY_APPLE_ID" --team-id "$NOTARY_TEAM_ID" \
    --password "$NOTARY_PASSWORD" --wait
else
  xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait
fi

echo "==> stapling the ticket"
# Staple the APP ONLY. Stapling writes the ticket file INTO the target bundle —
# so stapling the nested extension mutates a bundle the app's signature has
# already sealed, and Gatekeeper then reports "a sealed resource is missing or
# invalid". The app's ticket covers its nested code; one staple is enough.
xcrun stapler staple "$APP"

echo "==> verifying Gatekeeper accepts it"
spctl -a -vvv -t exec "$APP"

if [ -n "${CI:-}" ]; then
  echo "done. Notarized app at: $APP"
  exit 0
fi

echo "==> installing to /Applications"
osascript -e 'quit app "OpenOpal"' 2>/dev/null || true
sleep 1
rm -rf /Applications/OpenOpal.app
cp -R "$APP" /Applications/

echo
echo "done. Open Opal is notarized and installed."
echo "Launch it, then: Advanced -> Virtual Camera -> Install virtual camera."
