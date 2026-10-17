import SwiftUI
import UIKit

/// 裁切照片：中间一个正方形取景框，图片在下面缩放平移，框外压暗。
///
/// 交互目标是最短路径：打开就已经居中放好、放大到刚好填满取景框，
/// 用户直接点「完成」就行。想微调就双指缩放、拖动；想改框大小就拖四角。
///
/// ## 三个关键设计（都踩过坑，改之前先读）
///
/// **1. 屏幕上永远只用缩略图。**
///    相机原图动辄 4000×3000。直接交给界面绘制，每个手势帧都要重采样一张
///    1200 万像素的图，表现就是「进裁切页慢、拖动卡」。
///    所以先生成一张长边 1200px 的预览图（在主线程外），界面只画它；
///    点「完成」时再把裁切矩形按比例映射回原图，切出全分辨率结果。
///
/// **2. 屏幕上只有一张图。**
///    曾经试过「框内滚动视图 + 框外再画一张同变换的图」，结果两张必然错位：
///    `UIScrollView` 内部的实时缩放，SwiftUI 的重绘永远追不上。
///    现在靠 `CropScrollView` 的 `clipsToBounds = false`，让**同一张图**溢出到框外，
///    再由 `CropOverlay` 压暗。见 `ZoomableCropView` 顶部注释。
///
/// **3. 缩放平移交给 UIKit 的 `UIScrollView`，不自己写手势。**
///    `MagnifyGesture` 的 `startAnchor` 报的是被缩放后的图片坐标系，
///    拿它当容器坐标做锚定，补偿量全错 —— 表现是「无论捏哪里取景框都往同一方向漂」。
struct ImageCropper: View {
    let image: UIImage
    /// 回调裁切结果
    let onDone: (UIImage) -> Void
    /// 取消
    let onCancel: () -> Void

    /// 预览图长边像素。1200 是为了在 3× 屏上画取景框仍清晰，同时小到足以让手势流畅。
    static let previewMaxDimension: CGFloat = 1200
    /// 取景框占可用短边的初始比例
    static let cropSideRatio: CGFloat = 0.72
    /// 取景框边长下限
    static let minCropSide: CGFloat = 180
    /// 取景框边长上限（大屏上不至于占满整屏）
    static let maxCropSide: CGFloat = 520
    /// 四角拖拽手柄的直径
    static let handleDiameter: CGFloat = 34

    /// 原图（方向已拍平）。裁切结果取自它，所以不损失分辨率。
    @State private var original: UIImage?
    /// 屏幕上实际绘制的缩略图
    @State private var preview: UIImage?
    /// 取景框边长（可拖动四角调整）
    @State private var cropSide: CGFloat = 0
    /// 拖拽手柄按下时的边长，用来算增量
    @State private var dragStartSide: CGFloat?
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
            GeometryReader { geometry in
                let side = cropSide > 0
                    ? cropSide
                    : Self.clampedCropSide(Self.cropSide(fitting: geometry.size), available: geometry.size)
                let window = CGRect(
                    x: (geometry.size.width - side) / 2,
                    y: (geometry.size.height - side) / 2,
                    width: side,
                    height: side
                )

                ZStack {
                    Color.black

                    // 图片页：frame 就是取景框，但内容溢出（clipsToBounds = false），
                    // 所以框内外是同一张图，缩放时不会错位。
                    ZoomableCropView(
                        image: preview,
                        onTransformChange: { transform = $0 },
                        onFit: { fitScale = $0 }
                    )
                    .frame(width: side, height: side)
                    .position(x: window.midX, y: window.midY)

                    // 框外压暗 + 白边 + 三分线（框内透明，透出下面的图片）
                    CropOverlay(cropSide: side)
                        .allowsHitTesting(false)

                    // 四角拖动改框大小
                    resizeHandles(window: window, available: geometry.size)
                }
                .clipped()
                .onAppear {
                    if cropSide == 0 {
                        cropSide = Self.clampedCropSide(
                            Self.cropSide(fitting: geometry.size),
                            available: geometry.size
                        )
                    }
                }
                .onChange(of: geometry.size) { _, newValue in
                    cropSide = Self.clampedCropSide(cropSide, available: newValue)
                }
            }

