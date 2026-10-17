# ios-cloth · 设计文档（v0.1 草案）

> 一个自用的 iPhone 衣柜 App：把家里所有衣服录进去，按**季节 + 温度区间**筛出来，
> 一键生成可穿的搭配，并支持边用边迭代。
>
> 本文是 v1 的设计基线。**带 🔸 的是需要你拍板的决策点**，带 ❓ 的是待确认问题。

---

## 0. TL;DR

- **做什么**：单机、免费、无账号的 iPhone App。录入衣物（拍图 + 分类 + 季节 + 温度区间）→ 按天气/场景筛出候选 → 生成搭配 → 存成「今天的这身」。
- **技术选型**：SwiftUI + **SwiftData**（不是 UserDefaults）+ 图片存沙盒文件 + 无后端。iOS 18.0 起。
- **核心设计取舍**：温度不用「一个数」，用**区间 + 多季节标签**，因为真实衣柜里一件风衣横跨 8–20°C、毛衣横跨整个冬天，单选季节会把你老婆一半的衣服筛丢。
- **v1 范围**：录入、浏览筛选、规则搭配生成、搭配收藏、本地备份导出。**3–4 周可自用**。
- **最大风险不是代码，是录入成本**（几百件衣服拍一遍 1–2 小时），所以录入流程被当成一等公民设计（见 §7）。

---

## 0.5 实施进度（滚动更新）

| 里程碑 | 状态 | 说明 |
|---|---|---|
| M0 工程地基 | ✅ | XcodeGen + `project.yml`，模拟器编译运行通过 |
| M1 数据层 | ✅ | SwiftData 模型、`ImageStore`、`OutfitEngine`、`BackupService` |
| M2 录入流程 | ✅ | 相机 + 裁切 + 「保存并继续」批量录入；**5 条 UI 端到端测试**覆盖主链路 |
| M3 衣柜浏览 | 🟡 部分 | 图墙 + 分类/季节/状态筛选 + 搜索已可用；温度区间筛选、批量改状态待做 |
| M4 推荐 | 🟡 部分 | 引擎 + 打分 + 理由文案 + 换一套 + 就这套已可用；多层搭配待做 |
| M5 穿着记录与反馈 | ⬜ | 表结构已就位，UI 未做 |
| M6 真机 | ✅ | 已装到「陈出新的iPhone」（iOS 27.0.1）。免费证书，**7 天需重装**，见 `scripts/install-to-device.sh` |

**测试总量：100 个**（93 单测 + 7 UI 端到端），全绿。

### 已知的坑（都是真机上暴露出来的，改之前先读）

