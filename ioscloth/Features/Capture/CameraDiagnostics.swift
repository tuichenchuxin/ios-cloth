import AVFoundation
import Foundation

/// 相机能力诊断：把设备类型、变焦范围、可用格式写到 Documents。
///
/// 为什么需要它：模拟器没有相机，而「能不能缩到 0.5×」完全取决于真机的
/// 设备类型与格式，代码里推不出来。落到文件后可以用
/// `xcrun devicectl device copy from` 拉回来看。
///
/// 只在 Debug 构建里写，正式包不会产生这个文件。
enum CameraDiagnostics {
    private static let fileName = "camera-diagnostics.txt"

    static func record(
        deviceType: AVCaptureDevice.DeviceType,
        minZoom: CGFloat,
        maxZoom: CGFloat,
        format: AVCaptureDevice.Format,
        availableDevices: [AVCaptureDevice]
    ) {
        #if DEBUG
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        var lines: [String] = [
            "=== \(formatter.string(from: Date())) ===",
            "chosen: \(deviceType.rawValue)",
            "minZoom: \(minZoom)",
            "maxZoom: \(maxZoom)",
            "format: \(format.formatDescription.dimensions.width)x\(format.formatDescription.dimensions.height)",
            "available back devices:",
        ]
        for device in availableDevices {
            lines.append("  - \(device.deviceType.rawValue) min=\(device.minAvailableVideoZoomFactor) max=\(device.maxAvailableVideoZoomFactor)")
        }

        let text = lines.joined(separator: "\n") + "\n\n"
        guard let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return
        }
        let url = documents.appendingPathComponent(fileName)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(text.utf8))
        } else {
            try? Data(text.utf8).write(to: url)
        }
        #endif
    }
}
