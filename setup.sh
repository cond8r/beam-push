#!/bin/bash
# Beam 一键构建脚本
# 用法：bash setup.sh
set -e

FLUTTER="/opt/homebrew/Caskroom/flutter/3.44.2/flutter/bin/flutter"
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$DIR/beam_app"

echo "╔═══════════════════════════════════╗"
echo "║       Beam — 一键构建             ║"
echo "╚═══════════════════════════════════╝"

# ── 1. Flutter create ─────────────────────────────────────────────────────────
if [ ! -f "$APP/pubspec.yaml" ]; then
  echo "==> 创建 Flutter 项目…"
  "$FLUTTER" create \
    --org com.fangduo \
    --project-name beam \
    --platforms android,macos,windows \
    "$APP"
else
  echo "==> 项目已存在，跳过 flutter create"
fi

# ── 2. 覆盖 pubspec.yaml 和源文件 ────────────────────────────────────────────
echo "==> 复制源文件…"
cp "$DIR/flutter_app/pubspec.yaml" "$APP/pubspec.yaml"
cp -r "$DIR/flutter_app/lib"/*    "$APP/lib/"
mkdir -p "$APP/assets"
[ -f "$DIR/flutter_app/assets/icon.png" ] && cp "$DIR/flutter_app/assets/icon.png" "$APP/assets/"
# Android
cp "$DIR/flutter_app/android/app/src/main/AndroidManifest.xml" \
   "$APP/android/app/src/main/AndroidManifest.xml"

# ── 3. pub get ───────────────────────────────────────────────────────────────
echo "==> 安装 Flutter 依赖（需要网络，约 1-2 分钟）…"
cd "$APP"
"$FLUTTER" pub get

# ── 4. 构建 macOS ────────────────────────────────────────────────────────────
echo "==> 构建 macOS App…"
"$FLUTTER" build macos --release
echo "✓ macOS: $APP/build/macos/Build/Products/Release/beam.app"
open "$APP/build/macos/Build/Products/Release/"

echo ""
echo "╔═══════════════════════════════════════════════════════════╗"
echo "║  构建完成！                                               ║"
echo "║                                                           ║"
echo "║  macOS App: build/macos/Build/Products/Release/beam.app  ║"
echo "║                                                           ║"
echo "║  下一步：                                                 ║"
echo "║  1. 在 Firebase Console 创建项目，下载 google-services.json║"
echo "║     放入 android/app/ 目录                               ║"
echo "║  2. 运行：flutter build apk --release                    ║"
echo "║  3. 部署服务器：cd server && bash deploy.sh              ║"
echo "╚═══════════════════════════════════════════════════════════╝"