            VStack(spacing: 2) {
                Text("双指缩放，单指拖动；拖四角可改框大小。直接点「完成」也行。")
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

    // MARK: - 四角手柄

    private func resizeHandles(window: CGRect, available: CGSize) -> some View {
        ZStack {
            ForEach(Array(Self.Corner.allCases.enumerated()), id: \.offset) { _, corner in
                Circle()
                    .fill(Color.white.opacity(0.9))
                    .frame(width: Self.handleDiameter, height: Self.handleDiameter)
                    .overlay {
                        Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 1)
                    }
                    .position(
                        x: window.midX + corner.dx * window.width / 2,
                        y: window.midY + corner.dy * window.height / 2
                    )
                    .gesture(resizeGesture(corner: corner, available: available))
                    .accessibilityLabel("调整取景框大小")
            }
        }
    }

    private func resizeGesture(corner: Self.Corner, available: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { value in
                let start = dragStartSide ?? cropSide
                if dragStartSide == nil { dragStartSide = start }

                // 框始终居中：角往外拖 t，边长增加 t（两个方向各 t/2）
                let delta = value.translation.width * corner.dx + value.translation.height * corner.dy
                cropSide = Self.clampedCropSide(start + delta, available: available)
            }
            .onEnded { _ in
                dragStartSide = nil
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

// MARK: - 取景框尺寸与裁切换算（纯函数，便于单测）

extension ImageCropper {
    /// 拖拽手柄的四个角。`dx` / `dy` 是它相对中心的方向。
    enum Corner: CaseIterable {
        case topLeading, topTrailing, bottomLeading, bottomTrailing

        var dx: CGFloat {
            switch self {
            case .topLeading, .bottomLeading: -1
            case .topTrailing, .bottomTrailing: 1
            }
        }

        var dy: CGFloat {
            switch self {
            case .topLeading, .topTrailing: -1
            case .bottomLeading, .bottomTrailing: 1
            }
        }
    }

    /// 取景框的初始边长：占可用短边的固定比例
    static func cropSide(fitting available: CGSize) -> CGFloat {
        let shortSide = min(available.width, available.height)
        guard shortSide > 0 else { return minCropSide }
        return shortSide * cropSideRatio
    }

    /// 把边长夹到可选范围内：不小于下限，且不超过「可用空间减去手柄直径」。
    ///
    /// 减去手柄直径是为了让四角手柄**始终完整可见** —— 否则框拖到最大时
    /// 手柄会被屏幕边缘切掉一半，很难再拖回来。
    /// 拖动四角、以及窗口尺寸变化都会走这里。
    static func clampedCropSide(_ value: CGFloat, available: CGSize) -> CGFloat {
        let usable = min(available.width, available.height) - handleInset * 2
        let limit = min(usable, maxCropSide)
        guard limit >= minCropSide else { return max(usable, 0) }
        return min(max(value, minCropSide), limit)
    }

    /// 手柄留出的边距（手柄半径）
    static let handleInset: CGFloat = handleDiameter / 2

    /// 取景框在**图片像素**里对应的边长。
    ///
    /// 取景框固定不动、图片被缩放，所以取景框覆盖的屏幕宽度
    /// 对应图片里的 `cropSide / zoomScale` 个点。
    static func cropSideInImage(cropSide: CGFloat, zoomScale: CGFloat, fitScale: CGFloat) -> CGFloat {
        guard cropSide > 0, fitScale > 0 else { return 0 }
        let effective = max(zoomScale, fitScale)
        let side = cropSide / effective
        return side.isFinite ? side : 0
    }

    /// 取景框在**图片像素**里对应的矩形。
    ///
    /// 三个量全部由 `UIScrollView` 直接给出，这里只做一次线性换算：屏幕中心 → 图片坐标。
    ///
    /// 推导：内容坐标 `c` 在滚动视图上的位置是 `c - contentOffset`，
    /// 所以可视区中心（`viewportSize / 2`）对应的图片坐标是
    /// `(viewportSize / 2 + contentOffset) / zoomScale`。
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
            .fill(Color.black.opacity(0.6))
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
