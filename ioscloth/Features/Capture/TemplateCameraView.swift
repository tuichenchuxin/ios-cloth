import SwiftUI
import UIKit

/// 带模板蒙层的拍照页。
///
/// 蒙层的作用是**构图引导**：把衣服摆进轮廓、撑满画面，
/// 拍完按蒙层方框自动裁成正方形 —— 不需要用户再手动裁。
///
/// 想做别的构图就用入口页的「自由」模板，那条路走系统相机 + 系统裁剪。
///
/// ## 预览区必须是 3:4，不能铺满屏幕（踩过的坑）
///
/// 相机出图是 4:3，屏幕是 19.5:9。如果让预览层 `resizeAspectFill` 铺满屏幕，
/// 系统会把画面放大到填满高度，**左右各裁掉一大块** —— 实测 440×956 的屏幕上
/// 只剩约 61% 的画面宽度。用户会以为「变焦没到超广角」，其实是预览被裁了。
///
/// 所以这里给预览区固定 3:4（和照片同比例），整幅画面完整可见，
/// 而且「取景框换算成照片坐标」也变成简单的等比缩放，所见即所得。
struct TemplateCameraView: View {
    let template: GarmentTemplate
    /// 拍好并裁好的照片
    let onCapture: (UIImage) -> Void
    let onCancel: () -> Void

    @StateObject private var camera = CameraController()
    @State private var isCapturing = false
    @State private var showPermissionAlert = false
    /// 预览区域尺寸（用来把屏幕上的框换算成照片里的比例）
    @State private var previewSize: CGSize = .zero
    /// 捏合开始时的倍数（避免累乘漂移）
    @State private var zoomBase: CGFloat?

    /// 预览区宽高比，和相机出图一致（4:3 竖着拿就是 3:4）
    private static let previewAspect: CGFloat = 3.0 / 4.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // 预览：固定 3:4，整幅画面可见
            CameraPreview(session: camera.session)
                .aspectRatio(Self.previewAspect, contentMode: .fit)
                .overlay { cropOverlay }
                .gesture(magnifyGesture)

            VStack(spacing: 12) {
                topBar
                Spacer(minLength: 0)
                zoomInfo
                shutter
                    .padding(.bottom, 24)
            }
            .padding(.top, 8)
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onChange(of: camera.isDenied) { _, denied in showPermissionAlert = denied }
        .onChange(of: camera.isRestricted) { _, restricted in showPermissionAlert = restricted }
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

    // MARK: - 蒙层

    private var cropOverlay: some View {
        GeometryReader { geometry in
            let frame = GarmentTemplate.frameRect(in: geometry.size)
            let _ = updatePreviewSize(geometry.size)

            ZStack {
                // 框外压暗
                Color.black.opacity(0.55)
                    .reverseMask {
                        RoundedRectangle(cornerRadius: 12)
                            .frame(width: frame.width, height: frame.height)
                    }

                // 衣物轮廓
                template.silhouette(in: frame)
                    .stroke(Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2, dash: [8, 6]))

                // 取景框边线
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.white.opacity(0.5), lineWidth: 1)
                    .frame(width: frame.width, height: frame.height)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - 顶部 / 底部

    private var topBar: some View {
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
    }

    /// 变焦倍数 + 模板提示
    private var zoomInfo: some View {
        VStack(spacing: 6) {
            if abs(camera.displayedZoom - 1) > 0.05 {
                HStack(spacing: 10) {
                    Text(Self.zoomLabel(camera.displayedZoom))
                        .font(.caption.monospacedDigit().weight(.medium))
                        .foregroundStyle(.yellow)
                    Button("1×") { camera.resetZoom() }
                        .font(.caption.weight(.semibold))
                        .tint(.yellow)
                        .accessibilityIdentifier("reset-zoom")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.black.opacity(0.5), in: Capsule())
            }

            Text(template.hint)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.9))
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

    // MARK: - 手势

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                // 起点用「实际值」而不是显示值：显示值是节流过的，滞后会跳
                let base = zoomBase ?? camera.currentZoom
                if zoomBase == nil { zoomBase = base }
                camera.setDisplayZoom(base * value.magnification)
            }
            .onEnded { _ in zoomBase = nil }
    }

    // MARK: - 动作

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
            // 预览是 3:4、照片也是 3:4，所以这里就是等比换算。
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
