#!/usr/bin/env bash
# Downloads the Core ML depth model into Models/ and compiles it to .mlmodelc.
# Models/ is gitignored (the .mlpackage is ~50MB), so a fresh clone runs this.
#
# Source: https://huggingface.co/apple/coreml-depth-anything-v2-small -- Apple's
# own Core ML conversion of Depth Anything V2 Small. We take the F16 variant:
# the INT8/palettized ones are smaller but no faster on the ANE (which computes
# in fp16 regardless), and they lose accuracy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELS="$ROOT/Models"

REPO="apple/coreml-depth-anything-v2-small"
PKG="DepthAnythingV2SmallF16.mlpackage"
BASE="https://huggingface.co/$REPO/resolve/main"
COMPILED="$MODELS/${PKG%.mlpackage}.mlmodelc"
download_tmp=""
compile_tmp=""

cleanup() {
  status=$?
  trap - EXIT
  trap '' INT TERM
  if [ -n "$download_tmp" ]; then
    rm -f "$download_tmp"
  fi
  if [ -n "$compile_tmp" ]; then
    rm -rf "$compile_tmp"
  fi
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# An .mlpackage is a directory, not a single file, so there is no one URL to
# grab -- fetch each member and rebuild the layout. This is the complete set;
# Manifest.json is what makes the directory a valid package.
FILES=(
  "Data/com.apple.CoreML/model.mlmodel"
  "Data/com.apple.CoreML/weights/weight.bin"
  "Manifest.json"
)

command -v xcrun >/dev/null || { echo "need xcrun: install Xcode command line tools"; exit 1; }

echo "==> fetching $PKG from $REPO"
for f in "${FILES[@]}"; do
  dest="$MODELS/$PKG/$f"
  if [ -s "$dest" ]; then
    echo "    have $f"
    continue
  fi
  mkdir -p "$(dirname "$dest")"
  echo "    get  $f"
  # -L: HF redirects the actual bytes to a CDN host.
  # --fail: without it curl writes a 404 HTML body to the file and exits 0,
  #         which would produce a corrupt package that only fails at compile.
  download_tmp="$(mktemp "$dest.download.XXXXXX")"
  curl --fail --location --progress-bar -o "$download_tmp" "$BASE/$PKG/$f"
  if [ ! -s "$download_tmp" ]; then
    echo "empty model member: $f" >&2
    exit 1
  fi
  mv "$download_tmp" "$dest"
  download_tmp=""
done

# Core ML can load an .mlpackage directly, but it compiles it on first use --
# a few seconds of stall. Shipping the prebuilt .mlmodelc skips that.
echo "==> compiling to .mlmodelc"
compile_tmp="$(mktemp -d "$MODELS/.compile.XXXXXX")"
xcrun coremlcompiler compile "$MODELS/$PKG" "$compile_tmp"
if [ ! -d "$compile_tmp/${PKG%.mlpackage}.mlmodelc" ]; then
  echo "compiler did not produce a compiled model" >&2
  exit 1
fi
if [ -e "$COMPILED" ]; then
  # Exchange complete directories without making the published path disappear.
  xcrun clang -x c - -o "$compile_tmp/exchange-model" <<'C'
#include <stdio.h>
int main(int argc, char **argv) {
  if (argc != 3) return 2;
  if (renamex_np(argv[1], argv[2], RENAME_SWAP) == 0) return 0;
  perror("atomic model replacement");
  return 1;
}
C
  "$compile_tmp/exchange-model" "$compile_tmp/${PKG%.mlpackage}.mlmodelc" "$COMPILED"
else
  mv "$compile_tmp/${PKG%.mlpackage}.mlmodelc" "$COMPILED"
fi

echo
echo "done. compiled model -> $COMPILED"
