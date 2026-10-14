import SwiftUI
import UIKit

/// 系统相机。
///
/// 用 `UIImagePickerController` 而不是自己搭 `AVCaptureSession`：
/// 系统相机自带对焦、曝光、闪光灯、网格，而且**零代码维护成本**。
/// 自建相机会带来一堆要调试的细节，对「录入衣服」这个场景毫无收益。
///
/// ⚠️ 这个视图**不自己关闭自己**。它的关闭完全由父级的 `isPresented` 绑定控制。
///
/// 之前这里用 `@Environment(\.dismiss)` 让相机自己 dismiss，结果踩了一个很难查的坑：
/// 它被包在 `fullScreenCover(isPresented: .constant(true))` 里时，
/// 相机一关闭会把**整个 cover** 一起拆掉 —— 用户点「使用照片」的瞬间，
/// 刚出现的裁切页也被连带销毁，表现就是「点了 Use，什么都没发生」。
struct CameraPicker: UIViewControllerRepresentable {
    /// 拍完回调（用户点了「使用照片」）
    let onCapture: (UIImage) -> Void
    /// 用户点了取消
    let onCancel: () -> Void

    /// 相机在当前设备上是否可用（模拟器没有）
    static var isAvailable: Bool {
        UIImagePickerController.isSourceTypeAvailable(.camera)
    }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.allowsEditing = false
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onCapture: onCapture, onCancel: onCancel)
    }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        private let onCapture: (UIImage) -> Void
        private let onCancel: () -> Void

        init(onCapture: @escaping (UIImage) -> Void, onCancel: @escaping () -> Void) {
            self.onCapture = onCapture
            self.onCancel = onCancel
        }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            // 只把结果交出去，关不关由父级决定。
            // 用 .originalImage 而不是 .editedImage —— 裁切我们自己控制。
            if let image = info[.originalImage] as? UIImage {
                onCapture(image)
            } else {
                onCancel()
            }
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onCancel()
        }
    }
}
