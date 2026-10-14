import XCTest
import UIKit
@testable import ioscloth

/// 录入流程里两块「算错了整个流程就废了」的逻辑：
/// 裁切坐标换算、批量录入的字段继承。
final class CaptureFlowTests: XCTestCase {

    // MARK: - 取景框对应的图片边长

    /// 在「刚好填满」的基准缩放下，取景框覆盖的图片边长 = cropSide / fitScale
    func testCropSideAtFitScale() {
        // 预览 675×1200 放进 340 的取景框 → fitScale = 340/675 ≈ 0.5037
        let fitScale = 340.0 / 675.0
        let side = ImageCropper.cropSideInImage(cropSide: 340, zoomScale: fitScale, fitScale: fitScale)

        XCTAssertEqual(side, 675, accuracy: 0.01, "填满时取景框正好覆盖图片窄边")
        XCTAssertGreaterThan(side, 0)
    }

    /// 放大之后取景框覆盖的图片边长变小（等于看得更细）
    func testCropSideShrinksWhenZoomingIn() {
        let fitScale = 340.0 / 675.0
        let side = ImageCropper.cropSideInImage(cropSide: 340, zoomScale: fitScale * 2, fitScale: fitScale)

        XCTAssertEqual(side, 675 / 2, accuracy: 0.01)
    }