| # | 现象 | 根因 | 修法 |
|---|---|---|---|
| 1 | 删衣物后搭配卡指向已删除对象 | `OutfitItem.clothing` 的 `@Relationship(deleteRule:)` 在这条边上不可靠 | `ClothingService.delete` 里显式置空 |
| 2 | `清空全部数据` 直接抛错 | `context.delete(model:)` 是 SQL 级批量删除，绕过级联规则，撞上 `mandatory OTO nullify inverse` 约束 | 逐条 `context.delete(_:)` |
| 3 | 裁切时可能吃爆内存 | `CGRect.intersection` 在两矩形不相交时返回 **`.infinite`** 而不是 `.null`，而 `isNull` 对 infinite 是 false | 额外校验 `isFinite` |
| 4 | **点相机「使用照片」后什么都没发生** | 相机自己 `@Environment(\.dismiss)`，而它被包在 `fullScreenCover(isPresented: .constant(true))` 里 —— 相机一关把整个 cover 一起拆掉，刚出现的裁切页被连带销毁 | 模态结构重排：相机用 cover、裁切用 push、表单用 sheet，**任何子视图不自己 dismiss**（见 `CaptureFlowView` 顶部注释） |
| 5 | 相册入口跳过裁切页、也没有「保存并继续」 | `ClosetView` 里另外挂着一个 `.photosPicker` + `.sheet(mode: .singlePhoto)`，**绕过了 `CaptureFlowView` 状态机**，导致相册和拍照走两套代码 | 删掉并行那条路，录入只保留 `CaptureFlowView` 一个入口 |
| 6 | **录完点保存没反应／没存进去** | 「保存并结束」在底部工具栏，**被键盘盖住**，点不到 | 保存栏改成 `safeAreaInset`（在滚动区之外，永远可见），不用工具栏 |
| 7 | UI 测试之间互相污染 | 数据持久化，上一条测试存的衣物影响下一条的断言 | App 支持 `-uitest-reset-data` 启动参数（仅供测试） |
| 8 | **点「保存并继续」/「保存并结束」/「返回」都没反应**，只有手动下滑页面才关得掉（而数据其实已经存了） | 子视图用 `@Environment(\.dismiss)` **自己关自己**，导致 sheet 的绑定和真实状态对不上 | 立下规矩：**任何子视图不许自己关闭自己**，一律回调给 `CaptureFlowView`，由它改 `scene` |
| 9 | 进裁切页慢、拖动和缩放卡 | 每帧都在把 4000×3000 的原图按 340pt 重采样 | 先生成长边 1200px 的预览图（在主线程外生成），屏幕只画它；点「完成」时再把裁切矩形按比例映射回原图切全分辨率 |
| 10 | **裁切页刚弹出就自己退出了**，照片没存进来 | `enter()` 里的 `guard nextScene == nil else { return }`：只要命中一次（比如同一个回调被系统触发两次），状态机就**永久卡死**，之后的点击全部静默失效；而且延时后的二次状态变更会把刚建好的页面拆掉 | 状态机改成「**同步完成**，只有 `裁切 → 表单` 这两个模态之间才等关闭动画」。去掉那个会卡死的守卫；重复调用变成幂等 |
| 11 | 手动放大后取景框「漂到右下」，**无论捏哪里方向都一样** | 见下方「坑 11 详解」 | 缩放平移交给 `UIScrollView`，不再自己写手势、不再手算裁切矩形 |
| 12 | 取景框没垂直居中 | `GeometryReader` 分配的可用高度与 `UIScrollView` 实际落位差约 32pt（安全区） | 用 `.overlay` 让取景框和滚动视图**共用同一个几何源** |
| 13 | 裁切页「完成」按钮点不动、用户卡死 | 我给按钮加了 `.disabled(fitScale <= 0)`，而 `fitScale` 是 UIKit 回调**异步**上报的，没上报到按钮就永远不可点 | 刻意不 disable：按钮点了必须有反应，参数缺失时退回原图（可接受的降级） |
| 14 | 换成 `UIScrollView` 后**完全没法缩放** | 缩放范围在 `makeUIView` 里算，那时视图还没进层级、`bounds` 是 zero，`minimumZoomScale` 被设成 0/NaN —— `UIScrollView` 会因此完全不响应捏合 | 缩放装配挪到 `layoutSubviews`（`bounds` 定稿后再配），构造函数里先给一个合法的非零范围兜着 |
| 15 | **放大后拖到衣服上，裁出来还是图片正中央** | 裁切矩形被我写成了「原图中央的正方形」，忽略了平移 | 把 `UIScrollView` 的 `contentOffset` 和可视尺寸一起上报，裁切中心 = `(viewportSize/2 + contentOffset) / zoomScale`（纯函数 + 单测） |
| 16 | 取景框又小又挤 | 写死 340pt | 改成按屏幕短边取 88%（夹在 240–520pt，且不超过可用空间） |
| 16c | **框内外看起来像两张图**，缩放时明显错位 | 我用「框内滚动视图 + 框外再画一张同变换的 Image」来补背景。这是根本错误：`UIScrollView` 内部缩放是实时的，SwiftUI 的重绘永远追不上，两者必然错位 | **屏幕上只保留一张图**：滚动视图 frame = 取景框，但 `clipsToBounds = false` —— 同一张图溢出到框外，再由 `CropOverlay` 压暗。夹取边界仍是取景框，边缘可达性不受影响 |
| 16b | **贴着原图最上面的内容怎么拖都进不了框**（反复反馈三次） | **滚动视图的尺寸和取景框不一致**。`UIScrollView` 把内容夹在「自身边界」内，所以视口比取景框大时，图片边缘最多只能走到 `(视口 − 取景框)/2` 的位置，永远差这一截。中间我还走过一次弯路：把滚动视图铺满整屏 + 取景框当覆盖层，看着像修好了，其实正是这个 bug | **滚动视图的 frame 严格等于取景框**（`ZStack` 里 `Color` + `CropOverlay` + 等大的 `ZoomableCropView`）。这是 iOS 所有成熟裁切器（RSKImageCropper / TOCropViewController）的共同做法 |
| 17 | **「保存并结束」没有退出流程，而是回到入口页** | `enter(.idle)` 只切到入口页，外层那个 `fullScreenCover` 还在；而在同一帧里既关内层 sheet 又关外层 cover 会让 SwiftUI 丢状态 | 新增 `finishFlow()`：先切到 idle 让表单收干净，等 400ms 动画走完再 `onFinish()` |
| 18 | 「保存并结束」和「保存并继续」行为完全一样（都回相机） | 外壳的 `onSave` 回调写成了恒定的 `onSaved(true)`，用户点的是哪个按钮根本没传出去 | `onSave` 改成接收 `SaveRequest`，如实转达用户的选择 |

#### 坑 11 详解：为什么「无论捏哪里都往同一方向漂」

我先后猜错了三次（改锚点公式、改坐标换算、加延迟），都没用。
最后是**写 UI 测试把真实手势数值打出来**才定位：

```
pinch m=3.63 a=0.18,0.17 s=1.829 off=4,4    ← 捏合点在左上角
pinch m=3.68 a=0.05,0.05 s=7.109 off=27,27  ← 第二次更靠左上
```

`MagnifyGesture` 的 `startAnchor` **报的是被缩放后的图片坐标系，不是容器坐标**。
我拿它当容器坐标去做锚定计算，补偿量完全错 —— 所以漂移方向与手指位置无关。

**同时证明了一件事**：我用手写手势 + 手算坐标系这条路是错的。
换 UIKit 后另外两个坑也一并消失。

> 教训：坐标换算类的 bug，**不要靠推导和目测**。
> 要么把真实数值打出来，要么直接量截图像素（这次量出取景框中心 y=1510、图片中心 y=1521，
> 差 4pt 属于已居中 —— 而我之前目测说「偏了 70pt」是错的）。

#### 坑 16b 的教训：不要自己发明几何

这个问题我改了**四轮**才修好，中间两次的修改方向都是错的（先是把取景框改大、
再是把滚动视图铺满整屏），因为我在凭直觉发明布局，而不是去看成熟实现怎么做。

