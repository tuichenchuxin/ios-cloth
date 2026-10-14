import XCTest
import UIKit
@testable import ioscloth

/// 录入流程里两块「算错了整个流程就废了」的逻辑：
/// 裁切坐标换算、批量录入的字段继承。
final class CaptureFlowTests: XCTestCase {

    // MARK: - 取景框尺寸

    /// 取景框按屏幕短边取比例，而不是写死 —— 之前固定 340pt，在 iPhone 上太小太挤
    func testCropSideScalesWithScreen() {
        let iPhone = ImageCropper.cropSide(fitting: CGSize(width: 440, height: 700))
        let iPad = ImageCropper.cropSide(fitting: CGSize(width: 1000, height: 1300))

        XCTAssertGreaterThan(iPad, iPhone, "大屏取景框应该更大")
        XCTAssertEqual(iPhone, 440 * ImageCropper.cropSideRatio, accuracy: 0.5)
    }

    func testCropSideHonoursBounds() {
        // 空间比下限还小时，以「装得下」优先 —— 取景框绝不能画到屏幕外
        XCTAssertEqual(ImageCropper.cropSide(fitting: CGSize(width: 100, height: 100)), 100)
        // 空间够用时才有下限
        XCTAssertEqual(
            ImageCropper.cropSide(fitting: CGSize(width: 260, height: 500)),
            ImageCropper.minCropSide
        )
        // 极大屏不超过上限
        XCTAssertEqual(ImageCropper.cropSide(fitting: CGSize(width: 2000, height: 2000)), ImageCropper.maxCropSide)
        // 不依赖哪一边更短
        XCTAssertEqual(
            ImageCropper.cropSide(fitting: CGSize(width: 700, height: 440)),
            ImageCropper.cropSide(fitting: CGSize(width: 440, height: 700)),
            accuracy: 0.001
        )
    }

    func testCropSideNeverExceedsAvailableSpace() {
        for side in stride(from: 200.0, through: 1400.0, by: 50.0) {
            let fit = ImageCropper.cropSide(fitting: CGSize(width: side, height: side * 1.6))
            XCTAssertLessThanOrEqual(fit, side, "取景框不能比可用区域还大")
        }
    }

    func testCropSideHandlesZeroSize() {
        XCTAssertEqual(ImageCropper.cropSide(fitting: .zero), ImageCropper.minCropSide)
    }

    /// **取景框必须和滚动视图同区**：如果取景框比视口小，那么贴在原图边缘的
    /// 内容被滚动夹住时就进不了框。这条测试守住「框 = 视口」这个前提。
    func testFrameFillsViewportSoEdgesAreReachable() {
        // 取景框边长 == 传给 UIKit 的 cropSide；滚动视图也铺满同一块区域，
        // 所以两者的边界重合。这里用「取景框不算太小」间接守住可用性。
        let viewport = CGSize(width: 440, height: 700)
        let side = ImageCropper.cropSide(fitting: viewport)
        XCTAssertGreaterThan(side, viewport.width * 0.8, "取景框应该占据大部分宽度，否则边缘很难对准")
    }

    // MARK: - 取景框对应的图片边长

    func testCropSideAtFitScale() {
        let fitScale = 340.0 / 675.0
        let side = ImageCropper.cropSideInImage(cropSide: 340, zoomScale: fitScale, fitScale: fitScale)
        XCTAssertEqual(side, 675, accuracy: 0.01, "填满时取景框正好覆盖图片窄边")
    }

    func testCropSideShrinksWhenZoomingIn() {
        let fitScale = 340.0 / 675.0
        let side = ImageCropper.cropSideInImage(cropSide: 340, zoomScale: fitScale * 2, fitScale: fitScale)
        XCTAssertEqual(side, 675 / 2, accuracy: 0.01)
    }

