# Releasing

Pushing a `v*` tag builds, signs, notarizes, and publishes a DMG to GitHub
Releases (`.github/workflows/release.yml`).

The release script bundles the complete non-system dylib dependency tree into
`Contents/Frameworks` before signing. This includes indirect dependencies such
as Homebrew's libpsl: a notarized app can still fail at launch if one of its
libraries loads a dependency from the build machine's Homebrew installation.
Bundled dependencies use paths relative to their loader and are signed with
the app's identity. Library validation remains enabled.

To package or check an unsigned local build without signing or installing it:

```sh
python3 scripts/bundle-dependencies.py /path/to/OpenOpal.app
python3 scripts/bundle-dependencies.py /path/to/OpenOpal.app --validate-only
python3 -m unittest discover -s scripts/tests -v
```

Packaging copies dylibs, leaving the original build/Homebrew libraries alone.
It fails on missing dependencies or conflicting library filenames; rebuild
with a consistent dependency set to resolve those errors. Validation inspects
all Mach-O files, including the camera extension, and rejects unresolved
`@rpath` loads and non-system dependencies outside the app. `sign.sh` runs that
same read-only check before signing. Run packaging before signing, since
rewriting a Mach-O file invalidates any existing signature. The packaging tests
compile tiny Mach-O fixtures on macOS without launching the app or camera.

```sh
git tag v0.1.0
git push origin v0.1.0
```

## One-time: repository secrets

The CI can't sign or notarize without these. Add them under
**Settings → Secrets and variables → Actions → New repository secret**. The
base64 values were generated into `~/Library/Application Support/OpenOpal/ci-secrets/`
(that directory is outside the repo and holds the private key — do not commit it).

| Secret | Where it comes from |
|---|---|
| `CERT_P12_BASE64` | contents of `ci-secrets/CERT_P12_BASE64.txt` |
| `CERT_PASSWORD` | contents of `ci-secrets/CERT_PASSWORD.txt` |
| `KEYCHAIN_PASSWORD` | any random string (ephemeral CI keychain) |
| `APP_PROFILE_BASE64` | contents of `ci-secrets/APP_PROFILE_BASE64.txt` |
| `CAMERA_PROFILE_BASE64` | contents of `ci-secrets/CAMERA_PROFILE_BASE64.txt` |
| `NOTARY_APPLE_ID` | your Apple ID email |
| `NOTARY_TEAM_ID` | `RD994J874S` |
| `NOTARY_PASSWORD` | an app-specific password from appleid.apple.com |

The certificate and profiles expire (2031) or are invalidated when you change
capabilities — regenerate them per [SIGNING.md](SIGNING.md) and re-encode the
secrets with `base64 -i <file>`.

## Runner

The workflow uses `runs-on: macos-26` for Xcode 26 / the Liquid Glass SDK. If
GitHub renames that image, update the label. The first run builds depthai-core
from source (~several minutes); it's cached afterward and only rebuilds when
`scripts/bootstrap.sh` changes.
