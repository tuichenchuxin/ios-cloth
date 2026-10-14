import SwiftUI
import UIKit

/// 可缩放平移的图片视图，底层是 `UIScrollView`。
///
/// ## 为什么用 UIKit 而不是 SwiftUI 手势
///
/// 之前用 SwiftUI 的 `MagnifyGesture` + `DragGesture` 自己算缩放平移，踩了两个坑：
/// 1. `MagnifyGesture` 的 `startAnchor` 是在**被缩放后的图片坐标系**里报的，
///    不是容器坐标 —— 拿它当容器坐标做锚定，补偿量完全错，表现就是
///    「无论捏哪里，取景框都往右下漂」；
/// 2. 两个手势同时改同一份 offset，互相打架。
///
/// `UIScrollView` 的缩放平移是 iOS 上最成熟的那套实现：锚定、边界回弹、
/// 双指平移全部由系统负责，行为确定、没有坐标系歧义。这里只读它的
/// `zoomScale` 和 `contentOffset` 来换算裁切矩形。
struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    /// 缩放/平移变化时回调，用来更新裁切框
    let onTransformChange: (CGFloat, CGPoint, CGSize) -> Void

    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.backgroundColor = .black

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.addSubview(imageView)
        scrollView.contentSize = image.size
        context.coordinator.imageView = imageView

        // 初始缩放：长边刚好填满可视区域
        scrollView.layoutIfNeeded()
        let bounds = scrollView.bounds.size
        guard bounds.width > 0, bounds.height > 0, image.size.width > 0, image.size.height > 0 else {
            return scrollView
        }
        let fitScale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        scrollView.minimumZoomScale = fitScale
        scrollView.maximumZoomScale = fitScale * 8
        scrollView.zoomScale = fitScale
        context.coordinator.centerContent(in: bounds)
        context.coordinator.report(scrollView)

        return scrollView
    }

    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        // 图片只在初始化时设置一次；之后缩放平移由 UIScrollView 自己管
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTransformChange: onTransformChange)
    }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        let onTransformChange: (CGFloat, CGPoint, CGSize) -> Void
        weak var imageView: UIImageView?

        init(onTransformChange: @escaping (CGFloat, CGPoint, CGSize) -> Void) {
            self.onTransformChange = onTransformChange
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            centerContent(in: scrollView.bounds.size)
            report(scrollView)
        }

        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            report(scrollView)
        }

        /// 内容比可视区小的时候居中（放大后不需要）
        func centerContent(in bounds: CGSize) {
            guard let imageView else { return }
            let scaled = imageView.frame.size
            let horizontal = max((bounds.width - scaled.width) / 2, 0)
            let vertical = max((bounds.height - scaled.height) / 2, 0)
            // ⚠️ 必须设 contentInset 而不是改 imageView.frame：
            // 改 frame 会被 UIScrollView 在缩放过程中重置，产生抖动。
            guard let scrollView = imageView.superview as? UIScrollView else { return }
            scrollView.contentInset = UIEdgeInsets(
                top: vertical, left: horizontal, bottom: vertical, right: horizontal
            )
        }

        func report(_ scrollView: UIScrollView) {
            onTransformChange(scrollView.zoomScale, scrollView.contentOffset, scrollView.bounds.size)
        }
    }
}