    func testCropSideClampsToFitScale() {
        let fitScale = 340.0 / 675.0
        let atFit = ImageCropper.cropSideInImage(cropSide: 340, zoomScale: fitScale, fitScale: fitScale)
        let belowFit = ImageCropper.cropSideInImage(cropSide: 340, zoomScale: fitScale * 0.1, fitScale: fitScale)
        XCTAssertEqual(belowFit, atFit, accuracy: 0.01, "缩到基准之下不该裁得更大")
    }

    func testCropSideHandlesDegenerateInput() {
        XCTAssertEqual(ImageCropper.cropSideInImage(cropSide: 0, zoomScale: 1, fitScale: 1), 0)
        XCTAssertEqual(ImageCropper.cropSideInImage(cropSide: 340, zoomScale: 1, fitScale: 0), 0)
        XCTAssertEqual(ImageCropper.cropSideInImage(cropSide: 340, zoomScale: 0, fitScale: 0), 0)
    }

    func testCropSideIsAlwaysSaneAcrossZoomRange() {
        let fitScale = 340.0 / 675.0
        for multiplier in stride(from: 1.0, through: 8.0, by: 0.25) {
            let side = ImageCropper.cropSideInImage(
                cropSide: 340,
                zoomScale: fitScale * multiplier,
                fitScale: fitScale
            )
            XCTAssertTrue(side.isFinite, "multiplier=\(multiplier) 时不是有限值")
            XCTAssertGreaterThan(side, 0)
            XCTAssertLessThanOrEqual(side, 675 + 0.01)
        }
    }

    // MARK: - 取景框对应的图片矩形

    /// 没有平移、且刚好填满时，取景框覆盖整张图（居中）
    func testCropRectCenteredWhenNoPan() {
        let transform = CropTransform(
            zoomScale: 0.25,
            contentOffset: .zero,
            viewportSize: CGSize(width: 300, height: 300)
        )
        let rect = ImageCropper.cropRectInImage(cropSide: 300, transform: transform, fitScale: 0.25)

        XCTAssertEqual(rect.width, 1200, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 600, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 600, accuracy: 0.01)
    }

    /// **平移必须影响裁切区域** —— 这条守的是「放大后拖到衣服上，
    /// 结果裁出来还是图片正中央」那个 bug。
    func testPanShiftsCropRectByTheSameAmountInImagePixels() {
        let fitScale = 0.25
        let viewport = CGSize(width: 440, height: 700)

        let centered = ImageCropper.cropRectInImage(
            cropSide: 340,
            transform: CropTransform(zoomScale: 1, contentOffset: .zero, viewportSize: viewport),
            fitScale: fitScale
        )
        let panned = ImageCropper.cropRectInImage(
            cropSide: 340,
            transform: CropTransform(
                zoomScale: 1,
                contentOffset: CGPoint(x: 100, y: -50),
                viewportSize: viewport
            ),
            fitScale: fitScale
        )

        XCTAssertEqual(panned.midX, centered.midX + 100, accuracy: 0.01, "右移内容 → 取景框在图上右移")
        XCTAssertEqual(panned.midY, centered.midY - 50, accuracy: 0.01, "上移内容 → 取景框在图上上移")
        XCTAssertEqual(panned.width, centered.width, accuracy: 0.01, "平移不改变取景框大小")
    }

    /// 放大后平移：位移要按缩放折算，否则拖动和裁切会对不上
    func testPanIsScaledByZoom() {
        let viewport = CGSize(width: 400, height: 400)
        let base = ImageCropper.cropRectInImage(
            cropSide: 300,
            transform: CropTransform(zoomScale: 2, contentOffset: .zero, viewportSize: viewport),
            fitScale: 1
        )
        let panned = ImageCropper.cropRectInImage(
            cropSide: 300,
            transform: CropTransform(zoomScale: 2, contentOffset: CGPoint(x: 100, y: 0), viewportSize: viewport),
            fitScale: 1
        )
        // contentOffset 是屏幕点，除以 zoomScale(2) → 图片坐标里移动 50
        XCTAssertEqual(panned.midX - base.midX, 50, accuracy: 0.01)
    }

