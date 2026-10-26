#!/bin/bash
# Builds a universal (Apple silicon + Intel) Scrollmate.app and packs it into
# dist/Scrollmate-<version>.dmg for sharing. Doesn't touch the installed copy.
# Usage:  bash make_dmg.sh
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Scrollmate"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)"
WORK="build/dmg"
APP="${WORK}/root/${APP_NAME}.app"
DMG="dist/${APP_NAME}-${VERSION}.dmg"

if ! xcrun --find swiftc >/dev/null 2>&1; then
  echo "Apple's Command Line Tools are needed:  xcode-select --install"
  exit 1
fi
SDK="$(xcrun --sdk macosx --show-sdk-path)"

rm -rf "$WORK"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" dist

for ARCH in arm64 x86_64; do
  echo "Compiling for ${ARCH}..."
  xcrun swiftc \
    -O \
    -swift-version 5 \
    -sdk "$SDK" \
    -target "${ARCH}-apple-macos13.0" \
    Sources/*.swift \
    -o "${WORK}/${APP_NAME}-${ARCH}"
done
lipo -create "${WORK}/${APP_NAME}-arm64" "${WORK}/${APP_NAME}-x86_64" -output "$APP/Contents/MacOS/$APP_NAME"

cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"

ln -s /Applications "${WORK}/root/Applications"
cat > "${WORK}/root/Read Me First.txt" <<'EOF'
Scrollmate — install

1. Drag Scrollmate into the Applications folder.

2. Open it. macOS will say it can't check it for malicious software,
   because it isn't from an identified developer. Click Done (or OK), then:
   System Settings → Privacy & Security → scroll down → "Scrollmate was
   blocked…" → Open Anyway, and confirm.

3. A mouse icon appears in the menu bar. When asked, switch Scrollmate on in
   System Settings → Privacy & Security → Accessibility.

Settings are under the menu-bar icon → Settings…
Needs macOS 13 Ventura or later. Works on Apple silicon and Intel Macs.
EOF

rm -f "$DMG"
echo "Creating ${DMG}..."
hdiutil create -quiet -volname "$APP_NAME" -srcfolder "${WORK}/root" -fs HFS+ -format UDZO "$DMG"

echo
echo "Done: ${DMG}"
