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
/// 之前试过在这里用 `convert(_:to:)` 反推矩形、再反推回原图，结果把位置信息
/// 弄丢了一半，绕了一大圈还是错。
struct ZoomableCropView: UIViewRepresentable {
    let image: UIImage
    /// 用户缩放变化时上报当前缩放倍数
    let onZoomScaleChange: (CGFloat) -> Void
    /// 初始化完成后上报一次「刚好填满」的基准缩放倍数
    let onFit: (CGFloat) -> Void

    func makeUIView(context: Context) -> CropScrollView {
        let scrollView = CropScrollView()
        scrollView.backgroundColor = .black
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true

        let imageView = UIImageView(image: image)
        imageView.frame = CGRect(origin: .zero, size: image.size)
        scrollView.addSubview(imageView)
        scrollView.contentSize = image.size
        scrollView.imageView = imageView
        scrollView.onZoom = onZoomScaleChange

        scrollView.layoutIfNeeded()
        let fitScale = max(
            scrollView.bounds.width / image.size.width,
            scrollView.bounds.height / image.size.height
        )
        guard fitScale.isFinite, fitScale > 0 else { return scrollView }

        scrollView.minimumZoomScale = fitScale
        scrollView.maximumZoomScale = fitScale * 8
        scrollView.zoomScale = fitScale
        scrollView.centerContent()

        onFit(fitScale)
        onZoomScaleChange(fitScale)

        return scrollView
    }

    func updateUIView(_ scrollView: CropScrollView, context: Context) {
        // 布局定稿后 bounds 才会是最终值。`makeUIView` 时拿到的可能是临时尺寸，
        // 那时算出来的居中会在最终布局里偏掉（实测偏了约 70pt）。
        // 所以在尺寸真的变化时重新居中一次。
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

/// 负责缩放平移的 `UIScrollView`
final class CropScrollView: UIScrollView, UIScrollViewDelegate {
    weak var imageView: UIImageView?
    /// 缩放变化时回调
    var onZoom: ((CGFloat) -> Void)?
    /// 上一次居中时用的可视尺寸，用来判断是否需要重新居中
    private var lastCenteredBounds: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // 每次布局都确认一下居中：bounds 在 `makeUIView` 时还没定稿
        recenterIfNeeded()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerContent()
        onZoom?(zoomScale)
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        onZoom?(zoomScale)
    }

    /// 可视尺寸变了就重新居中一次
    func recenterIfNeeded() {
        guard bounds.size != lastCenteredBounds else { return }
        lastCenteredBounds = bounds.size
        // 尺寸变化后 zoomScale 可能低于新的 minimumZoomScale，先夹住
        if zoomScale < minimumZoomScale { zoomScale = minimumZoomScale }
        centerContent()
        onZoom?(zoomScale)
    }

    /// 内容小于可视区时居中。
    /// 用 `contentInset` 而不是改 `imageView.frame`：后者会被 UIScrollView 在缩放中重置。
    func centerContent() {
        guard let imageView else { return }
        let scaled = imageView.frame.size
        let horizontal = max((bounds.width - scaled.width) / 2, 0)
        let vertical = max((bounds.height - scaled.height) / 2, 0)
        contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        lastCenteredBounds = bounds.size
    }
}
