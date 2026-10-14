import SwiftUI
import UIKit

/// 裁切照片：中间一个固定正方形取景框，图片在下面缩放平移。
///
/// 交互目标是最短路径：打开就已经居中放好、放大到刚好填满取景框，
/// 用户直接点「完成」就行。想微调就双指缩放、拖动。
///
/// ## 两个关键设计（都踩过坑，改之前先读）
///
/// **1. 屏幕上永远只用缩略图。**
///    相机原图动辄 4000×3000。直接交给界面按 340pt 绘制，每个手势帧都要
///    重采样一张 1200 万像素的图，表现就是「进裁切页慢、拖动卡」。
///    所以先生成一张长边 1200px 的预览图（在主线程外），界面只画它；
///    点「完成」时再把裁切矩形按比例映射回原图，切出全分辨率结果。
///
/// **2. 缩放平移和裁切矩形都交给 UIKit。**
///    自己用 SwiftUI 手势算会踩坐标系坑（见 `ZoomableCropView` 的注释），
///    自己从 `contentOffset` 推裁切矩形也算错过（被单测抓到）。
struct ImageCropper: View {
    let image: UIImage
    /// 回调裁切结果
    let onDone: (UIImage) -> Void
    /// 取消
    let onCancel: () -> Void

    /// 预览图长边像素。1200 是为了在 3× 屏上画 340pt 仍清晰（约 1020px），
    /// 同时小到足以让手势全程流畅。
    static let previewMaxDimension: CGFloat = 1200
    /// 取景框最大边长（正方形：衣服拍出来基本都是竖着的主体）
    static let maxCropSide: CGFloat = 340
    /// 取景框与屏幕边缘的间距
    static let cropSidePadding: CGFloat = 12

    /// 原图（方向已拍平）。裁切结果取自它，所以不损失分辨率。
    @State private var original: UIImage?
    /// 屏幕上实际绘制的缩略图
    @State private var preview: UIImage?
    /// 取景框边长（由可用空间算出）
    @State private var cropSide: CGFloat = 300
    /// 当前缩放倍数（由 UIKit 上报）
    @State private var zoomScale: CGFloat = 0
    /// 「刚好填满取景框」的基准缩放倍数
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
                    if let original, let preview {
                        onDone(Self.crop(from: original, preview: preview, cropSide: cropSide, zoomScale: zoomScale, fitScale: fitScale))
                    } else if let original {
                        onDone(original)
                    }
                }
                // 刻意不 disable：按钮点了必须有反应。
                // 之前加了 `.disabled(fitScale <= 0)`，而 fitScale 是 UIKit 回调
                // 异步上报的，一旦没上报到按钮就永远点不动 —— 用户直接卡死在这一页。
                // 参数缺失时 `crop` 会退回原图，是可接受的降级，不该堵住主流程。
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - 编辑器

    private func editor(preview: UIImage) -> some View {
        VStack(spacing: 16) {
            // 用 overlay 而不是 ZStack：取景框和滚动视图共用**同一个**几何源。
            // 之前放 ZStack 里，滚动视图实际落在安全区内、比分配高度矮约 32pt，
            // 结果取景框中心与图片视觉中心错开，看起来「没居中」。
            GeometryReader { geometry in
                let side = min(
                    min(geometry.size.width, geometry.size.height) - Self.cropSidePadding * 2,
                    Self.maxCropSide
                )

                ZoomableCropView(
                    image: preview,
                    onZoomScaleChange: { zoomScale = $0 },
                    onFit: { fitScale = $0 }
                )
                .overlay {
                    CropOverlay(cropSide: side)
                        .allowsHitTesting(false)
                }
                .onAppear { cropSide = side }
                .onChange(of: side) { _, newValue in cropSide = newValue }
            }

            Text("双指缩放，单指拖动。直接点「完成」也行。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 裁切换算（纯函数，便于单测）

extension ImageCropper {
    /// 取景框在**图片像素**里对应的边长。
    ///
    /// 取景框固定不动、图片被缩放，所以取景框覆盖的屏幕宽度
    /// 对应图片里的 `cropSide / zoomScale` 个点。
    ///
    /// `fitScale` 是「刚好填满取景框」的基准缩放：在它之下不该发生
    /// （`minimumZoomScale` 保证），真发生了就夹住，避免裁出比取景框更大的区域。
    static func cropSideInImage(cropSide: CGFloat, zoomScale: CGFloat, fitScale: CGFloat) -> CGFloat {
        guard cropSide > 0, fitScale > 0 else { return 0 }
        let effective = max(zoomScale, fitScale)
        let side = cropSide / effective
        return side.isFinite ? side : 0
    }

    /// 预览图边长 → 原图对应的边长。两张图等比，按宽度比例线性映射即可。
    static func scaleToOriginal(_ length: CGFloat, previewSize: CGSize, originalSize: CGSize) -> CGFloat {
        guard previewSize.width > 0, originalSize.width > 0 else { return 0 }
        return length * (originalSize.width / previewSize.width)
    }

    /// 从原图切出取景框对应的区域。
    ///
    /// 取景框始终居中（`minimumZoomScale` 保证图片至少填满取景框，
    /// 而居中由 `CropScrollView.centerContent` 负责），所以区域就是原图中央的正方形。
    ///
    /// **保证返回一张图**：换算异常时退回整张原图，绝不返回 nil ——
    /// 否则用户点了「完成」会毫无反应，那是最让人困惑的失败方式。
    static func crop(
        from original: UIImage,
        preview: UIImage,
        cropSide: CGFloat,
        zoomScale: CGFloat,
        fitScale: CGFloat
    ) -> UIImage {
        guard let cgImage = original.cgImage else { return original }

        let sideInPreview = cropSideInImage(cropSide: cropSide, zoomScale: zoomScale, fitScale: fitScale)
        guard sideInPreview > 1 else { return original }

        let sideInOriginal = scaleToOriginal(
            sideInPreview,
            previewSize: preview.size,
            originalSize: original.size
        )
        guard sideInOriginal > 1 else { return original }

        let rect = CGRect(
            x: (original.size.width - sideInOriginal) / 2,
            y: (original.size.height - sideInOriginal) / 2,
            width: sideInOriginal,
            height: sideInOriginal
        ).integral.intersection(CGRect(origin: .zero, size: original.size))

        guard rect.width > 1, rect.height > 1 else { return original }
        guard let cropped = cgImage.cropping(to: rect) else { return original }
        return UIImage(cgImage: cropped, scale: original.scale, orientation: .up)
    }
}

// MARK: - 取景框

/// 固定不动的正方形取景框：四周压暗 + 白色细边 + 三分线
private struct CropOverlay: View {
    let cropSide: CGFloat

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .reverseMask {
                    Rectangle().frame(width: cropSide, height: cropSide)
                }

            Rectangle()
                .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                .frame(width: cropSide, height: cropSide)

            thirds
        }
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
