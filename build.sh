#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
APP="${SCAN_BUILD_APP:-$PWD/高拍扫描助手.app}"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
MACOSX_DEPLOYMENT_TARGET=14.0 swiftc -target arm64-apple-macosx14.0 -swift-version 5 -O -parse-as-library Sources/*.swift -o "$APP/Contents/MacOS/ScanAssistant" -framework SwiftUI -framework AppKit -framework AVFoundation -framework Vision -framework CoreImage -framework ImageIO
xcrun clang -target arm64-apple-macosx14.0 -isysroot "$(xcrun --sdk macosx --show-sdk-path)" -O2 -Wno-deprecated-declarations UVCTool/uvcctl.c -framework IOKit -framework CoreFoundation -o "$APP/Contents/Resources/uvcctl"
cp UVCTool/LICENSE "$APP/Contents/Resources/UVC-License.txt"
codesign --force --sign - "$APP/Contents/Resources/uvcctl"
ditto DocumentScan "$APP/Contents/Resources/DocumentScan"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
if [[ -f Assets/flat-field-default.json ]]; then
    cp Assets/flat-field-default.json "$APP/Contents/Resources/flat-field-default.json"
fi
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>ScanAssistant</string>
<key>CFBundleIdentifier</key><string>local.leisheng.scanassistant</string>
<key>CFBundleName</key><string>高拍扫描助手</string>
<key>CFBundleDisplayName</key><string>高拍扫描助手</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.18</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>NSCameraUsageDescription</key><string>需要使用高拍仪或摄像头拍摄文件。</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
codesign --force --sign - "$APP"
