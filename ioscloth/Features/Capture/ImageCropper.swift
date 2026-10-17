import SwiftUI
import UIKit

/// 裁切照片：中间一个正方形取景框，图片在下面缩放平移。
///
/// 交互目标是最短路径：打开就已经居中放好、放大到刚好填满取景框，
/// 用户直接点「完成」就行。想微调就双指缩放、拖动。
///
/// ## 三个关键设计（都踩过坑，改之前先读）
///
/// **1. 屏幕上永远只用缩略图。**
///    相机原图动辄 4000×3000。直接交给界面按取景框大小绘制，每个手势帧都要
///    重采样一张 1200 万像素的图，表现就是「进裁切页慢、拖动卡」。
///    所以先生成一张长边 1200px 的预览图（在主线程外），界面只画它；
///    点「完成」时再把裁切矩形按比例映射回原图，切出全分辨率结果。
///
/// **2. 缩放平移交给 UIKit 的 `UIScrollView`，不自己写手势。**
///    `MagnifyGesture` 的 `startAnchor` 报的是被缩放后的图片坐标系，
///    拿它当容器坐标做锚定，补偿量全错 —— 表现是「无论捏哪里取景框都往同一方向漂」。
///
/// **3. 滚动视图必须铺满整块可用区域，取景框只是画在它上面的一层。**
///    如果滚动视图缩在取景框那么大的一块里，「滚动夹住的边界」和
///    「取景框的边界」就不是同一条线，贴着原图边缘的内容永远拖不进框里。
///    两者同区之后，拖到头的时刻正好是该方向的内容贴住取景框边。
struct ImageCropper: View {
    let image: UIImage
    /// 回调裁切结果
    let onDone: (UIImage) -> Void
    /// 取消
    let onCancel: () -> Void

    /// 预览图长边像素。1200 是为了在 3× 屏上画取景框仍清晰，同时小到足以让手势流畅。
    static let previewMaxDimension: CGFloat = 1200
    /// 取景框占可用短边的比例
    static let cropSideRatio: CGFloat = 0.88
    /// 取景框边长下限。太小的话放大后能看到的范围太窄，很难对准细节。
    static let minCropSide: CGFloat = 240
    /// 取景框边长上限（iPad 上不至于占满整屏）
    static let maxCropSide: CGFloat = 520

    /// 原图（方向已拍平）。裁切结果取自它，所以不损失分辨率。
    @State private var original: UIImage?
    /// 屏幕上实际绘制的缩略图
    @State private var preview: UIImage?
    /// 取景框边长（由可用空间算出）
    @State private var cropSide: CGFloat = 300
    /// 当前缩放平移（由 UIKit 上报的原始量）
    @State private var transform = CropTransform.identity
    /// 「刚好填满取景框」的基准缩放（由 UIKit 上报）
    @State private var fitScale: CGFloat = 0

