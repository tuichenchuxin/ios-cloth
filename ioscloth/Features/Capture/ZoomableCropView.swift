import SwiftUI
import UIKit

/// 缩放平移的图片视图。**只有这一张图**，取景框之外的部分由上层压暗。
///
/// ## 关键设计：bounds = 取景框，但 `clipsToBounds = false`
///
/// 裁切交互有两个互相拉扯的需求：
/// 1. 框外要能看到照片（被压暗），这样知道主体在整张照片里的位置；
/// 2. 图片边缘要能被拖到取景框边上（否则贴边的部分永远裁不到）。
///
/// 常见做法「滚动视图铺满整屏 + 取景框当覆盖层」满足 1，但因为
/// `UIScrollView` 把内容夹在自身 bounds 内，图片上边缘最多只能到视口顶部，
/// **永远进不了比视口小的取景框** —— ①②冲突。
///
/// 现在的做法：
/// - 滚动视图的 frame **就是取景框**（bounds = 取景框）→ 夹取边界 == 取景框边界，
///   图片边缘能精确拖到框边（解决 ②）；
/// - 但把 `clipsToBounds` 关掉 → 图片内容会**溢出到框外继续绘制**，
///   再由上层 `CropOverlay` 把框外压暗（解决 ①）。
///
/// 这样**屏幕上始终只有一份图片**，缩放时框内外绝对不会错位。
/// （之前试过「框内滚动视图 + 框外再画一张同变换的图」，两张图必然错位，
/// SwiftUI 的重绘永远追不上 `UIScrollView` 内部的实时缩放。）
struct ZoomableCropView: UIViewRepresentable {
    let image: UIImage
    /// 用户缩放 / 平移变化时上报当前变换
    let onTransformChange: (CropTransform) -> Void
    /// 装配完成或取景框尺寸变化后上报「刚好填满」的基准缩放
    let onFit: (CGFloat) -> Void

    func makeUIView(context: Context) -> CropScrollView {
        let scrollView = CropScrollView()
        scrollView.backgroundColor = .clear
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

/// 负责缩放平移的 `UIScrollView`。
///
/// **不使用 `contentInset` 做居中**：inset 是否计入夹取范围要靠实验确定，
/// 而且缩放过程中反复变化会干扰手势。改成在 `layoutSubviews` 里直接摆正
/// `imageView` 的位置 —— 比自身小就居中，比自身大则原点对齐。
final class CropScrollView: UIScrollView, UIScrollViewDelegate {
    var image: UIImage? {
        didSet { setNeedsLayout() }
    }

    var onTransform: ((CropTransform) -> Void)?
    var onFit: ((CGFloat) -> Void)?

    private var imageView: UIImageView?
    private var isConfigured = false
    private var lastBoundsSize: CGSize = .zero

    override init(frame: CGRect) {
        super.init(frame: frame)
        delegate = self
        // 让图片溢出到取景框之外继续绘制（框外由上层压暗）
        clipsToBounds = false
        // 先给一个合法的非零范围，避免系统在布局前就把手势禁掉
        minimumZoomScale = 1
        maximumZoomScale = 8
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureIfNeeded()
        if bounds.size != lastBoundsSize {
            lastBoundsSize = bounds.size
            applyFitScale()
        }
        positionImageView()
        report()
    }

    /// 装配图片。必须等到 bounds 有效（`makeUIView` 时还是 zero）。
    private func configureIfNeeded() {
        guard let image, !isConfigured else { return }
        guard bounds.width > 1, bounds.height > 1, image.size.width > 1, image.size.height > 1 else {
            return
        }

        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFill
        imageView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(imageView)
        self.imageView = imageView
        contentSize = image.size
        isConfigured = true
    }

    /// 按当前 bounds 重算缩放范围。取景框被拖动改大小时会走到这里。
    private func applyFitScale() {
        guard let imageView else { return }
        guard bounds.width > 1, bounds.height > 1 else { return }

        let fitScale = max(bounds.width / imageView.frame.width, bounds.height / imageView.frame.height)
        guard fitScale.isFinite, fitScale > 0 else { return }

        minimumZoomScale = fitScale
        maximumZoomScale = fitScale * 8
        // 取景框变小后原来的缩放可能低于新下限，夹住
        if zoomScale < fitScale { zoomScale = fitScale }
        onFit?(fitScale)
    }

    /// 摆正图片位置：比自身小就居中，比自身大则原点对齐。
    /// 这样夹取边界永远精确等于自身边界 —— 图片的上/下/左/右边缘都能拖到框边。
    private func positionImageView() {
        guard let imageView else { return }
        let scaled = imageView.frame.size
        imageView.frame.origin = CGPoint(
            x: scaled.width < bounds.width ? (bounds.width - scaled.width) / 2 : 0,
            y: scaled.height < bounds.height ? (bounds.height - scaled.height) / 2 : 0
        )
    }

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
