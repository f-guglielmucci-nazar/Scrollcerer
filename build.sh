#!/bin/bash
# Builds Scrollcerer.app and installs it in /Applications.
# Usage:  bash build.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Scrollcerer"
BUNDLE_ID="local.scrollcerer"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
INSTALL_PATH="/Applications/$APP_NAME.app"

# 1. Apple's free command line tools provide the Swift compiler.
if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed. A window will pop up to install them."
  xcode-select --install || true
  echo "When that install finishes, run:  bash build.sh  again."
  exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"   # arm64 (Apple silicon) or x86_64 (Intel)

echo "Building ${APP_NAME} for ${ARCH}..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

xcrun swiftc \
  -O \
  -swift-version 5 \
  -sdk "$SDK" \
  -target "$ARCH-apple-macos13.0" \
  Sources/*.swift \
  -o "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

# 2. Install (replacing any older copy).
WAS_INSTALLED=0
if [ -d "$INSTALL_PATH" ]; then WAS_INSTALLED=1; fi
pkill -x "$APP_NAME" 2>/dev/null || true
sleep 0.5
rm -rf "$INSTALL_PATH"
cp -R "$APP" "$INSTALL_PATH"

# A rebuilt app has a new signature, so macOS ignores the old Accessibility
# approval. Clear it so the app asks again cleanly.
if [ "$WAS_INSTALLED" = "1" ]; then
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
fi

open "$INSTALL_PATH"
echo
echo "Done. Scrollcerer is in /Applications and running (look for the mouse icon in the menu bar)."
echo "If asked, allow it under System Settings → Privacy & Security → Accessibility."