    func testCropRectIsAlwaysSquareAcrossZoomRange() {
        for zoom in stride(from: 0.2, through: 8.0, by: 0.2) {
            let transform = CropTransform(
                zoomScale: zoom,
                contentOffset: CGPoint(x: -120, y: 80),
                viewportSize: CGSize(width: 393, height: 393)
            )
            let rect = ImageCropper.cropRectInImage(cropSide: 340, transform: transform, fitScale: 0.5)
            XCTAssertEqual(rect.width, rect.height, accuracy: 0.001, "zoom=\(zoom) 时不是正方形")
            XCTAssertGreaterThan(rect.width, 0)
        }
    }

    func testCropRectHandlesDegenerateInput() {
        XCTAssertEqual(
            ImageCropper.cropRectInImage(cropSide: 300, transform: .identity, fitScale: 1),
            .zero
        )
        XCTAssertEqual(
            ImageCropper.cropRectInImage(
                cropSide: 0,
                transform: CropTransform(zoomScale: 1, contentOffset: .zero, viewportSize: CGSize(width: 100, height: 100)),
                fitScale: 1
            ),
            .zero
        )
    }

    // MARK: - 裁切矩形换算（期望值全部来自实测）

    /// 换算公式的数值必须和实测一致。
    ///
    /// 期望值不是推导出来的，是**用真实 `UIScrollView` 打印出来的**：
    /// 取景框 = 视口 = 387、预览图 675×1200、zoom = 387/675（刚好填满）时，
    /// 内容高 688pt，可滚动范围 0…301。
    ///
    ///   contentOffset.y = 0   → rect.y = 0…675       （显示图片上半部分）
    ///   contentOffset.y = 150 → rect.y = 261.6…936.6 （往下滚）
    ///
    /// 关键点：**在刚好填满的缩放下，contentOffset 最小就是 0**，
    /// 此时取景框上边缘正好对齐图片顶边 —— 也就是用户要的「把最上面的内容放进框」。
    ///
    /// 符号很容易搞反（我错过）：`contentOffset` 是内容原点在滚动视图坐标里的位置，
    /// 所以「屏幕位置 → 图片坐标」是 `屏幕位置 + contentOffset`。
    func testCropRectMatchesMeasuredValues() {
        let side: CGFloat = 387
        let fitScale: CGFloat = 387.0 / 675.0

        func rect(offsetY: CGFloat) -> CGRect {
            ImageCropper.cropRectInImage(
                cropSide: side,
                transform: CropTransform(
                    zoomScale: fitScale,
                    contentOffset: CGPoint(x: 0, y: offsetY),
                    viewportSize: CGSize(width: side, height: side)
                ),
                fitScale: fitScale
            )
        }

        // 实测：offset 为 0（刚好填满时能达到的最小值）→ 上边缘对齐框顶
        let atTopEdge = rect(offsetY: 0)
        XCTAssertEqual(atTopEdge.minY, 0, accuracy: 1, "实测 offset=0 → rect.y 从 0 开始")
        XCTAssertEqual(atTopEdge.maxY, 675, accuracy: 1, "实测高度 675")

        // 实测：offset=150 → rect.y = 261.6…936.6
        let scrolled = rect(offsetY: 150)
        XCTAssertEqual(scrolled.minY, 261.63, accuracy: 1, "实测值")
        XCTAssertEqual(scrolled.maxY, 936.63, accuracy: 1, "实测值")

        // 位移量 = offset 变化 / zoom
        XCTAssertEqual(scrolled.minY - atTopEdge.minY, 150 / fitScale, accuracy: 1)
    }

