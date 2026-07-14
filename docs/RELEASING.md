# Releasing

Pushing a `v*` tag builds, signs, notarizes, and publishes a DMG to GitHub
Releases (`.github/workflows/release.yml`).

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
