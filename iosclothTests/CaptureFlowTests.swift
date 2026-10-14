import XCTest
import SwiftUI
import UIKit
@testable import ioscloth

/// 录入流程里两块「算错了整个流程就废了」的逻辑：
/// 裁切坐标换算、批量录入的字段继承。
final class CaptureFlowTests: XCTestCase {

    // MARK: - 裁切坐标（预览图坐标系）

    /// 竖图：最小缩放填满正方形后，裁出来应该是预览图中间一个正方形
    func testCropRectOnPortraitPreviewIsCenteredSquare() {
        let previewSize = CGSize(width: 1000, height: 2000)
        let cropSide: CGFloat = 300
        let scale = max(cropSide / previewSize.width, cropSide / previewSize.height) // 0.3

        let rect = ImageCropper.cropRect(
            previewSize: previewSize,
            offset: .zero,
            scale: scale,
            cropSide: cropSide
        )

        XCTAssertEqual(rect.width, 1000, accuracy: 0.01, "300 / 0.3 = 1000，正好是预览图宽度")
        XCTAssertEqual(rect.height, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 500, accuracy: 0.01, "水平居中")
        XCTAssertEqual(rect.midY, 1000, accuracy: 0.01, "垂直居中")
    }

    func testCropRectOnLandscapePreviewIsCenteredSquare() {
        let previewSize = CGSize(width: 2000, height: 1000)
        let cropSide: CGFloat = 300
        let scale = max(cropSide / previewSize.width, cropSide / previewSize.height) // 0.3

        let rect = ImageCropper.cropRect(
            previewSize: previewSize,
            offset: .zero,
            scale: scale,
            cropSide: cropSide
        )

        XCTAssertEqual(rect.width, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.height, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.midY, 500, accuracy: 0.01)
    }

    /// 裁切结果必须始终是正方形 —— 不然图墙上会出现各种怪异长宽比
    func testCropRectIsAlwaysSquareWhenWithinBounds() {
        let previewSize = CGSize(width: 1000, height: 2000)

        for offsetX in stride(from: -200.0, through: 200.0, by: 50.0) {
            let rect = ImageCropper.cropRect(
                previewSize: previewSize,
                offset: CGSize(width: offsetX, height: 0),
                scale: 1,
                cropSide: 300
            )
            XCTAssertEqual(rect.width, rect.height, accuracy: 0.01, "offsetX=\(offsetX) 时不是正方形")
        }
    }

    /// 往右拖（offset 为正）应该让取景窗在图上往左移
    func testPositiveOffsetMovesCropWindowLeft() {
        let previewSize = CGSize(width: 2000, height: 2000)
        let centered = ImageCropper.cropRect(previewSize: previewSize, offset: .zero, scale: 1, cropSide: 300)
        let dragged = ImageCropper.cropRect(
            previewSize: previewSize,
            offset: CGSize(width: 100, height: 0),
            scale: 1,
            cropSide: 300
        )

        XCTAssertLessThan(dragged.midX, centered.midX)
        XCTAssertEqual(dragged.midY, centered.midY, accuracy: 0.01)
    }

