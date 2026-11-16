#!/bin/bash
# Builds a Release Archipel.app and packs it into a DMG with an Applications
# shortcut. Used by .github/workflows/release.yml, and runnable locally.
#
#   ./scripts/build-dmg.sh <version> [build-number]
#
# Signing depends on the environment:
#   SIGNING_IDENTITY  e.g. "Developer ID Application". Unset means an ad-hoc
#                     signature, which Gatekeeper blocks on other Macs until
#                     the user allows it in System Settings > Privacy & Security.
#   DEVELOPMENT_TEAM  the Apple team ID that owns SIGNING_IDENTITY.
#   NOTARY_KEY_PATH, NOTARY_KEY_ID, NOTARY_ISSUER_ID
#                     an App Store Connect API key. When set (and signing with
#                     Developer ID), the app and DMG are notarized and stapled.
#   OUTPUT_DIR        where the DMG goes, defaults to .build/dmg.
#
# Prints the path of the DMG as its last line.
set -euo pipefail

version="${1:?usage: build-dmg.sh <version> [build-number]}"
build="${2:-1}"

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${OUTPUT_DIR:-$root/.build/dmg}"
work="$(mktemp -d "${TMPDIR:-/tmp}/archipel-dmg.XXXXXX")"
trap 'rm -rf "$work"' EXIT
archive="$work/Archipel.xcarchive"
dmg="$out/Archipel-$version.dmg"

if [[ ! -d "$root/Packages/TerminalKit/Frameworks/GhosttyKit.xcframework" ]]; then
  echo "error: GhosttyKit is missing. Run ./scripts/build-ghostty.sh first." >&2
  exit 1
fi

signed=false
[[ -n "${SIGNING_IDENTITY:-}" ]] && signed=true
notarize=false
$signed && [[ -n "${NOTARY_KEY_PATH:-}" ]] && notarize=true

if $signed; then
  team_id="${DEVELOPMENT_TEAM:?DEVELOPMENT_TEAM must be set when SIGNING_IDENTITY is}"
  signing=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="$SIGNING_IDENTITY"
    DEVELOPMENT_TEAM="$team_id"
    OTHER_CODE_SIGN_FLAGS=--timestamp
  )
else
  echo "warning: SIGNING_IDENTITY is not set, signing ad-hoc. Gatekeeper will block this build on first launch." >&2
  # Spelled out so a developer's Configs/Local.xcconfig can't switch it back to their team.
  signing=(CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM=)
fi

echo "Archiving Archipel $version ($build)..." >&2
# Own DerivedData so this never invalidates the Debug build in Xcode's.
xcodebuild archive \
  -project "$root/Archipel.xcodeproj" \
  -scheme Archipel \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -archivePath "$archive" \
  -derivedDataPath "$root/.build/dmg-derived" \
  -quiet \
  MARKETING_VERSION="$version" \
  CURRENT_PROJECT_VERSION="$build" \
  "${signing[@]}" >&2

app="$archive/Products/Applications/Archipel.app"
if $signed; then
  # The export re-signs for distribution and strips anything a Developer ID
  # build must not carry, such as the get-task-allow entitlement.
  cat > "$work/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$SIGNING_IDENTITY</string>
  <key>teamID</key><string>$team_id</string>
</dict>
</plist>
EOF
  xcodebuild -exportArchive \
    -archivePath "$archive" \
    -exportPath "$work/export" \
    -exportOptionsPlist "$work/ExportOptions.plist" >&2
  app="$work/export/Archipel.app"
fi
codesign --verify --deep --strict "$app" >&2

# Local runs pick up frameworks from DerivedData, so one that isn't embedded only
# crashes on other Macs. alpha.2 shipped without TerminalKit that way.
missing=()
while read -r lib; do
  [[ -e "$app/Contents/Frameworks/${lib#@rpath/}" ]] || missing+=("$lib")
done < <(otool -L "$app/Contents/MacOS/Archipel" | awk 'NR > 1 && $1 ~ /^@rpath\// { print $1 }' | sort -u)
if (( ${#missing[@]} )); then
  echo "error: Archipel.app links libraries it doesn't embed in Contents/Frameworks:" >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

if $notarize; then
  # Stapling the app itself, not only the DMG, lets it pass Gatekeeper offline
  # once it has been copied out of the disk image.
  echo "Notarizing the app..." >&2
  ditto -c -k --keepParent "$app" "$work/Archipel.zip"
  "$root/scripts/notarize.sh" "$work/Archipel.zip" >&2
  xcrun stapler staple "$app" >&2
fi

echo "Building the DMG..." >&2
mkdir -p "$work/dmg" "$out"
ditto "$app" "$work/dmg/Archipel.app"
ln -s /Applications "$work/dmg/Applications"
rm -f "$dmg"
hdiutil create -volname Archipel -srcfolder "$work/dmg" -fs APFS -format UDZO "$dmg" >&2

if $signed; then
  codesign --sign "$SIGNING_IDENTITY" --timestamp "$dmg" >&2
fi
if $notarize; then
  echo "Notarizing the DMG..." >&2
  "$root/scripts/notarize.sh" "$dmg" >&2
  xcrun stapler staple "$dmg" >&2
  spctl --assess --type open --context context:primary-signature --verbose "$dmg" >&2
fi

echo "$dmg"
