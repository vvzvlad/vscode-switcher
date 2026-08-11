#!/usr/bin/env bash
# Builds VSCodeSwitcher.app out of the SwiftPM release binary.
#
#   macos/scripts/build.sh              build the binary and assemble the bundle
#   macos/scripts/build.sh --skip-build reuse the binary already in .build
#
# The bundle also carries the hooks and the hook installer, so "Установить хуки"
# in the menu works for an app copied to /Applications.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$MACOS_DIR/.." && pwd)"
APP_NAME="VSCodeSwitcher"
BUILD_DIR="$MACOS_DIR/.build"
APP_BUNDLE="$MACOS_DIR/$APP_NAME.app"
PLIST_BUDDY="/usr/libexec/PlistBuddy"
SKIP_BUILD=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --skip-build) SKIP_BUILD=1 ;;
        *) echo "Error: unknown option '$1'" >&2; exit 1 ;;
    esac
    shift
done

cd "$MACOS_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
    echo "==> Building release binary..."
    swift build -c release
fi

BINARY="$BUILD_DIR/release/$APP_NAME"
if [[ ! -f "$BINARY" ]]; then
    echo "Error: binary not found at $BINARY" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app..."
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

cp "$MACOS_DIR/Resources/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

APP_VERSION="${APP_VERSION:-$("$PLIST_BUDDY" -c 'Print :CFBundleShortVersionString' "$APP_BUNDLE/Contents/Info.plist")}"
APP_BUILD="${APP_BUILD:-$(git -C "$REPO_DIR" rev-list --count HEAD 2>/dev/null || echo 1)}"
"$PLIST_BUDDY" -c "Set :CFBundleShortVersionString $APP_VERSION" "$APP_BUNDLE/Contents/Info.plist"
"$PLIST_BUDDY" -c "Set :CFBundleVersion $APP_BUILD" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Bundling hooks and the installer..."
mkdir -p "$APP_BUNDLE/Contents/Resources/hooks" "$APP_BUNDLE/Contents/Resources/scripts"
cp "$REPO_DIR"/hooks/*.sh "$APP_BUNDLE/Contents/Resources/hooks/"
cp "$REPO_DIR/scripts/install-hooks.sh" "$APP_BUNDLE/Contents/Resources/scripts/"
chmod +x "$APP_BUNDLE/Contents/Resources/hooks/"*.sh "$APP_BUNDLE/Contents/Resources/scripts/install-hooks.sh"

# ditto and friends can leave Finder metadata behind, which makes codesign fail
# with "resource fork, Finder information, or similar detritus not allowed".
xattr -cr "$APP_BUNDLE"

echo "==> Codesigning (ad-hoc)..."
codesign --force --sign - "$APP_BUNDLE"
codesign -v "$APP_BUNDLE"

echo "==> Built $APP_BUNDLE"
