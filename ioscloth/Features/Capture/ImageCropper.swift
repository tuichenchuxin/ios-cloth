import SwiftUI
import UIKit

/// 裁切照片。
///
/// 目标是**最短路径**：打开就已经居中放好、放大到填满裁切框，用户直接点「完成」。
/// 想微调就双指缩放、单指拖动。没有旋转变形工具 —— 录入衣服不需要。
///
/// ## 性能：屏幕上永远只用缩略图
///
/// 相机原图动辄 4000×3000。如果直接把它交给 SwiftUI 去按 340pt 绘制，
/// 每个手势帧都要重采样一张 1200 万像素的图 —— 表现就是「进裁切页很慢、
/// 拖动和缩放很卡」。
///
/// 所以这里先做一张长边 1200px 的预览图（`.task` 里一次性生成，放主线程外），
/// 屏幕上只画它；点「完成」时再把裁切矩形按比例映射回原图去切。
/// 这样既能得到全分辨率的裁切结果，交互又始终是流畅的。
struct ImageCropper: View {
    let image: UIImage
    /// 回调裁切结果
    let onDone: (UIImage) -> Void
    /// 取消
    let onCancel: () -> Void

    /// 预览图长边像素。取 1200 是为了在 3× 屏上画 340pt 仍然清晰（约 1020px），
    /// 同时小到足以让手势全程流畅。
    static let previewMaxDimension: CGFloat = 1200

    /// 裁切框最大边长（正方形：衣服拍出来基本都是竖着的主体）
    static let maxCropSide: CGFloat = 340
    /// 裁切框与屏幕边缘的间距
    static let cropSidePadding: CGFloat = 12

    /// 原图（方向已拍平）。裁切结果取自它，所以不损失分辨率。
    @State private var original: UIImage?
    /// 屏幕上实际绘制的缩略图
    @State private var preview: UIImage?
    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var cropSide: CGFloat = 300

