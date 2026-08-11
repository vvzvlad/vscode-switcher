#!/usr/bin/env bash
# Renders every raster the bundle needs out of the SVG sources.
#
#   macos/scripts/make-icons.sh
#
# Sources (hand-edited, versioned):
#   macos/Resources/icon.svg           app icon, 128 px and up
#   macos/Resources/icon-small.svg     app icon, 16/32 pt (rendered at 16/32/64)
#   macos/Resources/icon-menubar.svg   status item glyph, template image
#
# Products:
#   macos/Resources/AppIcon.icns                  referenced by CFBundleIconFile
#   macos/Resources/MenuBarIconTemplate.png       18x18, and @2x at 36x36
#   macos/.build/icons/AppIcon.iconset/*.png      intermediates, regenerated
#
# The script is idempotent: it wipes the iconset and rewrites every product on
# each run, so the output depends only on the SVG sources.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
RES_DIR="$MACOS_DIR/Resources"
WORK_DIR="$MACOS_DIR/.build/icons"
ICONSET="$WORK_DIR/AppIcon.iconset"

ICON_SVG="$RES_DIR/icon.svg"
ICON_SMALL_SVG="$RES_DIR/icon-small.svg"
MENUBAR_SVG="$RES_DIR/icon-menubar.svg"

require_tool() {
    local tool="$1" hint="$2"
    if ! command -v "$tool" >/dev/null 2>&1; then
        echo "Error: '$tool' not found in PATH. $hint" >&2
        exit 1
    fi
}

require_file() {
    if [[ ! -f "$1" ]]; then
        echo "Error: missing SVG source '$1'" >&2
        exit 1
    fi
}

require_tool rsvg-convert "Install it with: brew install librsvg"
require_tool iconutil "It ships with the Xcode command line tools: xcode-select --install"

require_file "$ICON_SVG"
require_file "$ICON_SMALL_SVG"
require_file "$MENUBAR_SVG"

# render <svg> <pixel size> <destination>
render() {
    rsvg-convert --width "$2" --height "$3" --format png "$1" --output "$4"
}

echo "==> Rendering the iconset..."
rm -rf "$ICONSET"
mkdir -p "$ICONSET"

# 16 pt and 32 pt (so 16, 32 and 64 px) come from the simplified drawing: five
# rows collapse into a grey smear at that scale.
render "$ICON_SMALL_SVG" 16 16 "$ICONSET/icon_16x16.png"
render "$ICON_SMALL_SVG" 32 32 "$ICONSET/icon_16x16@2x.png"
render "$ICON_SMALL_SVG" 32 32 "$ICONSET/icon_32x32.png"
render "$ICON_SMALL_SVG" 64 64 "$ICONSET/icon_32x32@2x.png"

render "$ICON_SVG" 128 128 "$ICONSET/icon_128x128.png"
render "$ICON_SVG" 256 256 "$ICONSET/icon_128x128@2x.png"
render "$ICON_SVG" 256 256 "$ICONSET/icon_256x256.png"
render "$ICON_SVG" 512 512 "$ICONSET/icon_256x256@2x.png"
render "$ICON_SVG" 512 512 "$ICONSET/icon_512x512.png"
render "$ICON_SVG" 1024 1024 "$ICONSET/icon_512x512@2x.png"

echo "==> Building AppIcon.icns..."
iconutil --convert icns --output "$RES_DIR/AppIcon.icns" "$ICONSET"

echo "==> Rendering the menu bar template..."
# The "Template" suffix is what makes AppKit tint the image for the current
# menu bar appearance; only the alpha channel is used.
render "$MENUBAR_SVG" 18 18 "$RES_DIR/MenuBarIconTemplate.png"
render "$MENUBAR_SVG" 36 36 "$RES_DIR/MenuBarIconTemplate@2x.png"

echo "==> Done:"
echo "    $RES_DIR/AppIcon.icns"
echo "    $RES_DIR/MenuBarIconTemplate.png"
echo "    $RES_DIR/MenuBarIconTemplate@2x.png"
