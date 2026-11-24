#!/usr/bin/env bash
# Build -> bundle dependencies -> sign -> notarize -> staple -> install.
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
#
# CI notarizes with an App Store Connect API key instead: NOTARY_KEY (the path
# to the .p8), NOTARY_KEY_ID and NOTARY_ISSUER.
#
# RELEASE_VERSION and RELEASE_BUILD, when set, replace the version in the built app, its
# camera extension and its launcher. The release workflow sets both.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROFILE="${NOTARY_PROFILE:-openopal}"
DERIVED="build/DerivedData"
APP="$DERIVED/Build/Products/Release/OpenOpal.app"
ZIP="build/OpenOpal.zip"

echo "==> building (Release)"
# A fresh checkout has no build/ until the SDK is built, and CI restores the
# SDK from a cache.
mkdir -p build
xcodegen generate >/dev/null
xcodebuild -project OpenOpal.xcodeproj -scheme OpenOpal \
  -configuration Release -derivedDataPath "$DERIVED" build \
  > build/xcodebuild.log 2>&1 || { tail -25 build/xcodebuild.log; exit 1; }

if [ -n "${RELEASE_VERSION:-}" ]; then
  echo "==> stamping version $RELEASE_VERSION (${RELEASE_BUILD:?})"
  # All three get the same numbers. This runs before signing, which seals them.
  for PLIST in \
    "$APP/Contents/Info.plist" \
    "$APP/Contents/Library/SystemExtensions/sh.alistair.open-opal.camera.systemextension/Contents/Info.plist" \
    "$APP/Contents/Library/LoginItems/OpenOpalLauncher.app/Contents/Info.plist"; do
    /usr/libexec/PlistBuddy \
      -c "Set :CFBundleShortVersionString $RELEASE_VERSION" \
      -c "Set :CFBundleVersion $RELEASE_BUILD" "$PLIST"
  done
fi

echo "==> bundling runtime dependencies"
python3 ./scripts/bundle-dependencies.py "$APP"

echo "==> signing"
./scripts/sign.sh "$APP" >/dev/null

# The extension only trusts the app whose Info.plist was sealed into it, and
# macOS only replaces an installed extension when its version or build differs.
# So changing the Info.plist without raising CFBundleVersion leaves an extension
# that refuses the app, and other apps get the camera-off card.
if [ -z "${CI:-}" ]; then
  NEW="$APP/Contents/Library/SystemExtensions/sh.alistair.open-opal.camera.systemextension/Contents"
  plist_version() {
    /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleVersion' "$1" | tr '\n' ' '
  }
  for OLD in /Library/SystemExtensions/*/sh.alistair.open-opal.camera.systemextension/Contents; do
    [ -f "$OLD/Info.plist" ] || continue
    if [ "$(plist_version "$OLD/Info.plist")" = "$(plist_version "$NEW/Info.plist")" ] &&
       ! cmp -s "$OLD/Resources/OpenOpalHostInfo.plist" "$NEW/Resources/OpenOpalHostInfo.plist"; then
      echo "error: the app's Info.plist changed but its build number did not." >&2
      echo "Raise CFBundleVersion in project.yml (all three), or the installed" >&2
      echo "camera extension will refuse this build." >&2
      exit 1
    fi
  done
fi

echo "==> zipping for notarization"
rm -f "$ZIP"
# ditto (not zip) — it preserves the bundle's symlinks and extended attributes,
# which the signature depends on.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> submitting to Apple (this usually takes 1-5 minutes)"
if [ -n "${NOTARY_KEY:-}" ]; then
  # CI path: credentials come from the environment, not a stored profile.
  xcrun notarytool submit "$ZIP" \
    --key "$NOTARY_KEY" --key-id "${NOTARY_KEY_ID:?}" \
    --issuer "${NOTARY_ISSUER:?}" --wait
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
echo "Launch it, float the panel, then: Camera -> Virtual camera -> Install."