    var body: some View {
        Group {
            if let preview, let original {
                editor(preview: preview, original: original)
            } else {
                ProgressView("正在准备…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
            }
        }
        .task {
            guard original == nil else { return }
            // 拍平方向 + 生成预览都放主线程外：这是进入裁切页慢的根源
            let prepared = await Task.detached(priority: .userInitiated) { () -> (UIImage, UIImage) in
                let upright = image.upright()
                return (upright, upright.resized(maxDimension: Self.previewMaxDimension))
            }.value
            original = prepared.0
            preview = prepared.1
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
                    if let original {
                        onDone(Self.crop(from: original, preview: preview, offset: offset, scale: scale, cropSide: cropSide))
                    }
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
    }

    // MARK: - 编辑器

    private func editor(preview: UIImage, original: UIImage) -> some View {
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let side = min(
                    min(geometry.size.width, geometry.size.height) - Self.cropSidePadding * 2,
                    Self.maxCropSide
                )

                ZStack {
                    Color.black

                    Image(uiImage: preview)
                        .resizable()
                        .frame(width: preview.size.width * scale, height: preview.size.height * scale)
                        .offset(offset)

                    CropOverlay()
                        .allowsHitTesting(false)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .gesture(dragGesture.simultaneously(with: magnifyGesture))
                .onAppear {
                    cropSide = side
                    reset()
                }
                .onChange(of: side) { _, newValue in
                    cropSide = newValue
                    reset()
                }
            }

            Text("双指缩放，单指拖动。直接点「完成」也行。")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 手势

    private var dragGesture: some Gesture {
        DragGesture()
            .onChanged { value in
                offset = clamped(
                    CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                )
            }
            .onEnded { _ in
                lastOffset = offset
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = max(lastScale * value.magnification, minimumScale)
                offset = clamped(offset)
            }
            .onEnded { _ in
                lastScale = scale
                lastOffset = offset
            }
    }

    private var minimumScale: CGFloat {
        let size = preview?.size ?? .zero
        guard size.width > 0, size.height > 0, cropSide > 0 else { return 1 }
        return max(cropSide / size.width, cropSide / size.height)
    }

    /// 把偏移限制在「图片始终盖满裁切框」的范围内
    private func clamped(_ candidate: CGSize) -> CGSize {
        guard let preview else { return .zero }
        let maxX = max((preview.size.width * scale - cropSide) / 2, 0)
        let maxY = max((preview.size.height * scale - cropSide) / 2, 0)
        return CGSize(
            width: min(max(candidate.width, -maxX), maxX),
            height: min(max(candidate.height, -maxY), maxY)
        )
    }

    private func reset() {
        scale = minimumScale
        lastScale = scale
        offset = .zero
        lastOffset = .zero
    }
}

// MARK: - 裁切换算

extension ImageCropper {
    /// 屏幕上的变换 → 预览图坐标里的裁切矩形。
    ///
    /// 抽成静态纯函数是为了能单测：这里错一点，所有照片就都废了，
    /// 而它又没法靠肉眼在模拟器上验证（差几个像素看不出来）。
    static func cropRect(
        previewSize: CGSize,
        offset: CGSize,
        scale: CGFloat,
        cropSide: CGFloat
    ) -> CGRect {
        guard scale > 0, cropSide > 0, previewSize.width > 0, previewSize.height > 0 else {
            return .zero
        }
        let centerX = previewSize.width / 2 - offset.width / scale
        let centerY = previewSize.height / 2 - offset.height / scale
        let side = cropSide / scale

        let desired = CGRect(
            x: centerX - side / 2,
            y: centerY - side / 2,
            width: side,
            height: side
        )
        let bounds = CGRect(origin: .zero, size: previewSize)
        guard desired.intersects(bounds) else { return .zero }

        // ⚠️ 不能直接信 `intersection` 的返回值：两矩形不相交时它返回
        // `CGRect.infinite`（不是 `.null`），而 `isNull` 对 infinite 是 false。
        // 放过去就会拿一个无穷大的矩形去裁图，直接吃爆内存。
        let clipped = desired.intersection(bounds)
        guard !clipped.isNull,
              clipped.width.isFinite, clipped.height.isFinite,
              clipped.width > 0, clipped.height > 0 else {
            return .zero
        }
        return clipped
    }

    /// 预览图坐标 → 原图像素坐标。两张图等比，所以按宽度比例线性映射即可。
    static func mapToOriginal(_ rect: CGRect, previewSize: CGSize, originalSize: CGSize) -> CGRect {
        guard previewSize.width > 0, originalSize.width > 0 else { return .zero }
        let ratio = originalSize.width / previewSize.width
        return CGRect(
            x: rect.origin.x * ratio,
            y: rect.origin.y * ratio,
            width: rect.width * ratio,
            height: rect.height * ratio
        ).integral
    }

    /// 从原图切出裁切区域。
    ///
    /// **保证返回一张图**：换算异常时退回整张原图，绝不返回 nil ——
    /// 否则用户点了「完成」会毫无反应，那是最让人困惑的失败方式。
    static func crop(
        from original: UIImage,
        preview: UIImage?,
        offset: CGSize,
        scale: CGFloat,
        cropSide: CGFloat
    ) -> UIImage {
        guard let preview, let cgImage = original.cgImage else { return original }

        let rectInPreview = cropRect(
            previewSize: preview.size,
            offset: offset,
            scale: scale,
            cropSide: cropSide
        )
        guard rectInPreview.width > 1, rectInPreview.height > 1 else { return original }

        let rectInOriginal = mapToOriginal(
            rectInPreview,
            previewSize: preview.size,
            originalSize: original.size
        )
        guard rectInOriginal.width > 1, rectInOriginal.height > 1 else { return original }

        guard let cropped = cgImage.cropping(to: rectInOriginal) else { return original }
        return UIImage(cgImage: cropped, scale: original.scale, orientation: .up)
    }
}

// MARK: - 裁切框

/// 四周压暗 + 白色细边 + 三分线。
/// 这个视图拿到整个可绘制区域，自己算出居中的正方形裁切框 ——
/// 这样压暗层和边框在同一个坐标系里，不会错位。
private struct CropOverlay: View {
    var body: some View {
        GeometryReader { geometry in
            // 和 ImageCropper 用同一套公式，保证压暗框与裁切结果完全对齐
            let side = min(
                min(geometry.size.width, geometry.size.height) - ImageCropper.cropSidePadding * 2,
                ImageCropper.maxCropSide
            )
            let third = side / 3

            ZStack {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .reverseMask {
                        Rectangle().frame(width: side, height: side)
                    }

                Rectangle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5)
                    .frame(width: side, height: side)

                Path { path in
                    for index in 1...2 {
                        let position = third * CGFloat(index) - side / 2
                        path.move(to: CGPoint(x: position, y: -side / 2))
                        path.addLine(to: CGPoint(x: position, y: side / 2))
                        path.move(to: CGPoint(x: -side / 2, y: position))
                        path.addLine(to: CGPoint(x: side / 2, y: position))
                    }
                }
                .stroke(Color.white.opacity(0.3), lineWidth: 0.5)
                .frame(width: side, height: side)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
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
