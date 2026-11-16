#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="JpSub"
APP_BUNDLE="dist/${APP_NAME}.app"

ARCH="$(uname -m)"
case "$ARCH" in
  arm64)  CPU="arm64" ;;
  x86_64) CPU="x86_64" ;;
  *) echo "不支持的架构：$ARCH"; exit 1 ;;
esac

# 用本机 SDK 版本作为部署目标，避免「目标版本高于本机 SDK」导致编译失败
SDK_VER="$(xcrun --sdk macosx --show-sdk-version 2>/dev/null || true)"
if [ -z "$SDK_VER" ]; then SDK_VER="$(sw_vers -productVersion)"; fi
TARGET="${CPU}-apple-macos${SDK_VER}"

if ! command -v swiftc >/dev/null 2>&1; then
  echo "未找到 swiftc（编译器）。请先在「终端」执行：xcode-select --install"
  exit 1
fi

echo "==> 本机 SDK 版本：$SDK_VER"
echo "==> 清理旧产物"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp Info.plist "$APP_BUNDLE/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $SDK_VER" "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null || true

# 应用图标：优先用 macOS 原生 iconutil 重新生成，缺失时回退到预生成 icns
if [ -f AppIcon.png ]; then
  if command -v iconutil >/dev/null 2>&1 && command -v sips >/dev/null 2>&1; then
    ICONSET=".build-icon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    sips -z 16 16 AppIcon.png --out "$ICONSET/icon_16x16.png" >/dev/null 2>&1
    sips -z 32 32 AppIcon.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null 2>&1
    sips -z 32 32 AppIcon.png --out "$ICONSET/icon_32x32.png" >/dev/null 2>&1
    sips -z 64 64 AppIcon.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null 2>&1
    sips -z 128 128 AppIcon.png --out "$ICONSET/icon_128x128.png" >/dev/null 2>&1
    sips -z 256 256 AppIcon.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null 2>&1
    sips -z 256 256 AppIcon.png --out "$ICONSET/icon_256x256.png" >/dev/null 2>&1
    sips -z 512 512 AppIcon.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null 2>&1
    sips -z 512 512 AppIcon.png --out "$ICONSET/icon_512x512.png" >/dev/null 2>&1
    sips -z 1024 1024 AppIcon.png --out "$ICONSET/icon_512x512@2x.png" >/dev/null 2>&1
    iconutil -c icns "$ICONSET" -o "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
  elif [ -f AppIcon.icns ]; then
    cp AppIcon.icns "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  fi
fi

echo "==> 编译（$ARCH，目标 macOS $SDK_VER）"
if ! swiftc \
  -swift-version 5 \
  -O \
  -target "$TARGET" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Vision \
  -framework AVFoundation \
  -framework AVKit \
  -framework CoreImage \
  -framework CoreVideo \
  -framework CoreGraphics \
  -framework UniformTypeIdentifiers \
  -o "$APP_BUNDLE/Contents/MacOS/$APP_NAME" \
  Sources/*.swift; then
  echo ""
  echo "=========================================="
  echo "  编译失败，没有生成可执行文件。"
  echo "  请把上面 error: 开头的报错行完整截图发给开发者。"
  echo "=========================================="
  rm -rf "$APP_BUNDLE"
  exit 1
fi

echo "==> 本地签名"
codesign --force --sign - "$APP_BUNDLE" >/dev/null 2>&1 || echo "（签名跳过，不影响运行）"

echo ""
echo "构建完成：$(pwd)/$APP_BUNDLE"
echo "现在可以执行： open \"$APP_BUNDLE\""
