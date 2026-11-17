# Releasing

Releases are started by hand, so several PRs can go in first:

```sh
gh workflow run release.yml -f version=0.2.0
```

Or use Actions > Release > Run workflow on GitHub. The run builds `master`,
signs and notarizes it, makes the `v0.2.0` tag, and publishes the DMG to GitHub
Releases (`.github/workflows/release.yml`). The app, camera extension and
launcher all get that version, and the run's number as their build number.

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

The release workflow gives the app, camera extension and launcher the same
`CFBundleVersion`. `sign.sh` seals the built host Info.plist into the extension
before signing it. Tell users to reinstall the virtual camera after updating; an
older extension cannot validate the new host.

Run the camera-free producer and stream checks with `bash scripts/check-sink.sh`.

## Model downloads

`fetch-models.sh` downloads each package member to its own sibling temporary
file. Only a successful, nonempty download replaces the cached member, so a
failed or interrupted download is fetched again on the next run. Exit, interrupt,
and termination traps remove only the temporary file owned by that run.

## Compiled model publication

Compilation writes into a unique staging directory beside the published model.
On macOS, a small native helper uses `renamex_np(RENAME_SWAP)` to exchange the
complete old and new directories in one operation. The published path never
disappears during replacement, and compile or exchange failures keep the old
model. A first install renames the complete staged model into place.

Normal exits and catchable interruptions remove this run's staging directory.
`SIGKILL` cannot run cleanup, so it may leave a `.compile.*` directory behind,
but the published path still contains the complete old or new model. Later runs
use their own staging directories and do not remove another run's files.

## One-time: repository secrets

The CI can't sign or notarize without these. Add them under
**Settings → Secrets and variables → Actions → New repository secret**. The
base64 values were generated into `~/Library/Application Support/OpenOpal/ci-secrets/`
(that directory is outside the repo and holds the private key — do not commit it).

| Secret | Where it comes from |
|---|---|
| `CERT_P12_BASE64` | contents of `ci-secrets/CERT_P12_BASE64.txt` |
| `CERT_PASSWORD` | contents of `ci-secrets/CERT_PASSWORD.txt` |
| `APP_PROFILE_BASE64` | contents of `ci-secrets/APP_PROFILE_BASE64.txt` |
| `CAMERA_PROFILE_BASE64` | contents of `ci-secrets/CAMERA_PROFILE_BASE64.txt` |
| `ASC_KEY_P8` | the text of an App Store Connect API key, `AuthKey_XXXXXXXXXX.p8` |
| `ASC_KEY_ID` | that key's ID, the `XXXXXXXXXX` in its file name |
| `ASC_ISSUER_ID` | the issuer ID shown above the keys in App Store Connect |

The certificate and profiles expire (2031) or are invalidated when you change
capabilities — regenerate them per [SIGNING.md](SIGNING.md) and re-encode the
secrets with `base64 -i <file>`.

## Runner

The workflow uses `runs-on: macos-26` for Xcode 26 / the Liquid Glass SDK.
Move it (and `build.yml`) to `macos-27` once GitHub offers that image. Builds
target macOS 14 regardless of the runner, and `bundle-dependencies.py` fails
the release if any bundled library needs a newer macOS than that. The first run builds depthai-core
from source (~several minutes); it's cached afterward and only rebuilds when
`scripts/bootstrap.sh` or `patches/` change.

## Release names

The version you type is checked first: it must look like `0.2.0`. It then
reaches the shell steps through the `RELEASE_VERSION` environment variable and
is never pasted into a script.
