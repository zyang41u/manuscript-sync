#!/bin/bash
# Build "Manuscript Sync.app" into build/. Pass --install to copy it to ~/Applications.
set -euo pipefail
cd "$(dirname "$0")"
# The Command Line Tools Swift on this Mac doesn't match its SDK; Xcode's toolchain works.
[ -d /Applications/Xcode.app ] && export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer

APP="build/Manuscript Sync.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -parse-as-library -target arm64-apple-macos14 Sources/*.swift \
    -o "$APP/Contents/MacOS/ManuscriptSync"

# Icon: Resources/AppIcon.png (made from icon-source.png by Resources/make_icon.py) -> AppIcon.icns
ICONSET=build/AppIcon.iconset
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
    sips -z $s $s Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
    sips -z $((s * 2)) $((s * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>Manuscript Sync</string>
    <key>CFBundleDisplayName</key><string>Manuscript Sync</string>
    <key>CFBundleIdentifier</key><string>local.manuscript-sync</string>
    <key>CFBundleExecutable</key><string>ManuscriptSync</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"

if [ "${1:-}" = "--install" ]; then
    rm -rf "$HOME/Applications/Manuscript Sync.app"
    cp -R "$APP" "$HOME/Applications/"
    touch "$HOME/Applications/Manuscript Sync.app"  # nudge Finder to pick up a new icon
    echo "Installed to ~/Applications/Manuscript Sync.app"
fi
