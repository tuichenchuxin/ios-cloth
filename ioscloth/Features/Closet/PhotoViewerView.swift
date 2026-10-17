import SwiftUI
import UIKit

/// 要看的图片
struct PhotoViewerItem: Identifiable {
    let id = UUID()
    /// 主图文件名（优先用它，看得清细节）
    let mainName: String
    /// 缩略图文件名（主图缺失时兜底）
    let thumbName: String
    var title: String = ""

    init(mainName: String, thumbName: String, title: String = "") {
        self.mainName = mainName
        self.thumbName = thumbName
        self.title = title
    }

    init(clothing: Clothing) {
        self.init(mainName: clothing.imageFile, thumbName: clothing.thumbFile, title: clothing.displayName)
    }
}

/// 全屏看图：黑底、双指缩放、单指拖动、双击放大、下滑关闭。
///
/// 用 `UIScrollView` 而不是 SwiftUI 手势，理由和裁切页一样
/// （见 `ZoomableCropView` 顶部注释）：缩放锚定、边界回弹交给系统才可靠。
struct PhotoViewerView: View {
    let item: PhotoViewerItem

    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var dragOffset: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                ZoomablePhoto(image: image)
                    .ignoresSafeArea()
            } else {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .white.opacity(0.25))
                    .padding(16)
            }
            .accessibilityLabel("关闭")
        }
        .overlay(alignment: .bottom) {
            if !item.title.isEmpty {
                Text(item.title)
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.85))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.45), in: Capsule())
                    .padding(.bottom, 28)
            }
        }
        .gesture(
            DragGesture()
                .onChanged { value in
                    // 只认「明显向下」的拖动，避免和缩放时的平移打架
                    dragOffset = max(value.translation.height, 0)
                }
                .onEnded { value in
                    if value.translation.height > 130 {
                        dismiss()
                    } else {
                        withAnimation(.spring(duration: 0.2)) { dragOffset = 0 }
                    }
                }
        )
        .opacity(dragOffset > 0 ? max(1 - dragOffset / 600, 0.5) : 1)
        .task {
            // 优先读主图：全屏看图时细节更重要；主图缺失再退回缩略图
            if let main = await ImageStore.shared.load(named: item.mainName) {
                image = main
            } else {
                image = await ImageStore.shared.load(named: item.thumbName)
            }
        }
    }
}

// MARK: - 可缩放的图片

private struct ZoomablePhoto: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> PhotoScrollView {
        PhotoScrollView(image: image)
    }

    func updateUIView(_ scrollView: PhotoScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {}
}

/// 全屏看图用的滚动视图：初始「完整显示」，可放大到 6 倍。
///
/// 缩放范围必须在 `layoutSubviews` 里配 —— `makeUIView` 时 `bounds` 还是 zero，
/// 算出来的 fit 会是 0/NaN，`UIScrollView` 直接不工作（裁切页踩过同样的坑）。
final class PhotoScrollView: UIScrollView, UIScrollViewDelegate {
    private let imageView: UIImageView
    private var isConfigured = false

    init(image: UIImage) {
        imageView = UIImageView(image: image)
        super.init(frame: .zero)

        backgroundColor = .clear
        showsHorizontalScrollIndicator = false
        showsVerticalScrollIndicator = false
        bouncesZoom = true
        decelerationRate = .fast
        delegate = self

        imageView.frame = CGRect(origin: .zero, size: image.size)
        addSubview(imageView)
        contentSize = image.size

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        addGestureRecognizer(doubleTap)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        configureIfNeeded()
        centerImageView()
    }

    private func configureIfNeeded() {
        guard !isConfigured else { return }
        guard bounds.width > 1, bounds.height > 1,
              imageView.frame.width > 1, imageView.frame.height > 1 else { return }

        // 「完整显示」而不是「填满」：看图时希望一眼看到全貌
        let fitScale = min(bounds.width / imageView.frame.width, bounds.height / imageView.frame.height)
        guard fitScale.isFinite, fitScale > 0 else { return }

        minimumZoomScale = fitScale
        maximumZoomScale = fitScale * 6
        zoomScale = fitScale
        isConfigured = true
    }

    /// 内容比可视区小时居中（放大后不需要）
    private func centerImageView() {
        let scaled = imageView.frame.size
        imageView.frame.origin = CGPoint(
            x: max((bounds.width - scaled.width) / 2, 0),
            y: max((bounds.height - scaled.height) / 2, 0)
        )
    }

    @objc private func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
        if zoomScale > minimumZoomScale + 0.01 {
            setZoomScale(minimumZoomScale, animated: true)
            return
        }
        let point = recognizer.location(in: imageView)
        let target = min(minimumZoomScale * 2.5, maximumZoomScale)
        let size = bounds.size
        let rect = CGRect(
            x: point.x - size.width / 2 / target,
            y: point.y - size.height / 2 / target,
            width: size.width / target,
            height: size.height / target
        )
        zoom(to: rect, animated: true)
    }

    // MARK: UIScrollViewDelegate

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerImageView()
    }
}

// MARK: - 可点击的缩略图（点开全屏）

/// 缩略图 + 「点一下全屏看」。搭配卡和搭配列表里都用它。
struct TappablePhoto: View {
    let mainName: String
    let thumbName: String
    var title: String = ""
    var size: CGFloat
    var cornerRadius: CGFloat = 8

    @State private var viewerItem: PhotoViewerItem?

    var body: some View {
        Button {
            viewerItem = PhotoViewerItem(mainName: mainName, thumbName: thumbName, title: title)
        } label: {
            PhotoThumbnailView(thumbName: thumbName, mainName: mainName)
                .frame(width: size, height: size)
                .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title.isEmpty ? "查看大图" : "查看大图：\(title)")
        .fullScreenCover(item: $viewerItem) { item in
            PhotoViewerView(item: item)
        }
    }
}
