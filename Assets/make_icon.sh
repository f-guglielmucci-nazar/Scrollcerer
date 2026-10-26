#!/bin/bash
# Regenerates Assets/logo.png and Assets/AppIcon.icns from make_icon.swift.
set -euo pipefail
cd "$(dirname "$0")"
xcrun swift make_icon.swift mouse .
iconutil -c icns AppIcon.iconset -o AppIcon.icns
rm -rf AppIcon.iconset
echo "Wrote Assets/logo.png and Assets/AppIcon.icns"
