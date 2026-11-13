#!/bin/bash
# Builds GhosttyKit.xcframework and Ghostty's runtime resources from the
# pinned Ghostty checkout.
#
# GhosttyKit is Ghostty's internal embedding library and has no stable API,
# so we build from an exact tag instead of tracking main. Bump GHOSTTY_TAG
# deliberately and expect to fix up TerminalKit when you do.
set -euo pipefail

GHOSTTY_TAG="v1.4.0"
REQUIRED_ZIG_MINOR="0.17"

root="$(cd "$(dirname "$0")/.." && pwd)"
src="$root/Vendor/ghostty"
# SwiftPM binary targets must live inside the package that declares them.
framework_out="$root/Packages/TerminalKit/Frameworks/GhosttyKit.xcframework"
# terminfo, shell integration and themes. The app copies these into
# Contents/Resources, which is where Ghostty looks for them at runtime.
resources_out="$root/Vendor/ghostty-resources"

if ! command -v zig >/dev/null; then
  echo "error: zig not found. Install Zig $REQUIRED_ZIG_MINOR.x (brew install zig)." >&2
  exit 1
fi
if [[ "$(zig version)" != "$REQUIRED_ZIG_MINOR."* ]]; then
  echo "error: Ghostty $GHOSTTY_TAG needs Zig $REQUIRED_ZIG_MINOR.x, found $(zig version)." >&2
  exit 1
fi

if [[ ! -d "$src/.git" && ! -f "$src/.git" ]]; then
  git clone --depth 1 --branch "$GHOSTTY_TAG" https://github.com/ghostty-org/ghostty.git "$src"
fi

cd "$src"
# -Dxcframework-target=native skips the iOS and x86_64 slices we never ship.
zig build \
  -Doptimize=ReleaseFast \
  -Demit-xcframework=true \
  -Demit-macos-app=false \
  -Dxcframework-target=native \
  -Dsentry=false

rm -rf "$framework_out" "$resources_out"
mkdir -p "$(dirname "$framework_out")" "$resources_out"
cp -R "$src/macos/GhosttyKit.xcframework" "$framework_out"
cp -R "$src/zig-out/share/ghostty" "$resources_out/ghostty"
cp -R "$src/zig-out/share/terminfo" "$resources_out/terminfo"
echo "Built $framework_out"
