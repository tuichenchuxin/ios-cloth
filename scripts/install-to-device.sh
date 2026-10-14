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

# 从 `devicectl list devices` 的输出里挑出第一台可用设备的 UDID。
# 只有在整行不含 unavailable 时才认为可用 —— 这样不会把 `unavailable` 误判成 `available`。
device_udid() {
  awk '
    /unavailable/ { next }
    match($0, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  '
}


BUNDLE_ID="com.chuxinchen.ioscloth"

echo "==> 找设备…"
# 设备探测有几个坑，所以写得啰嗦一点：
#   1. devicectl list 会把「记得但已离线 / 没配对」的旧设备也列出来，状态是 unavailable；
#   2. 状态的原始字符串可能是 `available`、`available (paired)`、`connected`；
#   3. `unavailable` 里面含有 `available`，简单 grep available 会挑中不可用的设备。
DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | device_udid)

if [ -z "${DEVICE_ID:-}" ]; then
  echo "❌ 没找到可用的 iPhone。当前设备列表："
  xcrun devicectl list devices
  echo
  echo "   检查：数据线插好、手机解锁、信任此电脑。"
  echo "   如果状态是 unavailable，多半是还没配对："
  echo "     xcrun devicectl manage pair --device <UDID>"
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
# 手机锁着的时候启动会被拒（BSErrorCodeDescription = Locked）。
# 这时候**安装已经成功了**，不该当成失败 —— 解锁后手动点开图标即可。
if xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID" 2>&1 | tee /tmp/ioscloth-launch.log | grep -q "Locked"; then
  echo "   手机处于锁屏状态，先不自动启动。解锁后点桌面上的「衣橱」图标即可。"
fi

echo
echo "✅ 安装完成。证书 7 天后过期，届时再跑一次这个脚本即可。"
