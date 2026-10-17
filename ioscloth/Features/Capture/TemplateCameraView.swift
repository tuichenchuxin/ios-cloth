import SwiftUI
import UIKit

/// 带模板蒙层的拍照页。
///
/// 蒙层的作用是**构图引导**：把衣服摆进轮廓、撑满画面，
/// 拍完按蒙层方框自动裁成正方形 —— 不需要用户再手动裁。
///
/// 想做别的构图就用入口页的「自由」模板，那条路走系统相机 + 系统裁剪。
struct TemplateCameraView: View {
    let template: GarmentTemplate
    /// 拍好并裁好的照片
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = CameraController()
    @State private var isCapturing = false
    /// 预览区域尺寸（用来把屏幕上的框换算成照片里的比例）
    @State private var previewSize: CGSize = .zero
    /// 捏合开始时的倍数（避免累乘漂移）
    @State private var zoomBase: CGFloat?
    @State private var showPermissionAlert = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            CameraPreview(session: camera.session)
                .ignoresSafeArea()
                // 捏合变焦：和系统相机一样，双指放大缩小
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            // 起点用「实际值」而不是显示值：显示值是节流过的，滞后会跳
                            let base = zoomBase ?? camera.currentZoom
                            if zoomBase == nil { zoomBase = base }
                            camera.setDisplayZoom(base * value.magnification)
                        }
                        .onEnded { _ in zoomBase = nil }
                )

            GeometryReader { geometry in
                let frame = GarmentTemplate.frameRect(in: geometry.size)
                let _ = updatePreviewSize(geometry.size)

                ZStack {
                    // 框外压暗
                    Color.black.opacity(0.55)
                        .reverseMask {
                            RoundedRectangle(cornerRadius: 12).frame(width: frame.width, height: frame.height)
                        }

                    // 衣物轮廓
                    template.silhouette(in: frame)
                        .stroke(
                            Color.white.opacity(0.85),
                            style: StrokeStyle(lineWidth: 2, dash: [8, 6])
                        )

                    // 取景框边线
                    RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                        .frame(width: frame.width, height: frame.height)

                    // 变焦倍数提示（只在放大时出现）
                    if abs(camera.displayedZoom - 1) > 0.05 {
                        Text(Self.zoomLabel(camera.displayedZoom))
                            .font(.caption.monospacedDigit().weight(.medium))
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.black.opacity(0.5), in: Capsule())
                            .position(x: frame.midX, y: frame.minY - 28)
                    }

                    Text(template.hint)
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.9))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.4), in: Capsule())
                        .position(x: frame.midX, y: frame.maxY + 34)
                }
            }
            .allowsHitTesting(false)

            // 顶部：取消 + 模板名
            VStack {
                HStack {
                    Button("取消", action: onCancel)
                        .tint(.white)
                    Spacer()
                    Text(template.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white)
                    Spacer()
                    // 占位，让标题居中
                    Text("取消").tint(.clear).opacity(0)
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)

                Spacer()

                HStack {
                    Spacer()
                    if abs(camera.displayedZoom - 1) > 0.05 {
                        Button("1×") { camera.resetZoom() }
                            .font(.footnote.weight(.semibold))
                            .tint(.yellow)
                            .accessibilityIdentifier("reset-zoom")
                        Spacer()
                    } else {
                        Spacer()
                        Spacer()
                    }
                }
                .padding(.bottom, 8)

                shutter
                    .padding(.bottom, 28)
            }
        }
        .statusBarHidden(false)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.isDenied) { _, denied in
            showPermissionAlert = denied
        }
        .onChange(of: camera.isRestricted) { _, restricted in
            showPermissionAlert = restricted
        }
        .alert("需要相机权限", isPresented: $showPermissionAlert) {
            Button("去设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("取消", role: .cancel, action: onCancel)
        } message: {
            Text("请在「设置」里允许「衣橱」使用相机，才能拍照录入。")
        }
    }

    private var shutter: some View {
        Button {
            capture()
        } label: {
            ZStack {
                Circle()
                    .strokeBorder(Color.white.opacity(0.9), lineWidth: 4)
                    .frame(width: 76, height: 76)
                Circle()
                    .fill(Color.white)
                    .frame(width: 62, height: 62)
                    .opacity(isCapturing ? 0.4 : 1)
            }
        }
        .disabled(!camera.isReady || isCapturing)
        .accessibilityLabel("拍照")
        .accessibilityIdentifier("shutter")
    }

    /// 倍数文案：整数不显示小数（1×、2×），半档保留一位（0.5×）
    static func zoomLabel(_ value: CGFloat) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.05 {
            return "\(Int(rounded))×"
        }
        return String(format: "%.1f×", value)
    }

    private func updatePreviewSize(_ size: CGSize) {
        guard size.width > 0, size.height > 0 else { return }
        DispatchQueue.main.async {
            if previewSize != size { previewSize = size }
        }
    }

    private func capture() {
        isCapturing = true
        camera.capture { image in
            isCapturing = false
            guard let image else { return }
            // 按蒙层方框裁成正方形：用户看到的范围就是存下来的范围。
            // 需要把「屏幕上的框」换算成「照片里的比例」—— 两者长宽比不同。
            let rect = GarmentTemplate.normalizedCropRect(
                photoSize: image.size,
                previewSize: previewSize,
                frameRect: GarmentTemplate.frameRect(in: previewSize)
            )
            onCapture(GarmentTemplate.crop(image, toNormalized: rect))
        }
    }
}

// MARK: - 反向遮罩

private extension View {
    /// 只在「不是」给定形状的地方生效
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
