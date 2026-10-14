import SwiftUI
import UIKit

/// 带固定正方形取景框的缩放平移视图。缩放平移全交给 `UIScrollView`。
///
/// ## 为什么用 UIKit 而不是 SwiftUI 手势
///
/// 之前用 SwiftUI 的 `MagnifyGesture` / `DragGesture` 自己算，踩了两个坑：
/// 1. `startAnchor` 报的是**被缩放后的图片坐标系**，不是容器坐标 ——
///    拿它当容器坐标做锚定，补偿量完全错，表现是「无论捏哪里，取景框都往右下漂」；
/// 2. 两个手势同时改同一份 offset，互相打架。
///
/// ## 这个视图只负责一件事：把「用户当前的缩放倍数」报出去
///
/// 裁切矩形**不在这里算**。它由 `ImageCropper` 在图片坐标里算 —— 那里同时
/// 持有原图和预览图，信息完整。这里只报一个标量（缩放倍数），少传数据少出错。
///
/// ⚠️ **缩放配置必须在 `layoutSubviews` 里做，不能在 `makeUIView` 里做。**
/// `makeUIView` 时视图还没进层级，`bounds` 是 zero，算出来的
/// `minimumZoomScale` 会是 0 或 NaN —— `UIScrollView` 会因此**完全不响应捏合**。
struct ZoomableCropView: UIViewRepresentable {
    let image: UIImage
    /// 用户缩放 / 平移变化时上报当前变换
    let onTransformChange: (CropTransform) -> Void
    /// 初始化完成后上报一次「刚好填满」的基准缩放倍数
    let onFit: (CGFloat) -> Void

    func makeUIView(context: Context) -> CropScrollView {
        let scrollView = CropScrollView()
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.decelerationRate = .fast
        scrollView.image = image
        scrollView.onTransform = onTransformChange
        scrollView.onFit = onFit
        return scrollView
    }

    func updateUIView(_ scrollView: CropScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

/// 负责缩放平移的 `UIScrollView`
final class CropScrollView: UIScrollView, UIScrollViewDelegate {
    /// 待展示的图片。设置后会在下一次布局时装配
    var image: UIImage? {
        didSet { setNeedsLayout() }
    }

    var onTransform: ((CropTransform) -> Void)?
    var onFit: ((CGFloat) -> Void)?

    private var imageView: UIImageView?
    /// 缩放范围只配置一次
    private var isConfigured = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        // 提前给一个合法的（非零）缩放范围，避免系统在布局前就把手势禁掉
        minimumZoomScale = 1
        maximumZoomScale = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureIfNeeded()
        centerContent()
    }

    /// 装配图片并设置缩放范围。**必须等到 bounds 有效**。
    private func configureIfNeeded() {
        guard let image, !isConfigured else { return }
        guard bounds.width > 1, bounds.height > 1, image.size.width > 1, image.size.height > 1 else {
            return
        }

        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(imageView)
        self.imageView = imageView
        contentSize = image.size

        // 「刚好填满取景框」的基准缩放
        let fitScale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        guard fitScale.isFinite, fitScale > 0 else { return }

        minimumZoomScale = fitScale
        maximumZoomScale = fitScale * 8
        zoomScale = fitScale
        isConfigured = true

        onFit?(fitScale)
        report()
    }

    /// 内容小于可视区时居中。
    /// 用 `contentInset` 而不是改 `imageView.frame`：后者会被 `UIScrollView` 在缩放中重置。
    private func centerContent() {
        guard let imageView else { return }
        let scaled = imageView.frame.size
        let horizontal = max((bounds.width - scaled.width) / 2, 0)
        let vertical = max((bounds.height - scaled.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // 缩放中 bounds 会变，居中也要跟着更新
        centerContent()
        report()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        report()
    }

    /// 把「用户当前看到的区域」需要的三个量报上去。
    ///
    /// 这里**刻意不做任何坐标系推演** —— 只报原始量，换算放在能单测的纯函数里。
    /// 之前就是在这一层手算 `contentOffset`/`contentInset` 的关系，算错了中心点。
    private func report() {
        onTransform?(CropTransform(
            zoomScale: zoomScale,
            contentOffset: contentOffset,
            viewportSize: bounds.size
        ))
    }
}
