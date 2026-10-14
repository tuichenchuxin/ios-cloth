import XCTest
import UIKit
@testable import ioscloth

/// 录入流程里两块「算错了整个流程就废了」的逻辑：
/// 裁切坐标换算、批量录入的字段继承。
final class CaptureFlowTests: XCTestCase {

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