    /// 缩放小于基准时应该夹住 —— 否则会裁出比取景框更大的区域
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
        XCTAssertTrue(ImageCropper.cropSideInImage(cropSide: 340, zoomScale: .infinity, fitScale: 1) >= 0)
    }

    /// 关键回归：无论怎么缩放、什么设备尺寸，裁切边长都必须有限且为正
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
            XCTAssertLessThanOrEqual(side, 675 + 0.01, "不该超过图片窄边")
        }
    }

    // MARK: - 图片边长映射

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

    /// 填满状态下裁切：结果是正方形，且分辨率取自原图而不是缩略图
    func testCropProducesSquareImageAtOriginalResolution() {
        let originalSize = CGSize(width: 3000, height: 4000)
        let original = Self.makeImage(size: originalSize)
        let preview = original.resized(maxDimension: ImageCropper.previewMaxDimension)

        let cropSide: CGFloat = 340
        let fitScale = max(cropSide / preview.size.width, cropSide / preview.size.height)

        let result = ImageCropper.crop(
            from: original,
            preview: preview,
            cropSide: cropSide,
            zoomScale: fitScale,
            fitScale: fitScale
        )

        XCTAssertEqual(result.size.width, result.size.height, accuracy: 2, "结果必须是正方形")
        XCTAssertGreaterThan(
            result.size.width,
            ImageCropper.previewMaxDimension,
            "裁切结果必须取自原图，不能只是缩略图的分辨率"
        )
    }

    /// 放大后能切出的像素更少（说明缩放真的影响了裁切范围）
    func testZoomedInCropProducesFewerPixels() {
        let original = Self.makeImage(size: CGSize(width: 3000, height: 4000))
        let preview = original.resized(maxDimension: ImageCropper.previewMaxDimension)
        let cropSide: CGFloat = 340
        let fitScale = max(cropSide / preview.size.width, cropSide / preview.size.height)

        let fit = ImageCropper.crop(
            from: original, preview: preview, cropSide: cropSide,
            zoomScale: fitScale, fitScale: fitScale
        )
        let zoomedIn = ImageCropper.crop(
            from: original, preview: preview, cropSide: cropSide,
            zoomScale: fitScale * 3, fitScale: fitScale
        )

        XCTAssertLessThan(zoomedIn.size.width, fit.size.width)
    }

    /// 换算异常时必须退回整张原图，而不是返回 nil 让「完成」变成没反应
    func testCropFallsBackToOriginalWhenScaleIsDegenerate() {
        let original = Self.makeImage(size: CGSize(width: 1200, height: 900))

        let noFit = ImageCropper.crop(
            from: original, preview: original, cropSide: 340, zoomScale: 1, fitScale: 0
        )
        XCTAssertEqual(noFit.size.width, 1200, accuracy: 1)

        let noCropSide = ImageCropper.crop(
            from: original, preview: original, cropSide: 0, zoomScale: 1, fitScale: 1
        )
        XCTAssertEqual(noCropSide.size.width, 1200, accuracy: 1)
    }

    private static func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 批量录入的字段继承

    private func makeFilledDraft() -> ClothingEditView.Draft {
        var draft = ClothingEditView.Draft()
        draft.name = "黑色羊毛大衣"
        draft.category = .outerwear
        draft.subcategory = "大衣"
        draft.colorName = "黑色"
        draft.brand = "某品牌"
        draft.seasons = [.winter, .autumn]
        draft.tempMin = -5
        draft.tempMax = 10
        draft.isLayerable = true
        draft.styleTags = [.commute, .formal]
        draft.isFavorite = true
        draft.status = .wearing
        draft.note = "袖口有点旧了"
        return draft
    }

    func testInheritedCarriesOverSeasonTemperatureAndStyle() {
        let next = makeFilledDraft().inherited()

        XCTAssertEqual(next.seasons, [.winter, .autumn], "同一季的衣服，季节应该沿用")
        XCTAssertEqual(next.tempMin, -5)
        XCTAssertEqual(next.tempMax, 10)
        XCTAssertEqual(next.styleTags, [.commute, .formal])
        XCTAssertEqual(next.category, .outerwear)
        XCTAssertEqual(next.colorName, "黑色")
        XCTAssertEqual(next.brand, "某品牌")
        XCTAssertEqual(next.isLayerable, true)
        XCTAssertEqual(next.status, .wearing)
    }

    func testInheritedDeliberatelyDropsPerItemFields() {
        let next = makeFilledDraft().inherited()

        XCTAssertTrue(next.name.isEmpty, "每件的名称都不一样，不该继承")
        XCTAssertTrue(next.subcategory.isEmpty, "子类每件都不一样（大衣 vs 羽绒服）")
        XCTAssertFalse(next.isFavorite, "「标为常用」是偏个人的标记，默认不带过去")
        XCTAssertTrue(next.note.isEmpty, "备注是这一件特有的")
    }

    func testInheritedDraftAppliesCleanlyToANewItem() {
        var next = makeFilledDraft().inherited()
        next.name = "米色羽绒服"
        next.subcategory = "羽绒服"

        let item = Clothing()
        next.apply(to: item)

        XCTAssertEqual(item.name, "米色羽绒服")
        XCTAssertEqual(item.subcategory, "羽绒服")
        XCTAssertEqual(item.seasons, [.winter, .autumn])
        XCTAssertEqual(item.temperatureLabel, "-5–10°C")
        XCTAssertEqual(item.category, .outerwear)
        XCTAssertTrue(item.isLayerable)
    }

    /// 空草稿继承出来还是空草稿（第一件录完是空的，跟不跟没区别）
    func testEmptyDraftInheritsToEmptyDraft() {
        let next = ClothingEditView.Draft().inherited()
        XCTAssertTrue(next.seasons.isEmpty)
        XCTAssertTrue(next.styleTags.isEmpty)
        XCTAssertEqual(next.tempMin, 15)
        XCTAssertEqual(next.tempMax, 26)
    }

    func testDraftFromClothingRoundTrips() {
        let item = Clothing(
            name: "藏青风衣",
            category: .outerwear,
            subcategory: "风衣",
            seasons: [.spring, .autumn],
            tempMin: 8,
            tempMax: 20,
            isLayerable: false,
            colorName: "藏青",
            styleTags: [.commute],
            status: .stored
        )
        item.note = "换季收起来"
        item.isFavorite = true

        let draft = ClothingEditView.Draft(item)

        XCTAssertEqual(draft.name, "藏青风衣")
        XCTAssertEqual(draft.seasons, [.spring, .autumn])
        XCTAssertEqual(draft.tempMin, 8)
        XCTAssertEqual(draft.tempMax, 20)
        XCTAssertEqual(draft.styleTags, [.commute])
        XCTAssertEqual(draft.status, .stored)
        XCTAssertEqual(draft.note, "换季收起来")
        XCTAssertTrue(draft.isFavorite)
    }

    /// 最低温高于最高温时，写回对象要自动纠正（用户拖动 Stepper 有可能造成这种状态）
    func testApplyNormalizesInvertedTemperatureRange() {
        var draft = ClothingEditView.Draft()
        draft.tempMin = 30
        draft.tempMax = 10

        let item = Clothing()
        draft.apply(to: item)

        XCTAssertEqual(item.tempMin, 10)
        XCTAssertEqual(item.tempMax, 30)
    }

    // MARK: - 照片方向

    func testUprightKeepsSizeForAlreadyUprightImage() {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 80), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 40, height: 80))
        }
        XCTAssertEqual(image.imageOrientation, .up)

        let upright = image.upright()
        XCTAssertEqual(upright.size.width, 40, accuracy: 0.5)
        XCTAssertEqual(upright.size.height, 80, accuracy: 0.5)
    }
}