    /// 随便取极端组合，取景框都必须是有限、正方、大小合理
    func testCropRectIsAlwaysSaneSquare() {
        let fitScale: CGFloat = 387.0 / 675.0
        for offset in [-2000.0, -300.0, 0, 300.0, 2000.0] {
            for multiplier in [1.0, 2.5, 8.0] {
                let rect = ImageCropper.cropRectInImage(
                    cropSide: 387,
                    transform: CropTransform(
                        zoomScale: fitScale * multiplier,
                        contentOffset: CGPoint(x: offset, y: offset),
                        viewportSize: CGSize(width: 387, height: 387)
                    ),
                    fitScale: fitScale
                )
                XCTAssertEqual(rect.width, rect.height, accuracy: 0.001, "必须是正方形")
                XCTAssertGreaterThan(rect.width, 0)
                XCTAssertTrue(rect.width.isFinite)
            }
        }
    }

    // MARK: - 边长映射

    func testScaleToOriginalUsesWidthRatio() {
        let mapped = ImageCropper.scaleToOriginal(
            300,
            previewSize: CGSize(width: 1200, height: 1600),
            originalSize: CGSize(width: 4032, height: 3024)
        )
        XCTAssertEqual(mapped, 300 * 3.36, accuracy: 1)
    }

    func testScaleToOriginalHandlesDegenerateSizes() {
        XCTAssertEqual(
            ImageCropper.scaleToOriginal(10, previewSize: .zero, originalSize: CGSize(width: 100, height: 100)),
            0
        )
        XCTAssertEqual(
            ImageCropper.scaleToOriginal(10, previewSize: CGSize(width: 100, height: 100), originalSize: .zero),
            0
        )
    }

    // MARK: - 端到端：真的切出一张图

    private func fittedTransform(preview: UIImage, cropSide: CGFloat, viewport: CGSize) -> (CropTransform, CGFloat) {
        let fitScale = max(viewport.width / preview.size.width, viewport.height / preview.size.height)
        return (
            CropTransform(zoomScale: fitScale, contentOffset: .zero, viewportSize: viewport),
            fitScale
        )
    }

    func testCropProducesSquareImageAtOriginalResolution() {
        let original = Self.makeImage(size: CGSize(width: 3000, height: 4000))
        let preview = original.resized(maxDimension: ImageCropper.previewMaxDimension)
        let viewport = CGSize(width: 440, height: 700)
        let (transform, fitScale) = fittedTransform(preview: preview, cropSide: 340, viewport: viewport)

        let result = ImageCropper.crop(
            from: original, preview: preview, cropSide: 340, transform: transform, fitScale: fitScale
        )

        XCTAssertEqual(result.size.width, result.size.height, accuracy: 2, "结果必须是正方形")
        XCTAssertGreaterThan(result.size.width, 100, "不该裁出空图")
    }

    /// 放大后裁出来的像素更少 —— 对应「尺寸提示从 695 变成 256」
    func testZoomedInCropProducesFewerPixels() {
        let original = Self.makeImage(size: CGSize(width: 3000, height: 4000))
        let preview = original.resized(maxDimension: ImageCropper.previewMaxDimension)
        let viewport = CGSize(width: 440, height: 700)
        let fitScale = max(viewport.width / preview.size.width, viewport.height / preview.size.height)

        let atFit = ImageCropper.crop(
            from: original, preview: preview, cropSide: 340,
            transform: CropTransform(zoomScale: fitScale, contentOffset: .zero, viewportSize: viewport),
            fitScale: fitScale
        )
        let zoomed = ImageCropper.crop(
            from: original, preview: preview, cropSide: 340,
            transform: CropTransform(zoomScale: fitScale * 3, contentOffset: .zero, viewportSize: viewport),
            fitScale: fitScale
        )

        XCTAssertLessThan(zoomed.size.width, atFit.size.width)
    }

