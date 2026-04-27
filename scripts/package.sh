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

# 依赖下载失败时自动重试（最多 3 次）
for i in 1 2 3; do
  if swift build -c release 2>&1; then
    break
  fi
  if [ $i -eq 3 ]; then
    echo "❌ 编译失败，已重试 3 次，请检查网络后重试"
    exit 1
  fi
  echo "⚠️  编译失败（第 $i 次），等待 5 秒后重试..."
  sleep 5
done

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

echo "🔏 签名（ad-hoc）..."
codesign --force --deep --sign - "$APP_BUNDLE"

# 去掉隔离属性，避免 Gatekeeper 阻拦未签名应用
echo "🗑️  清除隔离属性..."
xattr -r -d com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true

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
