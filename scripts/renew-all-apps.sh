#!/usr/bin/env bash
#
# 一次性重装这台 Mac 上所有自用 App 到 iPhone。
#
# 免费 Personal Team 证书只有 7 天有效期，过期后手机上的 App 打不开。
# 到期时跑这个脚本即可（前提：手机插线解锁、Xcode 里 Apple ID 处于登录状态）。
#
# 用法：
#   ./scripts/renew-all-apps.sh

set -uo pipefail

BUNDLE_IDS=()

# 从 `devicectl list devices` 里挑第一台可用设备的 UDID（排除 unavailable）
device_udid() {
  awk '
    /unavailable/ { next }
    match($0, /[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}/) {
      print substr($0, RSTART, RLENGTH)
      exit
    }
  '
}

DEVICE_ID=$(xcrun devicectl list devices 2>/dev/null | device_udid)
if [ -z "${DEVICE_ID:-}" ]; then
  echo "❌ 没找到可用 iPhone。检查：插线、解锁、信任此电脑。"
  exit 1
fi
echo "设备：$DEVICE_ID"
echo

# 用法：install_app <显示名> <仓库目录> <工程文件> <scheme> <bundle id>
install_app() {
  local name="$1" dir="$2" project="$3" scheme="$4" bundle="$5"

  if [ ! -d "$dir/$project" ]; then
    echo "⏭  跳过 $name：没找到 $dir/$project"
    return 0
  fi

  echo "=== $name ==="
  pushd "$dir" >/dev/null || return 1
    # 生成式工程先重新生成
    if [ -f project.yml ]; then
      command -v xcodegen >/dev/null && xcodegen generate >/dev/null
    fi

    if ! xcodebuild -project "$project" -scheme "$scheme" \
        -destination "id=$DEVICE_ID" -configuration Debug \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        build 2>&1 | grep -qE "BUILD SUCCEEDED"; then
      echo "❌ $name 构建失败（多半是证书/账号问题）："
      xcodebuild -project "$project" -scheme "$scheme" \
        -destination "id=$DEVICE_ID" -configuration Debug \
        -allowProvisioningUpdates -allowProvisioningDeviceRegistration \
        build 2>&1 | grep -E "error:|No Accounts|No profiles" | head -4
      popd >/dev/null
      return 1
    fi

    local settings
    settings=$(xcodebuild -project "$project" -scheme "$scheme" \
      -configuration Debug -destination "id=$DEVICE_ID" -showBuildSettings 2>/dev/null)
    local products_dir full_name
    products_dir=$(printf '%s\n' "$settings" | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{print $2; exit}')
    full_name=$(printf '%s\n' "$settings" | awk -F' = ' '/ FULL_PRODUCT_NAME /{print $2; exit}')

    if [ -z "$products_dir" ] || [ ! -d "$products_dir/$full_name" ]; then
      echo "❌ $name 找不到构建产物"
      popd >/dev/null
      return 1
    fi

    xcrun devicectl device install app --device "$DEVICE_ID" "$products_dir/$full_name" >/dev/null 2>&1 \
      && echo "✅ $name 已安装" \
      || { echo "❌ $name 安装失败"; popd >/dev/null; return 1; }

    BUNDLE_IDS+=("$bundle")
  popd >/dev/null
}

install_app "衣橱" \
  "/Users/chenchuxin/Documents/github/ios-cloth" \
  "ioscloth.xcodeproj" "ioscloth" "com.chuxinchen.ioscloth"

install_app "RSSReader" \
  "/Users/chenchuxin/Documents/github/rss_private/RSSReader" \
  "RSSReader.xcodeproj" "RSSReader" "com.chuxinchen.rssreader"

echo
echo "=== 启动 ==="
NEEDS_TRUST=0
if [ ${#BUNDLE_IDS[@]} -eq 0 ]; then
  echo "（没有成功安装的 App，跳过启动）"
else
for bundle in "${BUNDLE_IDS[@]}"; do
  output=$(xcrun devicectl device process launch --device "$DEVICE_ID" "$bundle" 2>&1)

  if printf '%s' "$output" | grep -q "not been explicitly trusted"; then
    echo "   $bundle：已安装，但**需要在手机上信任开发者**"
    NEEDS_TRUST=1
  elif printf '%s' "$output" | grep -q "Locked"; then
    echo "   $bundle：已安装，手机锁屏中，解锁后手动点开"
  elif printf '%s' "$output" | grep -q "Launched application"; then
    echo "   $bundle：已启动"
  else
    echo "   $bundle：启动失败（下面可能有用）："
    printf '%s\n' "$output" | grep -iE "error|reason" | head -2
  fi
done
fi

if [ "$NEEDS_TRUST" = "1" ]; then
  echo
  echo "⚠️  手机上需要信任一次开发者证书（重建 profile 后必须重新确认）："
  echo "   设置 → 通用 → VPN 与设备管理 → 开发者 App"
  echo "   → 选「Apple Development: 你的AppleID@example.com」→ 信任"
  echo "   信任后 App 就能正常打开，不需要重装。"
fi

echo
echo "完成。证书 7 天后过期，届时再跑一次这个脚本。"
