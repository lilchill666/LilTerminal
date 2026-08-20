#!/bin/bash
# Rebuilds Vendor/ghostty-vt from source at the pinned revision.
#
# The vendored artifacts are committed so the app builds without a Zig
# toolchain; this script exists to regenerate or bump them deliberately.
#
#   brew install zig     # 0.16.0 or newer
#   Tools/build-ghostty-vt.sh [revision]
set -euo pipefail
cd "$(dirname "$0")/.."
REV="${1:-50d3ac8ed6ad1cbca498f7a4388ab14054a5c3e1}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

git clone --filter=blob:none https://github.com/ghostty-org/ghostty.git "$WORK/ghostty"
git -C "$WORK/ghostty" checkout "$REV"
# -Demit-lib-vt builds only the VT library: no macOS app, no docs.
(cd "$WORK/ghostty" && zig build -Demit-lib-vt=true -Doptimize=ReleaseFast --prefix ./out)

rm -rf Vendor/ghostty-vt
mkdir -p Vendor/ghostty-vt/lib Vendor/ghostty-vt/include
# The xcframework's macOS slice is universal (arm64 + x86_64).
cp "$WORK/ghostty/out/lib/ghostty-vt.xcframework/macos-arm64_x86_64/libghostty-vt.a" Vendor/ghostty-vt/lib/
cp -R "$WORK/ghostty/out/include/ghostty" Vendor/ghostty-vt/include/
cat > Vendor/ghostty-vt/REVISION <<REVEOF
ghostty-org/ghostty @ $REV
built with zig $(zig version) via Tools/build-ghostty-vt.sh
REVEOF
echo "Vendored libghostty-vt @ $REV"