**正确做法是：先搜现成方案，再动手。** 用户提醒我这一点之后，
从 [RSKImageCropper](https://github.com/ruslanskorb/RSKImageCropper/blob/master/RSKImageCropper/RSKImageScrollView.m)
和 [TOCropViewController](https://github.com/woshizilong/TOCropViewController)
的共同结构里一眼就看到了答案：**缩放视图和取景框必须同尺寸**。

以后遇到「这类交互应该怎么做」而不是「这个函数怎么用」，
先搜一遍成熟实现，别急着改。

#### 排查这类问题有效的手段（按可靠性排序）

这几轮排查里，只有后两种真正定位到了问题：

| 手段 | 效果 |
|---|---|
| 推导 / 目测 | ❌ 连续猜错三次（锚点公式、坐标换算、加延时） |
| 在界面上加读数 | 🟡 有时拿不到（`XCUIElement.label` 读不到实时文本） |
| **写 UI 测试把真实数值打出来** | ✅ 一次定位 `startAnchor` 坐标系错误 |
| **量截图像素** | ✅ 一次确认取景框是否真的居中 |
| **看元素 frame 前后变化** | ✅ 一次确认缩放/平移是否真的生效 |
| **在 App 里显示派生量**（如「将保存 695 × 695 像素」） | ✅ 一次发现「平移不影响裁切」——尺寸不变就说明位置没参与计算 |

最后一条尤其值得记住：**把内部推导结果直接显示出来**，比任何间接观察都快。
现在裁切页底部常驻显示「将保存 N × N 像素」，这既方便用户预判结果，
也让这类「参数没接进公式」的 bug 无法藏身。

> 第 4～9 条都**只在真机/真交互下才暴露**，单测完全覆盖不到。
> 这也是为什么这个项目从 M2 起就配了 UI 端到端测试（`iosclothUITests/`）。

### 三条铁律（改动模态 / 状态机前必读）

1. **任何子视图不许自己关闭自己。** 关闭一律由持有状态的那一层发起，
   子视图只通过回调报告「保存了」「取消了」。
2. **只在必要时才等关闭动画。** 同一次状态更新里既关 sheet 又开 cover，
   SwiftUI 会把两者一起丢掉 —— 但**不能给所有切换都加延时**，
   否则延时的二次状态变更会把刚建好的页面拆掉（坑 10）。
   现在的规则：只有「裁切 → 表单」（模态 → 模态）等 400ms，其余同步完成。
3. **状态切换不能有「被丢弃就永久卡死」的守卫。** 那种 `guard 正在切换 else { return }`
   一旦命中一次，后面所有点击都静默失效，而且极难查（坑 10）。
   宁可让重复调用幂等，也不要写会丢事件的守卫。
4. **按钮不许因为「参数还没准备好」而不可点。** 参数缺失就降级处理，
   不能让用户卡在一个点不动的界面上（坑 13）。
5. **不要手写坐标换算。** 能用系统组件（`UIScrollView` 的缩放平移、
   `convert(_:to:)`）就别自己算。真必须算，就写成纯函数并单测（坑 11）。

### 已定但未做（下轮候选）

| 项 | 说明 |
|---|---|
| 多层搭配 | 一套搭配目前每个部位只能放一件。要让「打底 + 毛衣 + 外套」成立，需要把 `OutfitDraft.assignments` 从 `[槽位: 衣物]` 改成 `[槽位: [衣物]]`（有序层），并迁移 `OutfitItem`。`Clothing.isLayerable` 就是为此预留的，现在界面上已隐藏、不参与任何计算 |
| 温度区间筛选 | 衣柜目前能按分类/季节/状态筛，还不能按温度区间筛 |
| 批量改状态 | 换季收纳需要长按多选 |
| 真实数据验证 | 算法是否准，只有真的录一批衣服才知道 |

### 代码风格约定

- **不要写兼容/兜底式的"以防万一"代码。** 不为旧版本、旧数据、旧接口留分支。
  这个 App 只有一个用户（自己），没有历史包袱需要背。
- **不要怕重写。** 结构不对就整个重写，不要在错的结构上打补丁 ——
  第 8 条坑就是"打补丁式重构"留下的：新的录入流程建好了，旧的相册入口没删，
  于是同一件事有了两套行为不一致的代码。
- **一处只做一件事。** `ClothingForm` 只管表单，`ClothingEditView` 只管外壳和按钮，
  `CaptureFlowView` 只管流程调度。谁持有状态，谁负责关闭。
- **注释写「为什么」，不写「做了什么」。** 尤其是踩过的坑，要写清现象和根因，
  否则下一个人（包括三个月后的自己）会原样踩回去。

---

## 1. 需求理解与边界

### 1.1 原始需求拆解

| 你的原话 | 翻译成功能 | 优先级 |
|---|---|---|
| 把所有衣服录入 app | 衣物条目 = 图片 + 结构化属性 | P0 |
| 从手机里挑衣服 | 图墙浏览 + 多维筛选 + 搜索 | P0 |
| 搭配 | 搭配编辑器（手动）+ 规则推荐（自动） | P0 / P1 |
| 录入时顺便录入季节、温度 | 季节多选标签 + 温度区间 | P0 |
| 从对应季节/温度的区间里挑 | 按当前天气/手动温度反查候选 | P0 |
| 持续迭代 | 数据模型可演进、本地可导出备份、里程碑式开发 | P0 |

### 1.2 真实用户场景（写成验收用例）

1. **早上 7:40，出门前 5 分钟**：老婆打开 App，看到"今天 12°C 多云 · 冬季"，点"给我搭一套"，出来 3 套候选，选一套存为"今天"，走。→ **全流程 ≤ 30 秒**。
2. **换季整理**：她把冬季衣服收起来，长按多选 → 批量标记"已收纳"。冬天再问 App 时，收纳中的衣服不出现在推荐里。
3. **刚买了一件大衣**：拍 1 张照，点"冬季 + 秋季"，把温度滑块拖到 −5～12°C，30 秒录完。
4. **"我这件白衬衫配什么"**：在衣物详情页点"和它搭一套"，App 以这件为锚点补齐其余部位。
5. **想不起某件衣服长什么样**：搜"牛仔"，或按"蓝色 + 上衣"筛。

### 1.3 明确不做（v1）

- ❌ 账号、云后端、社交分享（这决定它免维护、零成本）
- ❌ 穿搭日历、打卡社交、AI 生图
- ❌ 男装/童装/多用户切换（架构留口子，不实现）
- ❌ 商城比价、二手转卖

---

## 2. 技术选型与理由

> 环境基线来自你的 RSSReader 项目（`knowledge-kb/projects/rssreader/environment.md`）：
> macOS 26.6.2 / Xcode 26.4 / Swift 6.3 / iOS 26.4 模拟器 / Team `M7GUVHHD97`。

| 项 | 选型 | 为什么不用备选 |
|---|---|---|
| UI | **SwiftUI** | 与 RSSReader 同栈，你熟的坑都已沉淀在知识库 |
| 数据 | **SwiftData**（iOS 17+） | ❌ UserDefaults：RSSReader 用它存文章列表是历史包袱；衣物带图片索引和大量查询（按温度区间、多标签、排序），UserDefaults 要全量反序列化，几百件就卡 |
| 图片 | **沙盒文件 + 库内只存文件名** | ❌ 存进 SwiftData Blob：数据库膨胀、备份变慢、缩略图无法独立管理；❌ 存 Photos 相册：需要相册权限、用户删照片就断链 |
| 图片输入 | `PhotosPicker` + `UIImagePickerController`(相机) | 自拍杆式"拍完即入"最高频，相机路径必须是最短的 |
| 相机实时抠图 | **v1 不做**；M3 起用 VisionKit `ImageAnalyzer` | 已定：v1 保留原图，录入流程越短越好。VisionKit 是 iOS 自带、免费、离线，将来加不引入新依赖 |
| 天气 | v1 **手动输入/预设**；v2 接 **WeatherKit** 或 **Open-Meteo** | 已定：**暂不买 $99/年开发者账号**，先只跑模拟器，所以 WeatherKit 现在用不了 |
| 最低版本 | **iOS 18.0** | 与 RSSReader 一致；SwiftData 成熟、`#Predicate` 的 `contains` 够用 |
| 依赖 | **零第三方依赖** | SPM 那套坑（pbxproj 手改）不必再踩一遍 |
| 工程生成 | **XcodeGen**（本机已装 2.45.4） | 你在 RSSReader 上被 pbxproj 手工编辑坑过（`notes/ios/xcode-pbxproj-editing-pitfalls.md`）。XcodeGen 用声明式 `project.yml` 生成工程，加文件零冲突 |
| 交付方式 | 先只跑**模拟器** | 已定：暂不买开发者账号。真机要装的话，免费证书每 7 天重装一次 |
| Bundle ID | `com.chuxinchen.ioscloth` | 沿用你 `com.chuxinchen.*` 命名空间 |
| 并发 | Swift Concurrency（`actor` + `@MainActor`） | 图片压缩/抠图放后台，主线程只做 UI |

---

## 3. 数据模型

### 3.1 实体总览

```
Clothing（衣物）───────────┐
  ├─ OutfitItem（搭配槽位）─┴─→ Outfit（搭配）
  ├─ WearRecord（穿着记录）
  └─ LaundryStatus（收纳/洗涤，用枚举字段，不单独建表）
```

### 3.2 Clothing（核心实体）

```swift
import SwiftData
import Foundation

enum ClothingCategory: String, Codable, CaseIterable, Identifiable {
    case top          // 上衣：T恤/衬衫/卫衣/针织
    case bottom       // 下装：裤/裙
    case outerwear    // 外套：夹克/大衣/羽绒
    case dress        // 连衣裙（自带上下身）
    case shoes
    case bag
    case accessory    // 帽/围巾/腰带/首饰
    case underwear
    case sportswear
    var id: String { rawValue }
}

enum Season: String, Codable, CaseIterable, Identifiable {
    case spring, summer, autumn, winter
    var id: String { rawValue }
}

enum ClothingStatus: String, Codable {
    case inUse        // 在穿
    case stored       // 已收纳（换季）
    case toDonate     // 待处理/断舍离
    case lent         // 借出
}

enum StyleTag: String, Codable, CaseIterable, Identifiable {
    case commute      // 通勤
    case casual       // 休闲
    case sporty       // 运动
    case formal       // 正式/宴会
    case date         // 约会
    case home         // 居家
    var id: String { rawValue }
}

@Model
final class Clothing {
    var id: UUID = UUID()
    var name: String = ""

    // —— 分类 ——
    var categoryRaw: String = ClothingCategory.top.rawValue
    var subcategory: String = ""          // 自由文本：T恤 / 阔腿裤 / 风衣

    // —— 季节与温度（核心筛选维度）——
    // 用 rawValue 数组而非 [Season]：SwiftData 的 #Predicate 不支持自定义 Codable 数组
    var seasonRaws: [String] = []
    var tempMin: Double = 15              // 适合的最低气温 ℃
    var tempMax: Double = 30              // 适合的最高气温 ℃
    var isLayerable: Bool = false         // 可叠穿（打底、开衫、薄外套）

    // —— 外观 ——
    var colorName: String = ""
    var colorHex: String = ""             // 用于按色筛选 / 之后的自动取色
    var pattern: String = ""              // 纯色/条纹/格纹/印花
    var material: String = ""             // 棉/羊毛/真丝/聚酯
    var styleRaws: [String] = []

    // —— 图片：只存相对文件名，文件在沙盒 ——
    var imageFile: String = ""            // Images/<uuid>.jpg
    var thumbFile: String = ""            // Thumbs/<uuid>.jpg
    var cutoutFile: String = ""           // Cutouts/<uuid>.png（抠白底，可空）
    var brand: String = ""
    var price: Double?
    var purchaseDate: Date?
    var note: String = ""

    // —— 状态与推荐信号 ——
    var statusRaw: String = ClothingStatus.inUse.rawValue
    var isFavorite: Bool = false
    var wearCount: Int = 0
    var lastWorn: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    // —— 搭配冲突（"这两件别一起穿"）——
    var avoidItemIDsRaw: [String] = []

    // 计算属性负责类型安全，不参与持久化
    var category: ClothingCategory { get set }
    var seasons: [Season] { get set }
    var styleTags: [StyleTag] { get set }
    var status: ClothingStatus { get set }
    var avoidItemIDs: [UUID] { get set }
}
```

**设计要点**

- `seasonRaws` / `styleRaws` 存 `String` 数组而不是枚举数组，是给 `#Predicate` 让路 —— 这是 SwiftData 目前最实际的约束。
- `tempMin/tempMax` 用 `Double`：支持 `0～15`、`-5～8` 这种区间。**一件衣服只能填一个区间**，但可以多选季节，覆盖"秋季外套也能在初冬穿"。
- `wearCount` / `lastWorn` 是**推荐算法的燃料**，从第一天就开始攒。

### 3.3 Outfit 与 OutfitItem

```swift
enum OutfitSlot: String, Codable {
    case top, bottom, outerwear, dress, shoes, bag, accessory
}

@Model
final class Outfit {
    var id: UUID = UUID()
    var name: String = ""                 // "周三通勤"
    var styleRaws: [String] = []
    var seasonRaws: [String] = []
    var tempMin: Double = 15              // 由成员衣物推导
    var tempMax: Double = 25
    var isFavorite: Bool = false
    var rating: Int = 0                   // 0–5，可选
    var wearCount: Int = 0
    var lastWorn: Date?
    var imageFile: String = ""            // 可选：整套合影（老婆更认这种）
    var note: String = ""
    var createdAt: Date = Date()
    var isGenerated: Bool = false         // 来自推荐 vs 手动

    @Relationship(deleteRule: .cascade, inverse: \OutfitItem.outfit)
    var items: [OutfitItem] = []
}

@Model
final class OutfitItem {
    var id: UUID = UUID()
    var slotRaw: String = OutfitSlot.top.rawValue
    var clothing: Clothing?               // 衣物删除时置空，不连带删搭配
    var outfit: Outfit?
}
```

> `Clothing` 删除时搭配不删（只留空槽）—— 因为搭配记录的是"当时的决定"，
> 比衣物本身更值得保留。如果你想反过来（删衣服就删搭配），改 `Clothing` 侧的 `deleteRule` 即可。

### 3.4 WearRecord（穿着记录）

```swift
@Model
final class WearRecord {
    var id: UUID = UUID()
    var date: Date = Date()
    var outfit: Outfit?
    var clothingIDsRaw: [String] = []     // 单件穿也记
    var weatherTemp: Double?
    var weatherCondition: String = ""
    var feedback: Int = 0                 // −1 太冷 / 0 刚好 / +1 太热 ← 校准温度区间的依据
}
```

**这是整个设计里最有复利价值的一张表**：积累几十条 `feedback` 后，就能自动校准某件衣服
标称的 `tempMin/tempMax`（"你标 0–10°C，但连续 3 次 8°C 穿它说太热 → 建议改成 0–6°C"）。
v1 只记录不校准，v2 再有数据可用。

---

## 4. 推荐算法（v1 版：规则 + 打分）

> 原则：**可解释、可信、可干预**。绝不用 AI 生成不存在的搭配 —— 每天推荐没有的衣服会瞬间毁掉信任。

### 4.1 输入

| 输入 | 来源 |
|---|---|
| 目标温度 `T` | 手动输入 / 预设 / （v2）天气 API |
| 季节 `S` | 手动 / 由月份+温度推断 |
| 场景 | StyleTag 多选（默认"通勤 + 休闲"） |
| 候选池 | `status == .inUse` 且（季节命中 或 温度区间覆盖 `T ± 3`） |

### 4.2 打分（0–100）

```swift
struct ScoredItem {
    let clothing: Clothing
    let score: Double
    let reason: String        // "匹配冬季 · 适配 −5~10°C · 近 7 天未穿"
}

func score(_ item: Clothing, temp: Double, season: Season, styles: [StyleTag]) -> ScoredItem {
    // 1) 季节：命中 35 分；未命中但温度覆盖，记 12 分（过渡季的衣服）
    let seasonScore = item.seasons.contains(season) ? 35.0
                    : (item.tempMin <= temp + 3 && item.tempMax >= temp - 3 ? 12.0 : 0.0)

    // 2) 温度：落在区间内 45 分，区间外按 ℃ 衰减（每 1°C 扣 6 分，最低 0）
    let gap = temp < item.tempMin ? item.tempMin - temp
            : temp > item.tempMax ? temp - item.tempMax : 0
    let tempScore = max(0, 45 - gap * 6)

    // 3) 场景：交集 × 10（最多 20）
    let styleScore = min(20.0, Double(Set(item.styleRaws).intersection(styles.map(\.rawValue)).count) * 10)

    // 4) 新鲜度：近 7 天穿过的扣分，避免永远推荐同几件
    var freshness = 0.0
    if let last = item.lastWorn {
        let days = Calendar.current.dateComponents([.day], from: last, to: .now).day ?? 999
        freshness = days < 3 ? -20 : (days < 7 ? -10 : (days > 30 ? 8 : 0))
    }

    // 5) 偏好：收藏 +5，轻微随机 ±3（让"再来一套"真的有变化）
    let bonus = (item.isFavorite ? 5.0 : 0.0) + Double.random(in: -3...3)

    let total = seasonScore + tempScore + styleScore + freshness + bonus
    return ScoredItem(clothing: item, score: total, reason: explain(item, season, temp))
}
```

### 4.3 组装一套搭配

```
1. 选主结构（按温度）
   T ≥ 24°C  → [dress] 或 [top + bottom]
   12–24°C   → [top + bottom]（+ 可选 outerwear）
   T < 12°C  → [top + bottom + outerwear]，outerwear 必须
2. 每个槽位：按分数加权随机取 Top-K（K=3），
   - top/bottom 从 4 个候选取 3 个组合
   - 若该槽位的最高分是「可叠穿」项且 T 在区间边缘 → 追加一件中层（提高容错）
3. 冲突过滤：剔除出现在 avoidItemIDs 里的组合；同色同材质不做限制（v1 不管，避免过度聪明）
4. 输出 3 套，每套带 reason 文案
5. 用户点「换一套」→ 从剩余组合里再抽，同一 session 内不重复
6. 「就这套」→ 存 Outfit(isGenerated: true) + 写 WearRecord
```

### 4.4 可解释文案（信任感的来源）

```
这套为什么推荐：
· 黑色羊毛大衣   匹配冬季 · 适配 −5~10°C · 近 12 天未穿
· 米色高领毛衣   可叠穿 · 适配 0~15°C
· 深灰直筒裤     匹配冬季 · 适配 −5~12°C
今天 12°C，羽绒偏热、风衣偏薄，所以选中这件大衣。
```

---

## 5. 图片与录入流水线

### 5.1 存储布局

```
<App沙盒>/Documents/
  Images/<uuid>.jpg      主图，长边 1600px，JPEG q0.8（约 150–300 KB/件）
  Thumbs/<uuid>.jpg      缩略图，长边 400px（约 25 KB/件）
  Cutouts/<uuid>.png     抠白底 PNG（可选，约 200 KB）
  Backups/wardrobe-YYYYMMDD.json   结构化数据导出
```

> **为什么不用 `@Attribute(.externalStorage)`**：它确实把 Blob 挪出主库，但你无法单独重建缩略图、
> 无法单独替换抠图版本、迁移时也不能只搬结构不搬图。自己管文件名，代价是多写 40 行
> `ImageStore`，换来的是完全可控。

容量估算：300 件 × (300+25) KB ≈ **100 MB**，1000 件 ≈ 330 MB。可接受。

```swift
actor ImageStore {
    func save(_ image: UIImage, id: UUID) async throws -> (main: String, thumb: String)
    func image(named: String) -> UIImage?
    func delete(_ names: [String])
    func orphanedFiles(knownNames: Set<String>) -> [String]   // 体检用
}
```

### 5.2 录入流程（第一优先级优化的地方）

```
[+] → 相机 / 相册
     ↓ 拍照
  裁切框（默认居中，一拉即可）
     ↓
  「要抠白底吗？」  → VisionKit ImageAnalyzer 当场处理（<1s）
     ↓
  录入表单（全部有默认值，能直接保存）
  ┌────────────────────────────────────────┐
  │ [预览图]  季节: 春 ○ 夏 ○ 秋 ● 冬 ●    │  ← 芯片单选/多选，一键
  │           温度: 8 ℃  ──●──────  20 ℃   │  ← 双滑块，默认继承上一件
  │           分类: 外套 ▾  子类: 大衣     │
  │           颜色: 黑 ▾   场景: 通勤 ✓    │
  │           名称: 黑色羊毛大衣           │  ← 可空，自动生成"外套·黑色"
  └────────────────────────────────────────┘
        [ 批量继续 ]        [ 保存 ]
```

**降低录入成本的具体手段**（这是项目成败关键）：

1. **"批量继续"模式**：保存后表单**不清空**季节/温度/场景，直接回到相机。同一季节的衣服连续拍，每件只需 1 次拍照 + 1 次保存。
2. **继承上一件**：温度区间默认沿用上一件（同一季的衣服通常相近）。
3. **可空字段**：名称、品牌、价格、材质全可空。**v1 允许"只有图 + 分类 + 季节"就跑通全流程**，细节慢慢补。
4. **两阶段录入**：先"拍照 + 分类"批量导入全部衣物（1 小时），之后按需补温度。App 提供"待完善"清单页，刷 10 秒补几件。
5. **省电/省事模式**：支持从相册批量多选（她可能早就拍过衣柜照）。

---

## 6. UI 信息架构

```
TabView
├── 1. 衣柜          「我有什么」
│     ├─ 顶部筛选条：分类胶囊 + 季节 + 温度区间 + 状态（在穿/收纳）
│     ├─ LazyVGrid 图墙（缩略图，长按多选批量改状态）
│     ├─ 搜索（名称/子类/颜色/品牌）
│     └─ 详情页 → [编辑] [和它搭一套] [加入今日搭配] [标记收纳]
│
├── 2. 搭配          「今天穿什么」  ← 主入口，默认 Tab
│     ├─ 天气条：12°C 多云 · 冬季（可手动改）
│     ├─ [给我搭一套]
│     ├─ 3 张搭配卡（纵向）：成员缩略图 + 理由 + [换一套] [就这套]
│     └─ [自己搭] → 手动搭配编辑器（分槽位选衣物）
│
├── 3. 我的搭配      「存下来的」
│     ├─ 收藏搭配列表（可按温度/季节/评分筛）
│     ├─ 穿着记录时间线
│     └─ 数据体检：未归类的 / 缺温度的 / 长期没穿的 / 幽灵图片
│
└── 4. 设置
      ├─ 温度预设档（炎热/热/舒适/凉/冷/严寒 的 ℃ 阈值）
      ├─ 分类与子类管理
      ├─ 备份 / 导出 JSON · 从 JSON 导入
      ├─ 图片存储占用 + 清理
      └─ 关于
```

**交互原则**

- **默认 Tab 是「搭配」**，不是「衣柜」—— 高频场景是早上出门，不是整理。
- 每一步都给**默认值**，任何页面都不允许"必须填完才能下一步"。
- 破坏性操作（删除衣物、清空数据）二次确认；其余操作不要弹窗。

---

## 7. 工程结构与里程碑

### 7.1 目录结构

```
ios-cloth/
├── project.yml                  # XcodeGen 声明（🔸 若不用 XcodeGen 则删）
├── DESIGN.md                    # 本文
├── ioscloth/
│   ├── App/          iosclothApp.swift · RootTabView.swift
│   ├── Models/       Clothing.swift · Outfit.swift · WearRecord.swift · Enums.swift
│   ├── Services/     WardrobeStore.swift · ImageStore.swift · OutfitEngine.swift
│   │                 WeatherService.swift(v2) · BackupService.swift
│   ├── Features/
│   │   ├── Closet/   ClosetGridView · ClothingDetailView · ClothingEditView · FilterBar
│   │   ├── Capture/  CaptureFlowView · CameraPicker · CropView · CutoutService
│   │   ├── Outfit/   OutfitTabView · OutfitCardView · OutfitBuilderView
│   │   └── Settings/ SettingsView · DataHealthView · BackupView
│   ├── DesignSystem/ Theme.swift · Chips.swift · TempRangeSlider.swift
│   └── Resources/    Assets.xcassets · Info.plist
└── iosclothTests/    OutfitEngineTests.swift · ScoringTests.swift
```

### 7.2 里程碑（每个都有可验收标准）

| 阶段 | 内容 | 验收标准 | 预估 |
|---|---|---|---|
| **M0 地基** | 建工程、XcodeGen、Team/签名、跑通空壳到模拟器 | `xcodebuild ... build` 出现 `BUILD SUCCEEDED`，`simctl launch` 出现 App | 0.5 天 |
| **M1 数据层** | SwiftData 模型 + `ImageStore` + 单元测试 | 能创建/查询/删除衣物；图片落盘、缩略图生成；测试通过 | 1.5 天 |
| **M2 录入** | 拍照/相册 + 裁切 + 表单 + **批量继续** | 连续录 20 件耗时 < 10 分钟（自己掐表） | 2–3 天 |
| **M3 衣柜** | 图墙 + 筛选（分类/季节/温度/状态）+ 搜索 + 详情 | 按"冬季 + 10°C"能筛出正确子集 | 2 天 |
| **M4 推荐** | `OutfitEngine` + 搭配 Tab + 理由文案 + 换一套 | 3 个不同温度下各出 3 套，且每套都物理可穿 | 2–3 天 |
| **M5 收藏与记录** | 存搭配 + 穿着记录 + 反馈（太冷/太热） | 「就这套」写入 Outfit + WearRecord | 1 天 |
| **M6 自用上线** | 装到老婆手机（免费证书 7 天 / 付费账号 1 年）+ JSON 备份导出 | 真机连续用 7 天不崩、数据不丢 | 1 天 |
| **v2** | 天气 API 自动带出温度 · 抠图批量重跑 · 温度区间自校准 · 数据体检自动化 | — | 之后 |
| **v3** | CloudKit 双端同步 · 衣柜统计（"你有 14 件黑上衣"）· 场景化胶囊（出差 3 天打包清单） | — | 之后 |

**总计：v1 约 11–13 个工作日**，按每天 2 小时业余投入 ≈ 3–4 周。

---

## 8. 关键决策记录（ADR）

| # | 决策 | 理由 | 复审条件 |
|---|---|---|---|
| D1 | 用 SwiftData，不用 UserDefaults | 上千条记录 + 多维查询；UserDefaults 全量反序列化会卡 | 衣物 > 5000 件且出现性能问题 |
| D2 | 图片存文件不存库 | 备份/迁移/缩略图/抠图版本都需独立控制 | 无 |
| D3 | 季节**多选** + 温度**区间** | 单选用户会把过渡季的衣服筛丢，这是需求原话的必然推论 | 无 |
| D4 | 引入「可叠穿 / 多层」概念 | 真实穿搭是分层的（打底+毛衣+外套），算法必须能表达 | 无 |
| D5 | v1 不接天气 API，先手动 | 先验证算法价值，再解决数据来源；避免被 WeatherKit 付费账号卡住 | M5 完成后立刻做，因为每天手输温度会烦 |
| D6 | v1 不做自动抠白底以外的 AI（不生成搭配、不识别款式） | 推荐不存在的衣服会摧毁信任；识别准确率不够时是负价值 | 抠图/分类模型可用且离线 |
| D7 | 引擎用纯函数 + 可解释打分 | 必须能回答"为什么推荐这件"，也方便写单测 | 无 |
| D8 | **XcodeGen** 而非手改 pbxproj | 你在 RSSReader 上被 pbxproj 坑过；声明式加文件无冲突；本机已安装 | 无 |
| D9 | 零第三方依赖 | 减少构建脆弱性；本项目不需要 | 出现确实无法自研的需求 |
| D10 | Bundle ID `com.chuxinchen.ioscloth` | 沿用既有命名空间 | 上架前若要换名 |

---

## 9. 风险与缓解

| 风险 | 影响 | 缓解 |
|---|---|---|
| **录入成本高**（最大风险） | 录到一半放弃 → 项目死 | §5.2 的批量继续 / 继承默认值 / 可空字段 / 两阶段录入；M2 用"20 件 < 10 分钟"做硬指标 |
| 数据丢失（手机丢了/重装） | 全部录入白费 | v1 就做 JSON 导出 + AirDrop 备份；v2 上 CloudKit |
| 温度区间标不准 → 推荐不准 | 老婆不信 App | 用 `WearRecord.feedback`（太冷/太热）攒数据后自校准；UI 上永远给"换一套"的兜底 |
| 天气 API 门槛 | v2 卡住 | 先用免费 Open-Meteo；不行就城市级天气 + 手动覆盖 |
| 图片占空间 | 手机爆 | 长边 1600px + q0.8；设置页显示占用并支持"仅保留缩略图"降级 |
| 免费证书 7 天过期 | 老婆手机上的 App 打不开 | 要么每年 $99 真机长期用；要么每 7 天重装一次（自用可忍，但要提前说清）|
| SwiftData 迁移 | 迭代改模型时旧数据读不出 | v1 起就用 `SchemaMigrationPlan` + `VersionedSchema`，别等出事 |
| 隐私 | 衣物+照片是私密数据 | 全本地、无网络请求（v2 天气除外）、无统计 SDK；若上架需写隐私政策 |

---

## 10. 附录 A：给 Java 开发者的对照表

> 你有丰富 Java 经验、iOS 储备不足。这个项目里 90% 的概念都能映射到你熟的东西上。

| iOS / Swift 概念 | Java 世界里的对应物 | 差异要点 |
|---|---|---|
| **SwiftData** `@Model` | JPA / Hibernate 的 `@Entity` | 都跑在 SQLite 上。区别：SwiftData 的查询条件写在代码里（`#Predicate`），不是 JPQL 字符串 |
| `ModelContainer` | `EntityManagerFactory` / `DataSource` | 应用启动时建一次 |
| `ModelContext` | `EntityManager`（一级缓存 + 事务） | `context.save()` ≈ `em.flush()` |
| `@Query` | Spring Data 的 `findByXxx` | 数据变了 UI 自动刷新，不用手写监听 |
| **UserDefaults** | `application.properties` | 只适合存几个开关。RSSReader 用它存文章列表是历史包袱，我们不用 |
| **XcodeGen** `project.yml` | **Maven 的 `pom.xml` / Gradle 的 `build.gradle`** | `.xcodeproj` 相当于手改的 IDE 工程文件（`.idea/`），多人/AI 协作必然冲突 —— 这就是为什么用它 |
| `xcodebuild` | `mvn package` / `gradle build` | 命令行构建 |
| Swift Package Manager (SPM) | Maven / Gradle 依赖管理 | 本项目零第三方依赖 |
| `actor` + `async/await` | 虚拟线程 + `CompletableFuture` | Swift 的 `actor` ≈ 单线程串行化的对象，天然免锁 |
| `@MainActor` | `@UiThread` / Swing EDT | UI 只能在主线程改 |
| `XCTest` | JUnit | 写法几乎一样：`func testXxx()` |
| `Codable` | Jackson / Gson | 协议式（类似 interface 自动实现），不用注解 |
| `enum` with `rawValue` | Java `enum` | Swift 枚举可以带关联值，比 Java 强很多 |
| **VisionKit `ImageAnalyzer`** | 一个免费的本地图像处理库 | 相当于把"抠图/主体识别"做成 JDK 自带，不联网不收费 |
| **WeatherKit** | 一个收费的天气 SaaS | ⚠️ 要 Apple 开发者账号（$99/年）。所以 v1 不接它 |
| **CloudKit** | Firebase / 自建云同步 | ⚠️ 同样要 $99/年账号。所以 v1 纯单机 |
| 免费证书 7 天 | — | ⚠️ 没有 $99/年账号时，装到真机上的 App **每 7 天要重装一次** |
| Xcode | IntelliJ IDEA | 图形化 IDE，能跑模拟器 |
| 模拟器 (`simctl`) | 类似本地 Docker 跑集成测试 | 不用真机就能开发 UI |

**本项目你只需要知道这些就够用了**：数据层是 JPA 那一套，工程配置是 pom.xml 那一套，
图片处理是"JDK 自带"，天气和云同步是"要花钱的第三方服务"所以先不接。

---

## 11. 已确认的决策

| 问题 | 结论 | 影响 |
|---|---|---|
| 最低 iOS 版本 | **iOS 18.0** | 与 RSSReader 一致，SwiftData 与后续 VisionKit 都能用 |
| Apple 开发者账号 | **暂不购买** | 只有模拟器，不装真机；天气用**手动输入**，无 CloudKit 同步 |
| 抠白底 | **v1 不做** | 录入流程更短；M3 起再考虑用免费离线的 VisionKit |
| 工程管理 | **XcodeGen** | `project.yml` 是唯一事实来源，`.xcodeproj` 不进版本库 |
| 天气数据 | **手动输入 + 滑块预设** | v2 再评估（免费 Open-Meteo 或买了账号之后的 WeatherKit） |
| 录入节奏 | 暂定「使用中渐进录入」 | M2 会把「批量继续」做成主路径，两种节奏都支持 |

**仍然待定（不阻塞开发）**：

1. App 显示名 —— 现在暂用「衣橱」（`project.yml` 里的 `INFOPLIST_KEY_CFBundleDisplayName`），随时可改。
2. 她手机上要不要装 —— 要装就需要每 7 天重装一次，或者买账号。

---

## 12. 下一步

**已完成**：M0 工程地基、M1 数据层（56 个单测全绿）。见 §0.5。

**接下来按这个顺序做**：

1. **M2 录入流程**（下一步，优先级最高）—— 相机拍照 + 裁切 + 「批量继续」+ 继承上一件的季节/温度。
   验收硬指标：**连续录 20 件衣物 < 10 分钟**（自己掐表）。这是全项目成败关键，
   因为录不进去就等于这个 App 不存在。
2. **M3 补完衣柜** —— 温度区间筛选、长按多选批量改状态（换季收纳）、衣物详情页。
3. **M4 补完推荐** —— 支撑「打底 + 毛衣 + 外套」的多层搭配（要改 `OutfitDraft` 与 `OutfitItem`
   的数据结构，见 `OutfitEngine.swift` 里的 TODO）。
4. **M5** —— 穿着记录 UI + 「太冷 / 刚好 / 太热」反馈。
5. **M6** —— 决定要不要上真机。

**知识沉淀**：等设计稳定、代码跑起来之后，把本项目的环境与决策落进知识库
`projects/ios-cloth/`（用 `knowledge-kb` 的 kb-curator 流程），与 `projects/rssreader/` 并列。
