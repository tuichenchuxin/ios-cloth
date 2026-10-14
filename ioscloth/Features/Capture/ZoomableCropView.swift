import SwiftUI
import UIKit

/// 可缩放平移的图片视图，缩放边界**严格等于**它的自身尺寸。
///
/// ## 关键约束：这个视图的尺寸必须和取景框完全一致
///
/// iOS 上所有成熟裁切器的共同做法都是这一条。原因：
/// `UIScrollView` 会把内容夹在 `[0, contentSize - bounds]` 之间，
/// **夹取边界就是这个视图的边界**。如果这个视图比取景框大（比如铺满整屏而
/// 取景框只占 88%），那么图片还能继续移动 `(视口 − 取景框) / 2` 的距离，
/// 但取景框已经到头了 —— 表现就是「贴着边缘的内容怎么也拖不进框」。
///
/// 所以调用方必须把它放在和取景框**同一个矩形**里，用 `.overlay` 或
/// `.frame` + `.offset` 对齐。
///
/// ## 缩放平移交给 UIKit，不自己写手势
///
/// 之前用 SwiftUI 的 `MagnifyGesture` / `DragGesture` 自己算，踩了两个坑：
/// 1. `startAnchor` 报的是**被缩放后的图片坐标系**，不是容器坐标 ——
///    拿它当容器坐标做锚定，补偿量完全错，表现是「无论捏哪里取景框都往同一方向漂」；
/// 2. 两个手势同时改同一份 offset，互相打架。
struct ZoomableCropView: UIViewRepresentable {
    let image: UIImage
    /// 用户缩放 / 平移变化时上报当前变换
    let onTransformChange: (CropTransform) -> Void
    /// 装配完成后上报「刚好填满」的基准缩放
    let onFit: (CGFloat) -> Void

    func makeUIView(context: Context) -> CropScrollView {
        let scrollView = CropScrollView()
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.bouncesZoom = true
        scrollView.bounces = true
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

/// 负责缩放平移的 `UIScrollView`。
///
/// **不使用 `contentInset` 做居中**。标准的「小内容居中」做法（改 inset）会引入
/// 「inset 是否算进夹取范围」这类要靠实验才能确定的语义，而且 inset 在缩放过程中
/// 反复变化会干扰手势。这里改成在 `layoutSubviews` 里直接摆正 `imageView` 的位置：
/// 内容比自身小就居中，比自身大就把内容原点对齐自身原点 —— 两种情况的
/// 夹取边界都精确落在自身边界上。
final class CropScrollView: UIScrollView, UIScrollViewDelegate {
    var image: UIImage? {
        didSet { setNeedsLayout() }
    }

    var onTransform: ((CropTransform) -> Void)?
    var onFit: ((CGFloat) -> Void)?

    private var imageView: UIImageView?
    private var isConfigured = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        // 先给一个合法的非零范围，避免系统在布局前就把手势禁掉
        minimumZoomScale = 1
        maximumZoomScale = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureIfNeeded()
        positionImageView()
        report()
    }

    /// 装配图片并设置缩放范围。必须等到 bounds 有效（`makeUIView` 时还是 zero）。
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

        // 「刚好填满」的基准缩放：保证两个方向都盖住自身，不会露白边
        let fitScale = max(bounds.width / image.size.width, bounds.height / image.size.height)
        guard fitScale.isFinite, fitScale > 0 else { return }

        minimumZoomScale = fitScale
        maximumZoomScale = fitScale * 8
        zoomScale = fitScale
        isConfigured = true

        onFit?(fitScale)
    }

    /// 摆正图片位置：比自身小就居中，比自身大就原点对齐。
    ///
    /// 这样夹取边界永远精确等于自身边界 —— 图片的上/下/左/右边缘都能拖到框边。
    private func positionImageView() {
        guard let imageView else { return }
        let scaled = imageView.frame.size
        imageView.frame.origin = CGPoint(
            x: scaled.width < bounds.width ? (bounds.width - scaled.width) / 2 : 0,
            y: scaled.height < bounds.height ? (bounds.height - scaled.height) / 2 : 0
        )
    }

    /// 图片视图当前的 frame（单测诊断用）
    var imageViewFrame: CGRect { imageView?.frame ?? .zero }

    /// 当前变换。上报和单测共用同一份构造，避免两边算法漂移。
    var currentTransform: CropTransform {
        CropTransform(
            zoomScale: zoomScale,
            contentOffset: contentOffset,
            viewportSize: bounds.size
        )
    }

    private func report() {
        onTransform?(currentTransform)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        positionImageView()
        report()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        report()
    }
}
