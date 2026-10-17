import AVFoundation

extension AVCaptureDevice.DeviceType {
    /// 诊断文件里用的短名，原始值是 `AVCaptureDeviceTypeBuiltInTripleCamera` 这种长串
    var shortName: String {
        switch self {
        case .builtInUltraWideCamera: "ultraWide"
        case .builtInWideAngleCamera: "wide"
        case .builtInTelephotoCamera: "tele"
        case .builtInDualCamera: "dual"
        case .builtInDualWideCamera: "dualWide"
        case .builtInTripleCamera: "triple"
        default: rawValue
            .replacingOccurrences(of: "AVCaptureDeviceTypeBuiltIn", with: "")
            .replacingOccurrences(of: "AVCaptureDeviceType", with: "")
        }
    }
}
