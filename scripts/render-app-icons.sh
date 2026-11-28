#!/bin/bash
# Renders the alternate app icons in AppIcons/*.icon, plus a light and a dark
# render of the main Archipel.icon for the Auto tile, into image sets the app
# loads at runtime (Settings > Appearance > App Icon).
#
#   ./scripts/render-app-icons.sh
#
# Run it after editing any .icon file and commit the PNGs. The .icon files stay
# the source: open them in Icon Composer to change a design. They are not
# compiled as app icons, because macOS can only switch icons by handing the
# Dock and Finder a flat image.
set -euo pipefail

cd "$(dirname "$0")/.."

ictool="$(xcode-select -p)/../Applications/Icon Composer.app/Contents/Executables/ictool"
[[ -x "$ictool" ]] || { echo "Icon Composer's ictool not found at $ictool" >&2; exit 1; }

out=Archipel/Assets.xcassets/AppIcons
rm -rf "$out"
mkdir -p "$out"
cat > "$out/Contents.json" <<'JSON'
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON

# 512 pixels covers the Dock at full magnification. 1024 would add about a
# megabyte per icon to the app.
#
# ictool fills the whole canvas, but macOS icons sit in an 824 body on a 1024
# canvas. Without that margin the icon looks too big next to other apps in the
# Dock, so render at 412 and pad to 512.
render() {
    local icon=$1 name=$2 rendition=$3
    local set="$out/$name.imageset"
    mkdir -p "$set"
    "$ictool" "$icon" --export-image --output-file "$set/$name.png" \
        --platform macOS --rendition "$rendition" --width 412 --height 412 --scale 1 >/dev/null
    sips --padToHeightWidth 512 512 "$set/$name.png" >/dev/null
    cat > "$set/Contents.json" <<JSON
{
  "images" : [
    {
      "filename" : "$name.png",
      "idiom" : "universal"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
JSON
    echo "$set"
}

render Archipel/Archipel.icon AppIconSystemLight Default
render Archipel/Archipel.icon AppIconSystemDark Dark
for icon in AppIcons/*.icon; do
    base=$(basename "$icon" .icon)
    render "$icon" "AppIcon$base" Default
done