    /// 拖到极限时结果不能跑出边界，更不能返回无穷大
    func testCropRectNeverExceedsBounds() {
        let previewSize = CGSize(width: 1000, height: 1200)
        let rect = ImageCropper.cropRect(
            previewSize: previewSize,
            offset: CGSize(width: 9999, height: -9999),
            scale: 1.5,
            cropSide: 300
        )

        XCTAssertTrue(rect.width.isFinite, "不能是 CGRect.infinite —— 那会拿去裁一张无穷大的图")
        XCTAssertTrue(rect.height.isFinite)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, previewSize.width)
        XCTAssertLessThanOrEqual(rect.maxY, previewSize.height)
    }

    func testCropRectFullyOutsidePreviewIsEmpty() {
        let rect = ImageCropper.cropRect(
            previewSize: CGSize(width: 1000, height: 1000),
            offset: CGSize(width: 100_000, height: 0),
            scale: 1,
            cropSide: 300
        )
        XCTAssertTrue(rect.isEmpty || rect == .zero)
        XCTAssertFalse(rect.width.isInfinite)
    }

    func testCropRectHandlesDegenerateInput() {
        XCTAssertEqual(ImageCropper.cropRect(previewSize: .zero, offset: .zero, scale: 1, cropSide: 300), .zero)
        XCTAssertEqual(
            ImageCropper.cropRect(previewSize: CGSize(width: 100, height: 100), offset: .zero, scale: 0, cropSide: 300),
            .zero
        )
        XCTAssertEqual(
            ImageCropper.cropRect(previewSize: CGSize(width: 100, height: 100), offset: .zero, scale: 1, cropSide: 0),
            .zero
        )
    }

    // MARK: - 预览图坐标 → 原图坐标

    /// 屏幕上用的是缩略图，但裁切结果必须按比例还原到全分辨率原图
    func testMapToOriginalScalesByWidthRatio() {
        let rectInPreview = CGRect(x: 100, y: 200, width: 400, height: 400)
        let mapped = ImageCropper.mapToOriginal(
            rectInPreview,
            previewSize: CGSize(width: 1200, height: 1600),
            originalSize: CGSize(width: 4032, height: 3024)
        )

        // 4032 / 1200 = 3.36
        XCTAssertEqual(mapped.origin.x, 336, accuracy: 1)
        XCTAssertEqual(mapped.origin.y, 672, accuracy: 1)
        XCTAssertEqual(mapped.width, 1344, accuracy: 1)
        XCTAssertEqual(mapped.height, 1344, accuracy: 1)
    }

    func testMapToOriginalIsIdentityWhenSizesMatch() {
        let rect = CGRect(x: 10, y: 20, width: 300, height: 300)
        let mapped = ImageCropper.mapToOriginal(
            rect,
            previewSize: CGSize(width: 800, height: 600),
            originalSize: CGSize(width: 800, height: 600)
        )
        XCTAssertEqual(mapped.origin.x, rect.origin.x, accuracy: 0.01)
        XCTAssertEqual(mapped.width, rect.width, accuracy: 0.01)
    }

    func testMapToOriginalHandlesDegenerateSizes() {
        XCTAssertEqual(
            ImageCropper.mapToOriginal(
                CGRect(x: 1, y: 1, width: 10, height: 10),
                previewSize: .zero,
                originalSize: CGSize(width: 100, height: 100)
            ),
            .zero
        )
    }

    // MARK: - 端到端：真的切出一张图

    /// 用「原图 + 缩略图」跑完整条链路，验证：
    /// 能切出图、是正方形、尺寸对应原图分辨率（不是缩略图分辨率）。
    func testCropProducesSquareImageAtOriginalResolution() {
        let originalSize = CGSize(width: 3000, height: 4000)
        let original = Self.makeImage(size: originalSize)
        let preview = original.resized(maxDimension: ImageCropper.previewMaxDimension)

        // 打开时的默认状态：居中、放大到刚好填满
        let cropSide: CGFloat = 300
        let scale = max(cropSide / preview.size.width, cropSide / preview.size.height)

        let result = ImageCropper.crop(
            from: original,
            preview: preview,
            offset: .zero,
            scale: scale,
            cropSide: cropSide
        )

        XCTAssertEqual(result.size.width, result.size.height, accuracy: 2, "结果必须是正方形")
        XCTAssertGreaterThan(
            result.size.width,
            ImageCropper.previewMaxDimension,
            "裁切结果必须取自原图，不能只是缩略图的分辨率"
        )
    }

    /// 换算异常时必须退回整张原图，而不是返回 nil 让「完成」变成没反应
    func testCropFallsBackToOriginalWhenTransformIsDegenerate() {
        let original = Self.makeImage(size: CGSize(width: 1200, height: 900))
        let result = ImageCropper.crop(
            from: original,
            preview: nil,
            offset: .zero,
            scale: 0,
            cropSide: 0
        )
        XCTAssertEqual(result.size.width, 1200, accuracy: 1)
        XCTAssertEqual(result.size.height, 900, accuracy: 1)
    }

    /// 正方形输入、居中裁切时，结果应该等于「预览图里那个正方形」按比例放大
    func testCropRectMatchesPreviewWindow() {
        let previewSize = CGSize(width: 1200, height: 1600)
        let cropSide: CGFloat = 300
        let scale = max(cropSide / previewSize.width, cropSide / previewSize.height) // 0.25

        let rect = ImageCropper.cropRect(
            previewSize: previewSize,
            offset: .zero,
            scale: scale,
            cropSide: cropSide
        )
        // 300 / 0.25 = 1200（宽度方向刚好铺满），所以裁切框是 1200×1200
        XCTAssertEqual(rect.width, 1200, accuracy: 1)
        XCTAssertEqual(rect.midX, 600, accuracy: 1)
        XCTAssertEqual(rect.midY, 800, accuracy: 1)
    }

    private static func makeImage(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
    }

    // MARK: - 捏合缩放：必须锚定在手指位置

    func testZoomedScaleRespectsMinimum() {
        // 想缩小到 0.1，但不能小于「刚好填满」的下限
        XCTAssertEqual(
            ImageCropper.zoomedScale(lastScale: 0.5, magnification: 0.2, minimumScale: 0.5),
            0.5,
            accuracy: 0.0001
        )
        XCTAssertEqual(
            ImageCropper.zoomedScale(lastScale: 1, magnification: 2, minimumScale: 0.5),
            2,
            accuracy: 0.0001
        )
    }

    /// 在正中心捏合时，锚点就是中心 → 偏移量不该变
    func testAnchorAtCenterKeepsOffsetUnchanged() {
        let result = ImageCropper.anchoredOffset(
            offset: CGSize(width: 30, height: -20),
            startAnchor: UnitPoint(x: 0.5, y: 0.5),
            cropSide: 300,
            fromScale: 1,
            toScale: 2
        )
        XCTAssertEqual(result.width, 30, accuracy: 0.0001)
        XCTAssertEqual(result.height, -20, accuracy: 0.0001)
    }

    /// 在右侧捏合放大时，偏移量要往左走 —— 让手指按住的点在屏幕上不动。
    /// 不锚定的话这里会是 0（图像以中心放大），视觉上就是「框往右漂」。
    func testAnchorOnRightMovesOffsetLeftWhenZoomingIn() {
        let result = ImageCropper.anchoredOffset(
            offset: .zero,
            startAnchor: UnitPoint(x: 1.0, y: 0.5),
            cropSide: 300,
            fromScale: 1,
            toScale: 2
        )
        // focal.width = (1.0 - 0.5) * 300 = 150
        // offset' = 0 + 150 * (1 - 2) = -150
        XCTAssertEqual(result.width, -150, accuracy: 0.0001)
        XCTAssertEqual(result.height, 0, accuracy: 0.0001)
    }

    func testAnchorOnLeftMovesOffsetRightWhenZoomingIn() {
        let result = ImageCropper.anchoredOffset(
            offset: .zero,
            startAnchor: UnitPoint(x: 0, y: 0.5),
            cropSide: 300,
            fromScale: 1,
            toScale: 2
        )
        XCTAssertEqual(result.width, 150, accuracy: 0.0001)
    }

    /// 缩小时方向相反
    func testAnchorOnRightMovesOffsetRightWhenZoomingOut() {
        let result = ImageCropper.anchoredOffset(
            offset: .zero,
            startAnchor: UnitPoint(x: 1.0, y: 0.5),
            cropSide: 300,
            fromScale: 2,
            toScale: 1
        )
        XCTAssertEqual(result.width, 150, accuracy: 0.0001)
    }

    /// 上下方向同理
    func testAnchorOnBottomMovesOffsetUpWhenZoomingIn() {
        let result = ImageCropper.anchoredOffset(
            offset: .zero,
            startAnchor: UnitPoint(x: 0.5, y: 1.0),
            cropSide: 300,
            fromScale: 1,
            toScale: 2
        )
        XCTAssertEqual(result.height, -150, accuracy: 0.0001)
        XCTAssertEqual(result.width, 0, accuracy: 0.0001)
    }

    /// 锚定后的偏移量必须仍然满足「图盖满取景框」。
    /// 这是实际报的 bug：放大后取景框跑出了可见区域。
    func testAnchoredOffsetStaysWithinPanLimits() {
        let previewSize = CGSize(width: 1200, height: 1600)
        let cropSide: CGFloat = 300
        let minScale = max(cropSide / previewSize.width, cropSide / previewSize.height)

        for anchorX in [0.0, 0.25, 0.5, 0.75, 1.0] {
            let zoomed = ImageCropper.zoomedScale(lastScale: minScale, magnification: 3, minimumScale: minScale)
            let anchored = ImageCropper.anchoredOffset(
                offset: .zero,
                startAnchor: UnitPoint(x: anchorX, y: 0.5),
                cropSide: cropSide,
                fromScale: minScale,
                toScale: zoomed
            )

            // 复刻 ImageCropper.clamped 的限制
            let maxX = max((previewSize.width * zoomed - cropSide) / 2, 0)
            XCTAssertLessThanOrEqual(
                abs(anchored.width), maxX + 0.0001,
                "anchorX=\(anchorX) 时偏移超界，取景框会跑出图片"
            )
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
