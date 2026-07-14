# Signing and the virtual camera

The app runs fine unsigned. The **virtual camera** does not: a CoreMediaIO system
extension only loads if macOS can validate it, and outside the App Store that
means Developer ID signing *and* notarization. (`systemextensionsctl developer
on` used to be a shortcut; recent macOS refuses it while SIP is enabled.)

If you're forking this, you need your own Apple Developer account. Everything
below is one-time setup.

## What Apple needs

1. **Developer ID Application certificate** — create at
   [developer.apple.com/account/resources/certificates](https://developer.apple.com/account/resources/certificates).
   Pick the **G2 Sub-CA** intermediate. You'll also need Apple's
   [DeveloperIDG2CA.cer](https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer)
   in your keychain, or the cert shows as untrusted and `security find-identity`
   lists nothing.

2. **An App Group** — e.g. `group.yourteam.yourapp`. This is not optional:
   CMIO rejects any extension whose Mach service name isn't prefixed by one of
   its App Groups.

3. **Two App IDs**, both with **App Groups** enabled, and the app's with
   **System Extension** enabled:
   - `your.bundle.id` (the app)
   - `your.bundle.id.camera` (the extension)

4. **Two Developer ID provisioning profiles**, one per App ID. Changing
   capabilities invalidates existing profiles — regenerate them.
   Drop them in `Provisioning/` as `OpenOpal.provisionprofile` and
   `OpenOpalCameraExtension.provisionprofile`.

5. **Notarization credentials**, stored once:
   ```sh
   xcrun notarytool store-credentials openopal \
     --apple-id you@example.com --team-id YOURTEAMID
   ```
   (Needs an app-specific password from appleid.apple.com.)

Then update the team ID, bundle IDs and App Group in `project.yml`, and run:

```sh
./scripts/release.sh     # build -> sign -> notarize -> staple -> /Applications
```

## Things that will waste your day

macOS reports most of these as **"Extension not found in App bundle"**,
regardless of the actual cause. It is almost never what it says.

| Symptom | Real cause |
|---|---|
| `extensionNotFound` (4) | The extension bundle must be **named after its bundle identifier** (`your.bundle.id.camera.systemextension`). Xcode's template does this via `PRODUCT_NAME = $(PRODUCT_BUNDLE_IDENTIFIER)`; other build systems don't. |
| `extensionNotFound` (4) | The app is missing `com.apple.application-identifier` / `com.apple.developer.team-identifier` entitlements. Xcode injects these from the provisioning profile; if you sign post-build, you must add them yourself. |
| `extensionNotFound` (4) | Extension `Info.plist` missing `CFBundlePackageType = SYSX`. |
| `validationFailed` (9), "extension category returned error" | `CMIOExtensionMachServiceName` must be prefixed by an **App Group**, not the team ID. |
| Launch fails, `launchd job spawn failed` (163) | The app carries the restricted `system-extension.install` entitlement without a provisioning profile that grants it. AMFI kills it. |
| "cannot allow apps outside /Applications" | The app must be in `/Applications`. Also delete stale copies elsewhere (DerivedData!) — LaunchServices may resolve your bundle ID to one of those. |
| Gatekeeper: "a sealed resource is missing or invalid" | You stapled the notarization ticket to the *extension*. Staple the app only; stapling writes into the bundle and breaks the app's seal. |

The system log is the only honest source:

```sh
log show --last 5m --predicate 'process == "sysextd"' --style compact
```
