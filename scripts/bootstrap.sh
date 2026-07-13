#!/usr/bin/env bash
# Fetches and builds depthai-core, the library that talks to the Opal C1's
# Myriad X over USB/XLink. Run once after cloning.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPTHAI_TAG="v2.30.0"
SRC="$ROOT/vendor/depthai-core"
BUILD="$ROOT/build/depthai"
PREFIX="$ROOT/vendor/install"

command -v cmake >/dev/null || { echo "need cmake:  brew install cmake ninja"; exit 1; }
command -v ninja >/dev/null || { echo "need ninja:  brew install cmake ninja"; exit 1; }

if [ ! -d "$SRC" ]; then
  echo "==> cloning depthai-core $DEPTHAI_TAG"
  git clone --depth 1 --branch "$DEPTHAI_TAG" --recurse-submodules --shallow-submodules \
    https://github.com/luxonis/depthai-core.git "$SRC"
fi

# zlib's zutil.h contains a 1990s-era branch:
#     #if defined(MACOS) || defined(TARGET_OS_MAC)
#     #  ifndef fdopen
#     #    define fdopen(fd,mode) NULL   /* No fdopen() */
# TARGET_OS_MAC is defined on modern macOS too, so zlib concludes it's building
# for *classic* Mac OS and macro-defines fdopen to NULL -- which then destroys
# the real fdopen() declaration in the SDK's <_stdio.h>, failing the build. This
# is still present in 1.2.13, so bumping the version alone does not fix it.
# Pre-defining fdopen as itself makes the `#ifndef fdopen` guard false, so the
# bad macro is never installed; the identity macro doesn't recurse, so real call
# sites compile unchanged.
if ! grep -q "OPEN_OPAL_ZLIB_PIN" "$SRC/cmake/Hunter/config.cmake"; then
  echo "==> patching Hunter config: zlib fdopen/TARGET_OS_MAC workaround"
  cat >> "$SRC/cmake/Hunter/config.cmake" <<'EOF'

# OPEN_OPAL_ZLIB_PIN
hunter_config(
    ZLIB
    VERSION "1.2.13-p0-opal"
    URL "https://github.com/cpp-pm/zlib/archive/v1.2.13-p0.tar.gz"
    SHA1 "219ae8c9e5040fb695f84e2cc364fe055d5a7408"
    CMAKE_ARGS
        CMAKE_C_FLAGS=-Dfdopen=fdopen
)
EOF
fi

echo "==> configuring (Hunter builds deps from source; first run takes a few minutes)"
# CMake 4.x removed compatibility with pre-3.5 policies, which Hunter's own
# nested cmake invocations still declare. The env var propagates into those
# nested calls; a -D flag on the outer command does not.
export CMAKE_POLICY_VERSION_MINIMUM=3.5
cmake -S "$SRC" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_INSTALL_PREFIX="$PREFIX" \
  -DBUILD_SHARED_LIBS=ON \
  -DDEPTHAI_BUILD_EXAMPLES=OFF \
  -DDEPTHAI_BUILD_TESTS=OFF \
  -DDEPTHAI_BUILD_DOCS=OFF \
  -DDEPTHAI_OPENCV_SUPPORT=OFF

echo "==> building"
cmake --build "$BUILD" --parallel

echo "==> installing to $PREFIX"
cmake --install "$BUILD"

echo
echo "done. depthai-core -> $PREFIX"
