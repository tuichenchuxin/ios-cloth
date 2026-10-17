import XCTest
import UIKit
@testable import ioscloth

/// 拍照模板的几何与裁切。
///
/// 蒙层是「构图引导」，所以关键是：**用户看到框住的范围 == 最终存下来的范围**。
/// 这条一致性靠 `frameRect`（画框）和 `normalizedCropRect`（裁切）严格对应来保证。
final class GarmentTemplateTests: XCTestCase {

    // MARK: - 取景框

    /// 预览和照片长宽比一致时，换算结果就是屏幕比例
    func testNormalizedCropRectWhenAspectMatches() {
        let size = CGSize(width: 1000, height: 1000)
        let frame = GarmentTemplate.frameRect(in: size)
        let rect = GarmentTemplate.normalizedCropRect(photoSize: size, previewSize: size, frameRect: frame)

        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 0.5, accuracy: 0.001)
        XCTAssertEqual(rect.width, rect.height, accuracy: 0.001)
        XCTAssertEqual(rect.width, 0.86, accuracy: 0.01)
    }

    /// **相机 4:3、屏幕更长** 时，换算后仍必须覆盖照片里的一块正方形。
    /// 之前用固定归一化矩形，这条会失败（裁出来是长方形）。
    func testNormalizedCropRectIsSquareInPhotoEvenWhenAspectDiffers() {
        let photo = CGSize(width: 3024, height: 4032)          // 相机竖拍 3:4
        let preview = CGSize(width: 440, height: 900)          // 全面屏
        let frame = GarmentTemplate.frameRect(in: preview)

        let rect = GarmentTemplate.normalizedCropRect(photoSize: photo, previewSize: preview, frameRect: frame)

        // 换算成照片像素后应该是正方形
        let pixelWidth = rect.width * photo.width
        let pixelHeight = rect.height * photo.height
        XCTAssertEqual(pixelWidth, pixelHeight, accuracy: 2, "照片里必须是正方形")
        XCTAssertLessThanOrEqual(rect.maxX, 1.0001)
        XCTAssertLessThanOrEqual(rect.maxY, 1.0001)
        XCTAssertGreaterThanOrEqual(rect.minX, -0.0001)
        XCTAssertGreaterThanOrEqual(rect.minY, -0.0001)
    }

    /// 屏幕上的框在预览里居中 → 换算到照片里也居中
    func testNormalizedCropRectIsCentered() {
        let photo = CGSize(width: 3000, height: 4000)
        let preview = CGSize(width: 400, height: 800)
        let frame = GarmentTemplate.frameRect(in: preview)
        let rect = GarmentTemplate.normalizedCropRect(photoSize: photo, previewSize: preview, frameRect: frame)

        XCTAssertEqual(rect.midX, 0.5, accuracy: 0.001)
        XCTAssertEqual(rect.midY, 0.5, accuracy: 0.001)
    }

    func testNormalizedCropRectHandlesZeroSizes() {
        XCTAssertEqual(
            GarmentTemplate.normalizedCropRect(photoSize: .zero, previewSize: CGSize(width: 400, height: 800), frameRect: .zero),
            .zero
        )
        XCTAssertEqual(
            GarmentTemplate.normalizedCropRect(photoSize: CGSize(width: 100, height: 100), previewSize: .zero, frameRect: .zero),
            .zero
        )
    }

    func testFrameRectFitsInsidePreview() {
        for size in [CGSize(width: 390, height: 844), CGSize(width: 844, height: 390)] {
            let frame = GarmentTemplate.frameRect(in: size)
            XCTAssertGreaterThan(frame.minX, 0)
            XCTAssertGreaterThan(frame.minY, 0)
            XCTAssertLessThanOrEqual(frame.maxX, size.width)
            XCTAssertLessThanOrEqual(frame.maxY, size.height)
        }
    }

    // MARK: - 轮廓

    /// 轮廓必须画在取景框里面（否则用户会对着框外的线摆姿势）
    func testSilhouetteStaysInsideFrame() {
        let frame = CGRect(x: 20, y: 100, width: 350, height: 350)

        for template in GarmentTemplate.allCases {
            let bounds = template.silhouette(in: frame).boundingRect
            XCTAssertGreaterThanOrEqual(bounds.minX, frame.minX - 1, "\(template.displayName) 轮廓越界")
            XCTAssertGreaterThanOrEqual(bounds.minY, frame.minY - 1, "\(template.displayName) 轮廓越界")
            XCTAssertLessThanOrEqual(bounds.maxX, frame.maxX + 1, "\(template.displayName) 轮廓越界")
            XCTAssertLessThanOrEqual(bounds.maxY, frame.maxY + 1, "\(template.displayName) 轮廓越界")
        }
    }

    func testEachTemplateHasDistinctSilhouette() {
        let frame = CGRect(x: 0, y: 0, width: 300, height: 300)
        let topBounds = GarmentTemplate.top.silhouette(in: frame).boundingRect
        let bottomBounds = GarmentTemplate.bottom.silhouette(in: frame).boundingRect

        XCTAssertFalse(topBounds.isEmpty)
        XCTAssertFalse(bottomBounds.isEmpty)
        // 上衣有袖子和领口、下衣是两条腿，两者形状不该完全一致
        XCTAssertNotEqual(topBounds, bottomBounds)
    }

    // MARK: - 裁切

    func testCropTakesTheFramedPortion() {
        let image = Self.makeImage(size: CGSize(width: 1000, height: 1000))
        let cropped = GarmentTemplate.crop(image, toNormalized: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))

        XCTAssertEqual(cropped.size.width, 500, accuracy: 1)
        XCTAssertEqual(cropped.size.height, 500, accuracy: 1)
    }

    /// 走完整链路：预览 440×900、照片 1200×1600 → 裁出来必须是正方形
    func testCropThroughPreviewMappingIsSquare() {
        let photo = Self.makeImage(size: CGSize(width: 1200, height: 1600))
        let preview = CGSize(width: 440, height: 900)
        let frame = GarmentTemplate.frameRect(in: preview)

        let rect = GarmentTemplate.normalizedCropRect(
            photoSize: photo.size, previewSize: preview, frameRect: frame
        )
        let cropped = GarmentTemplate.crop(photo, toNormalized: rect)

        XCTAssertEqual(cropped.size.width, cropped.size.height, accuracy: 2, "模板裁出来的必须是正方形")
        XCTAssertGreaterThan(cropped.size.width, 100, "不该裁出空图")
    }

    func testCropWithFullRectKeepsSize() {
        let image = Self.makeImage(size: CGSize(width: 800, height: 600))
        let cropped = GarmentTemplate.crop(image, toNormalized: CGRect(x: 0, y: 0, width: 1, height: 1))

        XCTAssertEqual(cropped.size.width, 800, accuracy: 1)
        XCTAssertEqual(cropped.size.height, 600, accuracy: 1)
    }

    /// 非法矩形不能崩，也不能返回空图
    func testCropWithDegenerateRectFallsBack() {
        let image = Self.makeImage(size: CGSize(width: 400, height: 400))
        let cropped = GarmentTemplate.crop(image, toNormalized: .zero)

        XCTAssertGreaterThan(cropped.size.width, 0)
        XCTAssertGreaterThan(cropped.size.height, 0)
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