    var body: some View {
        Group {
            if let preview {
                editor(preview: preview)
            } else {
                ProgressView("正在准备…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .task {
            guard original == nil else { return }
            // 拍平方向 + 生成预览都放主线程外：这是「进裁切页慢」的根源
            let prepared = await Task.detached(priority: .userInitiated) { () -> UIImage in
                image.upright()
            }.value
            original = prepared
            preview = prepared.resized(maxDimension: Self.previewMaxDimension)
        }
        .background(Color.black)
        .navigationTitle("调整照片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消", action: onCancel)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    // 刻意不 disable：按钮点了必须有反应。
                    // 参数缺失时 `crop` 会退回原图，是可接受的降级，不该堵住主流程。
                    if let original, let preview {
                        onDone(Self.crop(
                            from: original,
                            preview: preview,
                            cropSide: cropSide,
                            transform: transform,
                            fitScale: fitScale
                        ))
                    } else if let original {
                        onDone(original)
                    }
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - 编辑器

    private func editor(preview: UIImage) -> some View {
        VStack(spacing: 16) {
            // 取景框 = 滚动视图 = 同一块区域，逐层收窄：
            //
            //   ZStack                      铺满可用区域，负责画框外压暗
            //     Color.black
            //     CropOverlay(cropSide: side)  只在框外压暗（框内透明，透出下面的图片）
            //     ZoomableCropView             **尺寸 == 取景框**，居中
            //
            // 最后一层必须是和取景框等大的滚动视图：`UIScrollView` 的夹取边界
            // 就是它的 bounds，只有两者重合，图片的上/下/左/右边缘才能精确拖到框边。
            // 之前让滚动视图铺满整屏、取景框只占 88%，于是图片在夹取方向上还能多走
            // 「(视口 − 取景框) / 2」的距离，贴边内容就永远进不了框。
            GeometryReader { geometry in
                let side = Self.cropSide(fitting: geometry.size)
                let windowOrigin = CGPoint(
                    x: (geometry.size.width - side) / 2,
                    y: (geometry.size.height - side) / 2
                )

                ZStack(alignment: .topLeading) {
                    Color.black

                    // 框外也显示同一张图（只是被压暗），这样能看到照片的其余部分，
                    // 方便判断主体在整张照片里的位置。
                    //
                    // 关键在于它必须和框内的图片**共用同一个变换**，
                    // 否则框内外会对不上、看起来像两张不同的图。
                    Image(uiImage: preview)
                        // 必须 resizable：否则 Image 按原始点尺寸绘制（675×1200pt），
                        // frame 只约束布局不缩放内容，框内外就对不上了。
                        .resizable()
                        .interpolation(.medium)
                        .frame(
                            width: preview.size.width * transform.zoomScale,
                            height: preview.size.height * transform.zoomScale
                        )
                        .offset(
                            x: windowOrigin.x - transform.contentOffset.x,
                            y: windowOrigin.y - transform.contentOffset.y
                        )

                    // 框内：可缩放平移的图片，尺寸严格等于取景框（见 ZoomableCropView 注释）
                    ZoomableCropView(
                        image: preview,
                        onTransformChange: { transform = $0 },
                        onFit: { fitScale = $0 }
                    )
                    .frame(width: side, height: side)
                    .position(x: windowOrigin.x + side / 2, y: windowOrigin.y + side / 2)

                    // 框外压暗 + 白边 + 三分线（框内透明，透出下面的图片）
                    CropOverlay(cropSide: side)
                        .allowsHitTesting(false)
                }
                .clipped()
                .onAppear { cropSide = side }
                .onChange(of: side) { _, newValue in cropSide = newValue }
            }

            VStack(spacing: 2) {
                Text("双指缩放，单指拖动。直接点「完成」也行。")
                    .font(.footnote)
                // 让用户（和自己排查问题时）知道最终会存下多大的一块。
                // 它同时是最好的调试手段：派生量不变就说明某个输入没接进公式。
                Text(resultSizeHint)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .foregroundStyle(.secondary)
        }
    }

    /// 最终裁切结果的像素尺寸提示，例如「将保存 1024 × 1024 像素」
    private var resultSizeHint: String {
        guard let preview, let original, fitScale > 0 else { return " " }
        let sideInPreview = Self.cropSideInImage(
            cropSide: cropSide,
            zoomScale: transform.zoomScale,
            fitScale: fitScale
        )
        let sideInOriginal = Self.scaleToOriginal(
            sideInPreview,
            previewSize: preview.size,
            originalSize: original.size
        )
        guard sideInOriginal > 1 else { return " " }
        return "将保存 \(Int(sideInOriginal)) × \(Int(sideInOriginal)) 像素"
    }
}

/// `UIScrollView` 当前的变换状态。三个量都是 UIKit 直接给的原始值，不做任何推演。
struct CropTransform: Equatable {
    var zoomScale: CGFloat = 0
    var contentOffset: CGPoint = .zero
    var viewportSize: CGSize = .zero

    static let identity = CropTransform()
}

// MARK: - 裁切换算（纯函数，便于单测）

extension ImageCropper {
    /// 取景框边长：占可用短边的固定比例，并夹在上下限之间。
    ///
    /// 之前写死 340pt，在 iPhone 上显得又小又挤，贴近原图边缘的内容很难塞进去。
    static func cropSide(fitting available: CGSize) -> CGFloat {
        let shortSide = min(available.width, available.height)
        guard shortSide > 0 else { return minCropSide }
        let preferred = min(max(shortSide * cropSideRatio, minCropSide), maxCropSide)
        // 下限也不能突破可用空间：极小屏上取景框比可视区还大会画到屏幕外
        return min(preferred, shortSide)
    }

    /// 取景框在**图片像素**里对应的边长。
    ///
    /// 取景框固定不动、图片被缩放，所以取景框覆盖的屏幕宽度
    /// 对应图片里的 `cropSide / zoomScale` 个点。
    ///
    /// `fitScale` 是「刚好填满取景框」的基准缩放：在它之下不该发生
    /// （`minimumZoomScale` 保证），真发生了就夹住。
    static func cropSideInImage(cropSide: CGFloat, zoomScale: CGFloat, fitScale: CGFloat) -> CGFloat {
        guard cropSide > 0, fitScale > 0 else { return 0 }
        let effective = max(zoomScale, fitScale)
        let side = cropSide / effective
        return side.isFinite ? side : 0
    }

    /// 取景框在**图片像素**里对应的矩形。
    ///
    /// ## 符号坑（我在这里错过两次，用真实滚动视图量出来的）
    ///
    /// `contentOffset` 是**内容原点在滚动视图坐标里的位置**，而内容原点通常是负数：
    /// `contentOffset.y < 0` 意味着内容在屏幕上**往下**走了。
    /// 所以「屏幕位置 → 图片坐标」是
    ///
    ///     图片坐标 = 屏幕位置 − 内容原点 = 屏幕位置 − (−contentOffset) = 屏幕位置 + contentOffset
    ///
    /// 也就是**加号**。写成减号会让取景框朝着用户拖动的反方向偏移两倍 ——
    /// 表现就是「放大后怎么拖都到不了图片边缘」。
    ///
    /// 实测（viewport 387、图片 675×1200、zoom=0.5733 即刚好填满）：
    /// - offset.y = 0   → rect.y = 0…675     居中，正确
    /// - offset.y = −150（内容的极限）→ rect.y = 0…675  上边缘正好贴住框顶
    static func cropRectInImage(cropSide: CGFloat, transform: CropTransform, fitScale: CGFloat) -> CGRect {
        let side = cropSideInImage(
            cropSide: cropSide,
            zoomScale: transform.zoomScale,
            fitScale: fitScale
        )
        guard side > 0, transform.viewportSize.width > 0, transform.viewportSize.height > 0 else {
            return .zero
        }

        let center = CGPoint(
            x: (transform.viewportSize.width / 2 + transform.contentOffset.x) / transform.zoomScale,
            y: (transform.viewportSize.height / 2 + transform.contentOffset.y) / transform.zoomScale
        )

        return CGRect(
            x: center.x - side / 2,
            y: center.y - side / 2,
            width: side,
            height: side
        )
    }

    /// 预览图边长 → 原图对应的边长。两张图等比，按宽度比例线性映射即可。
    static func scaleToOriginal(_ length: CGFloat, previewSize: CGSize, originalSize: CGSize) -> CGFloat {
        guard previewSize.width > 0, originalSize.width > 0 else { return 0 }
        return length * (originalSize.width / previewSize.width)
    }

    /// 从原图切出取景框对应的区域。
    ///
    /// **保证返回一张图**：换算异常时退回整张原图，绝不返回 nil ——
    /// 否则用户点了「完成」会毫无反应，那是最让人困惑的失败方式。
    static func crop(
        from original: UIImage,
        preview: UIImage,
        cropSide: CGFloat,
        transform: CropTransform,
        fitScale: CGFloat
    ) -> UIImage {
        guard let cgImage = original.cgImage else { return original }

        let rectInPreview = cropRectInImage(cropSide: cropSide, transform: transform, fitScale: fitScale)
        guard rectInPreview.width > 1, rectInPreview.height > 1 else { return original }

        let sideInOriginal = scaleToOriginal(
            rectInPreview.width,
            previewSize: preview.size,
            originalSize: original.size
        )
        guard sideInOriginal > 1 else { return original }

        let centerInOriginal = CGPoint(
            x: (rectInPreview.midX / preview.size.width) * original.size.width,
            y: (rectInPreview.midY / preview.size.height) * original.size.height
        )
        let rect = CGRect(
            x: centerInOriginal.x - sideInOriginal / 2,
            y: centerInOriginal.y - sideInOriginal / 2,
            width: sideInOriginal,
            height: sideInOriginal
        ).integral.intersection(CGRect(origin: .zero, size: original.size))

        guard rect.width > 1, rect.height > 1 else { return original }
        guard let cropped = cgImage.cropping(to: rect) else { return original }
        return UIImage(cgImage: cropped, scale: original.scale, orientation: .up)
    }
}

// MARK: - 取景框

/// 固定不动的正方形取景框：**只在框外**压暗 + 白色细边 + 三分线。
///
/// 框内必须完全透明 —— 图片是画在它下面的一层，压暗会挡住图片。
private struct CropOverlay: View {
    let cropSide: CGFloat

    var body: some View {
        ZStack {
            dimming
            border
            thirds
        }
    }

    /// 框外压暗：整块半透明黑，再把中间的正方形抠掉
    private var dimming: some View {
        Rectangle()
            .fill(Color.black.opacity(0.55))
            .reverseMask {
                Rectangle().frame(width: cropSide, height: cropSide)
            }
    }

    private var border: some View {
        Rectangle()
            .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
            .frame(width: cropSide, height: cropSide)
    }

    private var thirds: some View {
        let third = cropSide / 3
        return Path { path in
            for index in 1...2 {
                let position = third * CGFloat(index) - cropSide / 2
                path.move(to: CGPoint(x: position, y: -cropSide / 2))
                path.addLine(to: CGPoint(x: position, y: cropSide / 2))
                path.move(to: CGPoint(x: -cropSide / 2, y: position))
                path.addLine(to: CGPoint(x: cropSide / 2, y: position))
            }
        }
        .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
        .frame(width: cropSide, height: cropSide)
    }
}

private extension View {
    /// 反向遮罩：只在「不是」给定形状的地方生效
    func reverseMask<Mask: View>(@ViewBuilder _ mask: () -> Mask) -> some View {
        self.mask {
            Rectangle()
                .overlay(alignment: .center) {
                    mask().blendMode(.destinationOut)
                }
                .compositingGroup()
        }
    }
}