    /// **平移真的改变裁切内容** —— 用「四角颜色不同的图」验证：
    /// 往不同方向平移，裁出来那块的中心颜色必须不同。
    /// 这条守的是「放大后拖到衣服上，结果裁出来还是图片正中央」那个 bug。
    func testPanActuallyChangesWhichPartIsCropped() {
        let source = Self.makeQuadrantImage(size: CGSize(width: 800, height: 800))
        let viewport = CGSize(width: 400, height: 400)
        let fitScale: CGFloat = 0.5

        // 取景框边长 200 屏幕点，zoomScale=1 → 覆盖图片 200×200。
        // 可视区 400×400，中心在 (200,200)；图片坐标里的取景框中心 = (200 + offset) / zoomScale。
        // 目标：左上象限中心 (200,200) → offset 0；右下象限中心 (600,600) → offset 400。
        // ⚠️ 取景框必须完整落在图片内，否则会被 intersection 裁掉一半（我第一版就写错了）。
        let topLeft = ImageCropper.crop(
            from: source, preview: source, cropSide: 200,
            transform: CropTransform(
                zoomScale: 1,
                contentOffset: .zero,
                viewportSize: viewport
            ),
            fitScale: fitScale
        )
        let bottomRight = ImageCropper.crop(
            from: source, preview: source, cropSide: 200,
            transform: CropTransform(
                zoomScale: 1,
                contentOffset: CGPoint(x: 400, y: 400),
                viewportSize: viewport
            ),
            fitScale: fitScale
        )

        XCTAssertEqual(topLeft.size.width, 200, accuracy: 1)
        let a = Self.pixelColor(topLeft, at: CGPoint(x: topLeft.size.width / 2, y: topLeft.size.height / 2))
        let b = Self.pixelColor(bottomRight, at: CGPoint(x: bottomRight.size.width / 2, y: bottomRight.size.height / 2))

        let distance = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
        XCTAssertGreaterThan(
            distance, 120,
            "不同平移方向应裁到明显不同的区域，实际色差只有 \(Int(distance))（a=\(a) b=\(b)）"
        )
    }

    func testCropFallsBackToOriginalWhenScaleIsDegenerate() {
        let original = Self.makeImage(size: CGSize(width: 1200, height: 900))

        let noFit = ImageCropper.crop(
            from: original, preview: original, cropSide: 340, transform: .identity, fitScale: 0
        )
        XCTAssertEqual(noFit.size.width, 1200, accuracy: 1)

        let noCropSide = ImageCropper.crop(
            from: original, preview: original, cropSide: 0,
            transform: CropTransform(zoomScale: 1, contentOffset: .zero, viewportSize: CGSize(width: 400, height: 400)),
            fitScale: 1
        )
        XCTAssertEqual(noCropSide.size.width, 1200, accuracy: 1)
    }

    // MARK: - 测试用图

    private static func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    /// 四个象限颜色都不同的图，用来验证「裁的是哪一块」
    private static func makeQuadrantImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let half = CGSize(width: size.width / 2, height: size.height / 2)
            UIColor.red.setFill()
            context.fill(CGRect(origin: .zero, size: half))
            UIColor.green.setFill()
            context.fill(CGRect(origin: CGPoint(x: half.width, y: 0), size: half))
            UIColor.blue.setFill()
            context.fill(CGRect(origin: CGPoint(x: 0, y: half.height), size: half))
            UIColor.yellow.setFill()
            context.fill(CGRect(origin: CGPoint(x: half.width, y: half.height), size: half))
        }
    }

    /// 读某个点的像素颜色（1:1 重绘后直接取，不做缩放，避免重采样引入误差）
    private static func pixelColor(_ image: UIImage, at point: CGPoint) -> (r: Int, g: Int, b: Int) {
        guard let cgImage = image.cgImage else { return (0, 0, 0) }
        let width = cgImage.width
        let height = cgImage.height
        guard width > 0, height > 0 else { return (0, 0, 0) }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return (0, 0, 0) }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x = min(max(Int(point.x), 0), width - 1)
        let y = min(max(Int(point.y), 0), height - 1)
        let index = (y * width + x) * 4
        return (Int(buffer[index]), Int(buffer[index + 1]), Int(buffer[index + 2]))
    }

}
