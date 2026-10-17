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
    /// 当前变焦倍数（1 = 原始视角）
    @Published private(set) var zoomFactor: CGFloat = 1

    /// 变焦上限。设备本身支持更高，但手机上超过 6 倍画质就糊了
    static let maxZoom: CGFloat = 6

    private let photoOutput = AVCapturePhotoOutput()
    private var device: AVCaptureDevice?
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

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device),
              session.canAddInput(input) else {
            return false
        }
        session.addInput(input)
        self.device = device

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

    /// 捏合变焦。1 倍是原始视角，上限取设备能力和 `maxZoom` 中较小的那个。
    ///
    /// 直接设 `videoZoomFactor`（而不是 ramp）是为了跟手 —— 捏合是连续的，
    /// 让指头的位置即时对应缩放；ramp 会在收手后继续滑一段，反而怪。
    func setZoom(_ factor: CGFloat) {
        guard let device else { return }
        let deviceLimit = min(device.activeFormat.videoMaxZoomFactor, Self.maxZoom)
        let clamped = max(1, min(factor, deviceLimit))

        sessionQueue.async { [weak self] in
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
                DispatchQueue.main.async { self?.zoomFactor = clamped }
            } catch {
                // 设不上就保持原样，不要打断拍照
            }
        }
    }

    func resetZoom() {
        setZoom(1)
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
