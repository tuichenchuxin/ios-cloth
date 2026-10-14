import SwiftUI
import UIKit

/// 裁切照片。
///
/// 目标是**最短路径**：打开就已经居中放好、放大到填满裁切框，用户直接点「完成」就行。
/// 想微调就双指缩放、单指拖动。没有旋转变形工具 —— 录入衣服不需要。
struct ImageCropper: View {
    let image: UIImage
    /// 回调裁切结果
    let onDone: (UIImage) -> Void
    /// 取消。默认自己 dismiss；嵌在别的流程里时由外面接管（否则会把整个 cover 关掉）
    var onCancel: (() -> Void)?

    @Environment(\.dismiss) private var dismiss

    private func cancel() {
        if let onCancel { onCancel() } else { dismiss() }
    }

    /// 裁切框最大边长（裁切框是正方形：衣服拍出来基本都是竖着的主体）
    static let maxCropSide: CGFloat = 340
    /// 裁切框与屏幕边缘的间距
    static let cropSidePadding: CGFloat = 12

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var cropSide: CGFloat = 300

    private var uprightImage: UIImage { image.upright() }

    /// 「刚好填满裁切框」所需的缩放。小于它就会露黑边，所以这是下限。
    private var minimumScale: CGFloat {
        let size = uprightImage.size
        guard size.width > 0, size.height > 0, cropSide > 0 else { return 1 }
        return max(cropSide / size.width, cropSide / size.height)
    }

    private var displayedSize: CGSize {
        let size = uprightImage.size
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    var body: some View {
        // 注意：这里**刻意不套 NavigationStack**。
        // 它是被 CaptureFlowView 用 NavigationStack push 进来的，
        // 再套一层会变成嵌套导航，返回手势和 toolbar 都会出问题。
        VStack(spacing: 16) {
            GeometryReader { geometry in
                let side = min(
                    min(geometry.size.width, geometry.size.height) - Self.cropSidePadding * 2,
                    Self.maxCropSide
                )

                ZStack {
                    Color.black

                    Image(uiImage: uprightImage)
                        .resizable()
                        .frame(width: displayedSize.width, height: displayedSize.height)
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
        .background(Color.black)
        .navigationTitle("调整照片")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("取消") { cancel() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("完成") {
                    // crop() 保证永远返回一张图（换算异常时退回原图），
                    // 所以这里不会出现「点了完成什么都没发生」。
                    onDone(crop())
                }
            }
        }
        .toolbarBackground(.black, for: .navigationBar)
        .toolbarColorScheme(.dark, for: .navigationBar)
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

    /// 把偏移限制在「图片始终盖满裁切框」的范围内
    private func clamped(_ candidate: CGSize) -> CGSize {
        let displayed = displayedSize
        let maxX = max((displayed.width - cropSide) / 2, 0)
        let maxY = max((displayed.height - cropSide) / 2, 0)
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

    // MARK: - 裁切

    /// 屏幕上的变换 → 原图坐标里的裁切矩形。
    ///
    /// 抽成静态纯函数是为了能单测：这里的换算错一点，所有照片就都废了，
    /// 而它又没法靠肉眼在模拟器上验证（差几个像素根本看不出来）。
    static func cropRect(
        sourceSize: CGSize,
        offset: CGSize,
        scale: CGFloat,
        cropSide: CGFloat
    ) -> CGRect {
        guard scale > 0, cropSide > 0, sourceSize.width > 0, sourceSize.height > 0 else {
            return .zero
        }
        // 裁切框中心对应到原图的坐标
        let centerX = sourceSize.width / 2 - offset.width / scale
        let centerY = sourceSize.height / 2 - offset.height / scale
        let side = cropSide / scale

        let desired = CGRect(
            x: centerX - side / 2,
            y: centerY - side / 2,
            width: side,
            height: side
        )
        let bounds = CGRect(origin: .zero, size: sourceSize)
        guard desired.intersects(bounds) else { return .zero }

        // ⚠️ 不能直接信 `intersection` 的返回值：两矩形不相交时它返回的是
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

    /// 把屏幕上的变换换算回原图像素坐标，再切出来。
    ///
    /// **保证返回一张图**：换算异常时退回整张原图，绝不返回 nil。
    /// 否则用户点了「完成」会毫无反应，而那是最让人困惑的失败方式。
    private func crop() -> UIImage {
        let source = uprightImage
        let sourceSize = source.size
        let rect = Self.cropRect(
            sourceSize: sourceSize,
            offset: offset,
            scale: scale,
            cropSide: cropSide
        )

        // 变换异常时矩形可能退化，那就别裁了，返回原图而不是崩
        guard rect.width > 1, rect.height > 1 else { return source }

        guard let cgImage = source.cgImage else { return source }
        // cgImage 以像素为单位，而 size 是点，缩放过的图两者不一致，必须换算
        let pixelScale = CGFloat(cgImage.width) / sourceSize.width
        let pixelRect = CGRect(
            x: rect.origin.x * pixelScale,
            y: rect.origin.y * pixelScale,
            width: rect.width * pixelScale,
            height: rect.height * pixelScale
        ).integral

        guard let cropped = cgImage.cropping(to: pixelRect) else { return source }
        return UIImage(cgImage: cropped, scale: source.scale, orientation: .up)
    }
}

/// 裁切框：四周压暗 + 白色细边 + 三分线。
/// 这个视图会拿到整个可绘制区域，自己算出居中的正方形裁切框 ——
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
                // 整块压暗，再把裁切框「抠」出来
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .reverseMask {
                        Rectangle()
                            .frame(width: side, height: side)
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
