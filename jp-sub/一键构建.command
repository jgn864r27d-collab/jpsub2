#!/bin/bash
cd "$(dirname "$0")"
chmod +x build.sh 2>/dev/null || true

echo "======================================"
echo "  JpSub 日语字幕播放器 · 一键构建"
echo "======================================"
echo ""

# 检查 Xcode 命令行工具（编译必需）
if ! xcode-select -p >/dev/null 2>&1; then
  echo "首次使用需要安装「苹果命令行开发工具」（免费，约 1GB）。"
  echo ""
  echo "接下来会弹出安装窗口，请点「安装」并耐心等待完成，"
  echo "装完后重新双击本脚本即可。"
  echo ""
  xcode-select --install 2>/dev/null || true
  echo "按回车键关闭此窗口…"
  read -r
  exit 0
fi

./build.sh

if [ ! -d "dist/JpSub.app" ]; then
  echo ""
  echo "构建失败。请把上面报错的文字截图发给开发者。"
  echo "按回车键关闭窗口…"
  read -r
  exit 1
fi

# 移除隔离属性，尽量避免「无法打开」提示
xattr -dr com.apple.quarantine "dist/JpSub.app" 2>/dev/null || true

echo ""
echo "构建成功，正在启动…"
open "dist/JpSub.app"

echo ""
echo "已启动。若系统提示「无法打开」，请到 系统设置 → 隐私与安全性 → 点「仍要打开」。"
echo "按回车键关闭此窗口…"
read -r
