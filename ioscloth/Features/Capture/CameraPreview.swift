import AVFoundation
import SwiftUI
import UIKit

/// 相机会话的封装：负责权限、配置、启停、拍照。
///
/// 为什么自建相机而不是继续用系统相机（`UIImagePickerController`）：
/// 系统相机**不允许我们往上加任何自定义蒙层**，而模板拍照的核心恰恰是蒙层。
/// 代价是要自己管会话、方向和权限，实现见下。
final class CameraController: NSObject, ObservableObject {
    let session = AVCaptureSession()

    /// 会话配好了、可以拍照了
    @Published private(set) var isReady = false
    /// 用户拒绝了相机权限
    @Published private(set) var isDenied = false
    /// 权限都不弹（系统设置里关掉了）
    @Published private(set) var isRestricted = false
    /// 界面显示的变焦倍数。
    ///
    /// **故意和实际值分开**：如果每个手势事件都发布一次，SwiftUI 会整页重绘
    /// （预览层 + 蒙层 + 按钮），放大时会明显卡顿甚至跳一下。
    /// 这里只在变化超过 0.1 时才发布。
    @Published private(set) var displayedZoom: CGFloat = 1

    /// 实际变焦倍数（同步更新，不触发重绘）。手势起点要用它，避免开头跳一下。
    private(set) var currentZoom: CGFloat = 1

    /// 这台设备支持的变焦范围。有超广角时下限是 0.5。
    private(set) var minZoom: CGFloat = 1
    private(set) var maxZoom: CGFloat = 6

    /// 手机上超过 6 倍画质就糊了，再高没意义
    private static let zoomCap: CGFloat = 6

    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
    /// 待应用的最新变焦目标。手势事件比串行队列快，只保留最新值，避免任务堆积。
    private var pendingZoom: CGFloat?
    private var isApplyingZoom = false
    private let sessionQueue = DispatchQueue(label: "ioscloth.camera.session")
    private var captureHandler: ((UIImage?) -> Void)?
    private var isConfigured = false

    // MARK: 生命周期

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startSession()
                } else {
                    DispatchQueue.main.async { self.isDenied = true }
                }
            }
        default:
            isRestricted = true
        }
    }

    func stop() {
        sessionQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    // MARK: 配置

    private func startSession() {
        sessionQueue.async { [self] in
            if !isConfigured {
                guard configure() else { return }
            }
            if !session.isRunning {
                session.startRunning()
            }
            DispatchQueue.main.async { self.isReady = true }
        }
    }

    private func configure() -> Bool {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .photo

        // 优先用「虚拟多摄」设备：它在 0.5× 时会自动切到超广角。
        // 单颗广角镜头（builtInWideAngleCamera）最小就是 1×，无法缩小。
        let preferredTypes: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInWideAngleCamera,
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferredTypes,
            mediaType: .video,
            position: .back
        )
        let device = preferredTypes
            .compactMap { type in discovery.devices.first { $0.deviceType == type } }
            .first

        guard let device,
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return false
        }
        session.addInput(input)
        self.device = device

        // 记录真实可用范围：有超广角时 minZoom 会是 0.5
        minZoom = max(device.minAvailableVideoZoomFactor, 0.5)
        maxZoom = min(device.maxAvailableVideoZoomFactor, Self.zoomCap)
        currentZoom = 1
        DispatchQueue.main.async { self.displayedZoom = 1 }

        guard session.canAddOutput(photoOutput) else { return false }
        session.addOutput(photoOutput)

        // 竖屏：把连接转正，否则存下来的照片会躺倒
        if let connection = photoOutput.connection(with: .video),
           connection.isVideoRotationAngleSupported(90) {
            connection.videoRotationAngle = 90
        }

        isConfigured = true
        return true
    }

    // MARK: 变焦

    /// 捏合变焦。1 倍是主摄视角，可以缩到 0.5（有超广角时）。
    ///
    /// 直接设 `videoZoomFactor` 而不是 `ramp`：捏合是连续手势，
    /// ramp 会让画面追着手指慢慢滑，反而更不跟手。
    func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        let clamped = Self.clampedZoom(factor, min: minZoom, max: maxZoom)

        // 同步更新实际值，手势下次取起点时是准的（避免开头跳一下）
        currentZoom = clamped

        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.pendingZoom = clamped

            // 已经在处理就交给循环带走最新值，不重复加锁
            guard !self.isApplyingZoom else { return }
            self.isApplyingZoom = true

            while let target = self.pendingZoom {
                self.pendingZoom = nil
                do {
                    try device.lockForConfiguration()
                    device.videoZoomFactor = target
                    device.unlockForConfiguration()
                } catch {
                    // 设不上就保持原样，不要打断拍照
                }
            }
            self.isApplyingZoom = false

            // 只有显示值真的变了才发布，避免每帧重绘整个页面
            DispatchQueue.main.async {
                if abs(self.displayedZoom - self.currentZoom) >= 0.1 {
                    self.displayedZoom = self.currentZoom
                }
            }
        }
    }

    func resetZoom() {
        setZoom(1)
    }

    /// 把捏合算出的目标倍数夹到设备范围内。
    ///
    /// 下限**不是 1**：有超广角时可以是 0.5（之前写死 `max(1, …)`，
    /// 结果就是「只能放大不能缩小」）。
    static func clampedZoom(_ factor: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
        guard factor.isFinite else { return 1 }
        return Swift.min(Swift.max(factor, min), max)
    }

    // MARK: 拍照

    func capture(_ withImage: @escaping (UIImage?) -> Void) {
        guard isReady, session.isRunning else {
            withImage(nil)
            return
        }
        captureHandler = withImage
        let settings = AVCapturePhotoSettings()
        photoOutput.capturePhoto(with: settings, delegate: self)
    }
}

extension CameraController: AVCapturePhotoCaptureDelegate {
    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        let handler = captureHandler
        captureHandler = nil

        guard error == nil,
              let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else {
            DispatchQueue.main.async { handler?(nil) }
            return
        }
        DispatchQueue.main.async { handler?(image) }
    }
}

// MARK: - 预览层

/// 只负责把 `AVCaptureVideoPreviewLayer` 铺满。
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.backgroundColor = .black
        view.videoPreviewLayer.session = session
        view.videoPreviewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override static var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var videoPreviewLayer: AVCaptureVideoPreviewLayer {
            // layerClass 保证一定是这个类型
            layer as! AVCaptureVideoPreviewLayer
        }
    }
}
