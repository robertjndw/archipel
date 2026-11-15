#!/bin/bash
# Builds a Release copy of Archipel from this checkout and installs it to
# /Applications, replacing (and relaunching) any copy already installed there.
# Run it again to update.
#
# Whatever is in the working tree gets built, uncommitted changes included.
# For a clean install, run this from a worktree checked out at main or a tag.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
dest="/Applications/Archipel.app"
# Separate from Xcode's own DerivedData so installing never invalidates the
# Debug build you're iterating on.
derived="$root/.build/install"
built="$derived/Build/Products/Release/Archipel.app"

if [[ ! -d "$root/Packages/TerminalKit/Frameworks/GhosttyKit.xcframework" ]]; then
  echo "error: GhosttyKit is missing. Run ./scripts/build-ghostty.sh first." >&2
  exit 1
fi

if [[ -n "$(git -C "$root" status --porcelain)" ]]; then
  echo "note: building with uncommitted changes from $(git -C "$root" rev-parse --abbrev-ref HEAD)"
fi

# Build before quitting so the installed copy keeps running if the build fails.
echo "Building Release..."
xcodebuild \
  -project "$root/Archipel.xcodeproj" \
  -scheme Archipel \
  -configuration Release \
  -derivedDataPath "$derived" \
  -quiet \
  build

# Read rather than hardcoded, since Configs/Local.xcconfig can change it.
BUNDLE_ID="$(defaults read "$built/Contents/Info" CFBundleIdentifier)"

# Other Release copies (a mounted DMG, a second checkout) share the bundle id,
# so match on the bundle path to make sure we only quit the installed copy.
# terminate() goes through the normal quit path, so unsaved-file and
# running-agent prompts still get a chance to show.
quit_installed() {
  osascript -l JavaScript - "$BUNDLE_ID" "$dest" <<'JS'
ObjC.import('AppKit');
function run(argv) {
  const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0]);
  let pids = [];
  for (let i = 0; i < apps.count; i++) {
    const app = apps.objectAtIndex(i);
    if (app.bundleURL.path.js === argv[1]) {
      app.terminate;
      pids.push(app.processIdentifier);
    }
  }
  return pids.join(' ');
}
JS
}

was_running=false
pids="$(quit_installed)"
if [[ -n "$pids" ]]; then
  was_running=true
  echo "Quitting the installed Archipel..."
  for _ in $(seq 120); do
    alive=false
    for pid in $pids; do
      kill -0 "$pid" 2>/dev/null && alive=true
    done
    $alive || break
    sleep 0.5
  done
  if $alive; then
    echo "error: Archipel is still running (quit cancelled?). Nothing was installed." >&2
    exit 1
  fi
fi

# Copy next to the destination first, then swap, so a failed copy never
# leaves a half-written app behind. ditto into an existing bundle would also
# keep files the new build no longer has.
staging="$(dirname "$dest")/.Archipel.app.installing"
rm -rf "$staging"
ditto "$built" "$staging"
rm -rf "$dest"
mv "$staging" "$dest"

version="$(defaults read "$dest/Contents/Info" CFBundleShortVersionString) ($(git -C "$root" rev-parse --short HEAD))"
echo "Installed Archipel $version to $dest"

if $was_running; then
  open "$dest"
fi
