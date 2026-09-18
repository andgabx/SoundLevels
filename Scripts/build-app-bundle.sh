#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="SoundLevels"
APP_BUNDLE="$REPO_ROOT/$APP_NAME.app"
ICONSET_DIR="$SCRIPT_DIR/AppIcon.iconset"
ICNS_PATH="$SCRIPT_DIR/AppIcon.icns"

echo "==> Cleaning previous build output..."
rm -rf "$APP_BUNDLE" "$ICONSET_DIR"

echo "==> Building release binary..."
if ! (cd "$REPO_ROOT" && swift build -c release); then
    echo "error: swift build -c release failed" >&2
    exit 1
fi

RELEASE_DIR="$REPO_ROOT/.build/release"
BINARY_PATH="$RELEASE_DIR/$APP_NAME"
RESOURCE_BUNDLE="$RELEASE_DIR/${APP_NAME}_AudioMixerKit.bundle"

if [ ! -x "$BINARY_PATH" ]; then
    echo "error: release binary not found at $BINARY_PATH" >&2
    exit 1
fi
if [ ! -d "$RESOURCE_BUNDLE" ]; then
    echo "error: AudioMixerKit resource bundle not found at $RESOURCE_BUNDLE" >&2
    exit 1
fi

echo "==> Rendering app icon..."
if [ ! -f "$SCRIPT_DIR/AppIcon.svg" ]; then
    echo "error: icon source not found at $SCRIPT_DIR/AppIcon.svg" >&2
    exit 1
fi
if ! swift "$SCRIPT_DIR/render-icon.swift"; then
    echo "error: render-icon.swift failed" >&2
    exit 1
fi
if ! iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"; then
    echo "error: iconutil failed to assemble $ICNS_PATH" >&2
    exit 1
fi

echo "==> Assembling $APP_NAME.app..."
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"
cp "$BINARY_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ICNS_PATH" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp -R "$RESOURCE_BUNDLE" "$APP_BUNDLE/Contents/Resources/"
cp "$REPO_ROOT/Sources/SoundLevels/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

echo "==> Ad-hoc signing..."
if ! codesign --force --deep --sign - "$APP_BUNDLE"; then
    echo "error: codesign failed to sign $APP_BUNDLE" >&2
    exit 1
fi
if ! codesign --verify --deep --strict "$APP_BUNDLE"; then
    echo "error: codesign --verify failed for $APP_BUNDLE" >&2
    exit 1
fi

echo "==> Done: $APP_BUNDLE"
