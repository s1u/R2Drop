#!/bin/bash
# R2Drop 一键打包脚本
# 在 Mac 上运行: 编译 → 打包 .app → 打开

set -e

APP="R2Drop"
BUILD_DIR=".build/release"
APP_BUNDLE="$APP.app"
DMG="$APP-macOS.dmg"

cd "$(dirname "$0")/.."

echo "🦞 编译 R2Drop..."
swift build -c release

echo "📦 打包 $APP_BUNDLE..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"

cp "$BUILD_DIR/$APP" "$APP_BUNDLE/Contents/MacOS/$APP"

cat > "$APP_BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>R2Drop</string>
    <key>CFBundleIdentifier</key>
    <string>app.r2drop</string>
    <key>CFBundleName</key>
    <string>R2Drop</string>
    <key>CFBundleVersion</key>
    <string>0.1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
</dict>
</plist>
PLIST

echo "🔏 签名..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "💿 打包 DMG..."
hdiutil create -volname "$APP" -srcfolder "$APP_BUNDLE" -ov -format UDZO "$DMG"

echo "🧹 清理临时文件..."
rm -rf "$APP_BUNDLE"

echo ""
echo "✅ 完成！"
echo "   DMG: $(pwd)/$DMG ($(du -h "$DMG" | cut -f1))"
echo ""

# 自动打开 DMG
open "$DMG"
