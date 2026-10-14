import XCTest
import UIKit
@testable import ioscloth

/// `CropScrollView` 的真实布局测试。
///
/// 这里防的是一类具体的回归：**缩放配置时机错了**。
/// 之前把缩放范围写在 `makeUIView` 里，那时视图还没进层级、`bounds` 是 zero，
/// 算出来的 `minimumZoomScale` 是 0/NaN —— `UIScrollView` 会因此完全不响应捏合，
/// 表现就是「取景框位置对了，但怎么捏都放不大」。
@MainActor
final class CropScrollViewTests: XCTestCase {

    private func makeScrollView(imageSize: CGSize, viewSide: CGFloat) -> CropScrollView {
        let scrollView = CropScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: viewSide, height: viewSide)
        scrollView.image = Self.makeImage(size: imageSize)
        // 触发布局（真实使用中由 UIKit 在入层级后触发）
        scrollView.layoutIfNeeded()
        return scrollView
    }

    func testZoomRangeIsConfiguredAfterLayout() {
        let scrollView = makeScrollView(imageSize: CGSize(width: 675, height: 1200), viewSide: 340)

        XCTAssertGreaterThan(scrollView.minimumZoomScale, 0, "最小缩放必须是正数，否则完全不响应捏合")
        XCTAssertTrue(scrollView.minimumZoomScale.isFinite, "最小缩放不能是 NaN/无穷")
        XCTAssertGreaterThan(scrollView.maximumZoomScale, scrollView.minimumZoomScale)
    }

    func testFitScaleFillsTheView() {
        let scrollView = makeScrollView(imageSize: CGSize(width: 675, height: 1200), viewSide: 340)

        // 填满 340 的正方形：宽 340、高 340 → 675 需要放大 340/675 ≈ 0.5037
        XCTAssertEqual(scrollView.minimumZoomScale, 340.0 / 675.0, accuracy: 0.001)
        XCTAssertEqual(scrollView.zoomScale, scrollView.minimumZoomScale, accuracy: 0.001,
                       "初始缩放应该正好填满取景框")
    }

    func testFitReportsBackToCaller() {
        var reportedFit: CGFloat = 0
        let scrollView = CropScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 340, height: 340)
        scrollView.onFit = { reportedFit = $0 }
        scrollView.image = Self.makeImage(size: CGSize(width: 675, height: 1200))
        scrollView.layoutIfNeeded()

        XCTAssertEqual(reportedFit, 340.0 / 675.0, accuracy: 0.001, "必须上报基准缩放，否则裁切算不出来")
    }

    func testZoomingChangesReportedTransformAndCropRegion() {
        let preview = Self.makeImage(size: CGSize(width: 675, height: 1200))
        var latest = CropTransform.identity
        let scrollView = CropScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 340, height: 340)
        scrollView.onTransform = { latest = $0 }
        scrollView.image = preview
        scrollView.layoutIfNeeded()

        let fitScale = scrollView.minimumZoomScale
        let sideAtFit = ImageCropper.cropSideInImage(cropSide: 340, zoomScale: fitScale, fitScale: fitScale)

        // 模拟用户捏合放大
        scrollView.zoomScale = fitScale * 3
        scrollView.layoutIfNeeded()

        XCTAssertEqual(latest.zoomScale, fitScale * 3, accuracy: 0.001, "缩放变化必须上报")
        XCTAssertEqual(latest.viewportSize.width, 340, accuracy: 0.01, "可视尺寸必须上报")
        XCTAssertLessThan(scrollView.zoomScale, scrollView.maximumZoomScale)

        let sideZoomed = ImageCropper.cropSideInImage(
            cropSide: 340,
            zoomScale: scrollView.zoomScale,
            fitScale: fitScale
        )
        XCTAssertLessThan(sideZoomed, sideAtFit, "放大后取景框覆盖的图片区域必须变小")
    }

    /// 平移必须上报，否则裁切拿不到「用户看到的是哪一块」
    func testPanIsReported() {
        var latest = CropTransform.identity
        let scrollView = CropScrollView()
        scrollView.frame = CGRect(x: 0, y: 0, width: 340, height: 340)
        scrollView.onTransform = { latest = $0 }
        scrollView.image = Self.makeImage(size: CGSize(width: 675, height: 1200))
        scrollView.layoutIfNeeded()

        // 放大到可以平移的程度
        scrollView.zoomScale = scrollView.minimumZoomScale * 3
        scrollView.layoutIfNeeded()
        scrollView.contentOffset = CGPoint(x: 40, y: 25)
        scrollView.layoutIfNeeded()

        XCTAssertEqual(latest.contentOffset.x, 40, accuracy: 1, "contentOffset 必须上报")
        XCTAssertEqual(latest.contentOffset.y, 25, accuracy: 1)
    }

    func testZoomScaleCannotGoBelowFit() {
        let scrollView = makeScrollView(imageSize: CGSize(width: 675, height: 1200), viewSide: 340)
        let fitScale = scrollView.minimumZoomScale

        scrollView.zoomScale = fitScale * 0.1
        scrollView.layoutIfNeeded()

        XCTAssertGreaterThanOrEqual(scrollView.zoomScale, fitScale - 0.001, "不允许缩到比「刚好填满」更小")
    }

    func testLandscapeImageAlsoConfiguresZoom() {
        let scrollView = makeScrollView(imageSize: CGSize(width: 1600, height: 900), viewSide: 340)
        XCTAssertEqual(scrollView.minimumZoomScale, 340.0 / 900.0, accuracy: 0.001)
        XCTAssertTrue(scrollView.minimumZoomScale.isFinite)
    }

    func testZeroBoundsDoesNotPoisonZoomRange() {
        // 视图还没拿到尺寸时不该把缩放范围设坏（这正是之前的 bug）
        let scrollView = CropScrollView()
        scrollView.image = Self.makeImage(size: CGSize(width: 675, height: 1200))
        scrollView.layoutIfNeeded()

        XCTAssertGreaterThan(scrollView.minimumZoomScale, 0)
        XCTAssertTrue(scrollView.minimumZoomScale.isFinite)
    }

    private static func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }
}
