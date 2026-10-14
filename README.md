# ios-cloth 衣橱

一个自用的 iPhone 衣柜 App：把家里所有衣服录进去，按**季节 + 温度区间**筛出来，一键生成可穿的搭配。

设计文档见 [DESIGN.md](DESIGN.md) —— 数据模型、推荐算法、里程碑、取舍理由都在那里。

## 现在做到哪了

| 里程碑 | 状态 |
|---|---|
| M0 工程地基（XcodeGen + 签名 + 跑通模拟器） | ✅ 完成 |
| M1 数据层（SwiftData 模型 + 图片落盘 + 推荐引擎 + 56 个单测） | ✅ 完成 |
| M2 录入流程（相机 + 裁切 + **批量继续**） | ⬜ 下一步 |
| M3 衣柜浏览（图墙筛选已在 M1 顺带做了） | ⬜ |
| M4 推荐（引擎与搭配卡已在 M1 顺带做了） | ⬜ |
| M5 穿着记录与反馈 | ⬜ |
| M6 真机 / 发布 | ⬜ |

## 环境（本机实测）

| 项 | 版本 |
|---|---|
| macOS | 26.6.2 (25G83), arm64 |
| Xcode | 26.4 (17E192) |
| Swift | 6.3（工程 `SWIFT_VERSION = 5.9`） |
| 模拟器 | iOS 26.4 (23E244)，常用设备 `iPhone 17 Pro Max` |
| 部署目标 | iOS 18.0 |
| XcodeGen | 2.45.4（`/opt/homebrew/bin/xcodegen`） |
| 依赖 | **零第三方依赖** |

## 跑起来

`.xcodeproj` 是**生成物**，不进版本库（见 `.gitignore`）。改完 `project.yml` 或增删源文件后先重新生成：

```bash
xcodegen generate
```

构建 + 跑测试：

```bash
xcodebuild test -project ioscloth.xcodeproj -scheme ioscloth \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest'
```

装到模拟器并启动：

```bash
xcodebuild -project ioscloth.xcodeproj -scheme ioscloth \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max,OS=latest' \
  -configuration Release build

APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/ioscloth-*/Build/Products/Release-iphonesimulator/ioscloth.app | head -1)
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl install "iPhone 17 Pro Max" "$APP"
xcrun simctl launch "iPhone 17 Pro Max" com.chuxinchen.ioscloth
```

> 用 `-configuration Release` 装模拟器：Xcode 17+ 的 Debug 产物带 `.debug.dylib`，
> `simctl launch` 会被 SBMainWorkspace 拒绝。

也可以直接 `open ioscloth.xcodeproj` 用 Xcode 跑。

## 已知噪音（不是 bug）

跑测试时终端会刷一堆 `CoreData: error: ... Sandbox access to file-write-create denied`。
这是测试宿主 App 首次启动时沙盒目录还没建好的瞬时报错，**测试全部通过、App 也正常**。
实测 App 启动后 `Library/Application Support/default.store` 会正常创建。

## 目录结构

```
project.yml                  XcodeGen 声明（工程的唯一事实来源）
ioscloth/
  App/        入口 · RootTabView · 预览数据
  Models/     Clothing · Outfit · WearRecord · Enums
  Services/   OutfitEngine（推荐）· ImageStore（图片）· ClothingService · BackupService
  Features/   Closet（衣柜）· Outfit（搭配）· Settings（设置）
iosclothTests/   56 个单测（引擎打分 / 搭配组装 / 图片落盘 / 持久化 / 备份）
```

## 隐私

全部数据（含照片）只在这台手机的沙盒里。没有账号、没有后端、没有统计 SDK、不联网。
