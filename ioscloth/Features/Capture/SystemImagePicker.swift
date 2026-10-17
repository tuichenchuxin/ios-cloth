import SwiftUI
import UIKit

/// 系统的拍照 / 选图界面，**自带裁剪**。
///
/// ## 为什么用 `UIImagePickerController`
///
/// `allowsEditing = true` 会启用系统自带的裁剪界面（就是我们平时在系统里见惯的样子）：
/// 正方形取景框、框外压暗、**双指缩放和拖动全屏有效**、行为完全符合用户习惯。
///
/// 这是 iOS 上**唯一公开的**裁切 UI。照片 App 里那种可调比例、可旋转的自由裁剪
/// **没有公开 API**（想完全一样只能用第三方库，比如 guoyingtao/Mantis）。
///
/// 局限：只能裁正方形（1:1），取景框大小/比例改不了。
/// 对本 App 够用 —— 衣柜网格、搭配卡显示的都是正方形。
///
/// 之前这里是自己写的裁切页（UIScrollView + 取景框 + 四角手柄），
/// 反复出问题：框外显示要靠再画一张图（必然错位）、改框大小会带动图片跳变、
/// 双指只在框内有效。换成系统组件后这些问题一次性消失。
struct SystemImagePicker: UIViewControllerRepresentable {
    enum Source {
        case camera
        case photoLibrary
    }

    let source: Source
    /// 拿到**已裁好**的图片
    let onPicked: (UIImage) -> Void
    /// 用户取消
    let onCancel: () -> Void

    /// 相机在当前设备上是否可用（模拟器没有）
    static var isCameraAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = (source == .camera) ? .camera : .photoLibrary
        if source == .camera {
            picker.cameraCaptureMode = .photo
        }
        // 关键：开启系统裁剪界面
        picker.allowsEditing = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onPicked: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onPicked: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onPicked = onPicked
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // 系统裁剪后的结果在 .editedImage；没有裁剪结果时退回原图
            if let image = (info[.editedImage] as? UIImage) ?? (info[.originalImage] as? UIImage) {
                onPicked(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
