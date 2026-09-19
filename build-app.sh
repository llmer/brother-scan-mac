#!/bin/bash
# Builds BrotherScan.app (SwiftUI) and scan-cli (terminal tool) with swiftc.
# Requires Xcode command line tools. The scanner driver must already be built
# (driver/build-driver.sh) for the app to actually scan.
set -euo pipefail
cd "$(dirname "$0")"

APP="BrotherScan.app"
MIN_MACOS="14.0"
ARCH="$(uname -m)"

echo "==> Building $APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  Sources/ScanCore.swift Sources/App.swift \
  -o "$APP/Contents/MacOS/BrotherScan"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Brother Scan</string>
  <key>CFBundleDisplayName</key><string>Brother Scan</string>
  <key>CFBundleIdentifier</key><string>xyz.tse.brotherscan</string>
  <key>CFBundleExecutable</key><string>BrotherScan</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>${MIN_MACOS}</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
</dict>
</plist>
PLIST
echo "APPL????" > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null || true

echo "==> Building scan-cli"
swiftc -O -parse-as-library \
  -target "${ARCH}-apple-macos${MIN_MACOS}" \
  Sources/ScanCore.swift Sources/CLI.swift \
  -o scan-cli

echo "==> Done"
echo "    open $APP           # GUI"
echo "    ./scan-cli out.pdf  # terminal"
