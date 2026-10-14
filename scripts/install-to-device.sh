#!/usr/bin/env bash
#
# 构建并安装到真机。
#
# 为什么需要这个脚本：免费 Personal Team 证书**只有 7 天有效期**，
# 到期后手机上的 App 会打不开，必须重新装一次。跑这个脚本就行。
#
# 用法：
#   ./scripts/install-to-device.sh
#
# 前提：手机用数据线连着，且已经解锁过、信任过这台电脑。

set -euo pipefail

cd "$(dirname "$0")/.."

BUNDLE_ID="com.chuxinchen.ioscloth"

echo "==> 找设备…"
# 取第一台已连接的 iPhone；也可以手动改成具体 UDID
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null \
  | grep -iE "iPhone" \
  | grep -iE "connected|available" \
  | head -1 \
  | awk '{print $3}')

if [ -z "${DEVICE_ID:-}" ]; then
  echo "❌ 没找到已连接的 iPhone。"
  echo "   检查：数据线插好、手机解锁、信任此电脑。"
  echo "   查看全部设备：xcrun devicectl list devices"
  exit 1
fi
echo "    设备：$DEVICE_ID"

echo "==> 重新生成 Xcode 工程…"
xcodegen generate >/dev/null

echo "==> 构建（Debug）…"
xcodebuild \
  -project ioscloth.xcodeproj \
  -scheme ioscloth \
  -destination "id=$DEVICE_ID" \
  -configuration Debug \
  -allowProvisioningUpdates \
  build \
  | tail -3

APP_PATH=$(ls -d ~/Library/Developer/Xcode/DerivedData/ioscloth-*/Build/Products/Debug-iphoneos/ioscloth.app | head -1)
if [ ! -d "$APP_PATH" ]; then
  echo "❌ 没找到构建产物：$APP_PATH"
  exit 1
fi

echo "==> 安装到手机…"
xcrun devicectl device install app --device "$DEVICE_ID" "$APP_PATH" 2>&1 | tail -5

echo "==> 启动…"
xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | tail -2

echo
echo "✅ 完成。证书 7 天后过期，届时再跑一次这个脚本即可。"
