import XCTest
import UIKit
@testable import ioscloth

/// 录入流程里两块「算错了整个流程就废了」的逻辑：
/// 裁切坐标换算、批量录入的字段继承。
final class CaptureFlowTests: XCTestCase {

    // MARK: - 裁切坐标

    /// 竖图：最小缩放填满正方形后，裁出来应该是图像中间一个正方形
    func testCropRectOnPortraitImageIsCenteredSquare() {
        let source = CGSize(width: 1000, height: 2000)
        let cropSide: CGFloat = 300
        let scale = max(cropSide / source.width, cropSide / source.height) // = 0.3

        let rect = ImageCropper.cropRect(
            sourceSize: source,
            offset: .zero,
            scale: scale,
            cropSide: cropSide
        )

        XCTAssertEqual(rect.width, 1000, accuracy: 0.01, "300 / 0.3 = 1000，正好是图的宽度")
        XCTAssertEqual(rect.height, 1000, accuracy: 0.01)
        XCTAssertEqual(rect.midX, 500, accuracy: 0.01, "水平居中")
        XCTAssertEqual(rect.midY, 1000, accuracy: 0.01, "垂直居中")
    }

    /// 横图：正方形应该按高度算，并且水平居中
    func testCropRectOnLandscapeImageIsCenteredSquare() {
        let source = CGSize(width: 2000, height: 1000)
        let cropSide: CGFloat = 300
        let scale = max(cropSide / source.width, cropSide / source.height) // = 0.3

        let rect = ImageCropper.cropRect(
            sourceSize: source,
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
        let source = CGSize(width: 1000, height: 2000)
        let cropSide: CGFloat = 300
        let scale: CGFloat = 1.0   // 放大到 1.0，300pt 对应原图 300px

        for offsetX in stride(from: -200.0, through: 200.0, by: 50.0) {
            let rect = ImageCropper.cropRect(
                sourceSize: source,
                offset: CGSize(width: offsetX, height: 0),
                scale: scale,
                cropSide: cropSide
            )
            XCTAssertEqual(rect.width, rect.height, accuracy: 0.01, "offsetX=\(offsetX) 时不是正方形")
        }
    }

    /// 往右拖（offset 为正）应该让裁切框在图上往左移
    func testPositiveOffsetMovesCropWindowLeftOnSource() {
        let source = CGSize(width: 2000, height: 2000)

        let centered = ImageCropper.cropRect(sourceSize: source, offset: .zero, scale: 1, cropSide: 300)
        let dragged = ImageCropper.cropRect(
            sourceSize: source,
            offset: CGSize(width: 100, height: 0),
            scale: 1,
            cropSide: 300
        )

        XCTAssertLessThan(dragged.midX, centered.midX, "往右拖是把图往右推，取景窗相对图往左走")
        XCTAssertEqual(dragged.midY, centered.midY, accuracy: 0.01)
    }

    /// 拖到极限时结果不能跑出图像边界，更不能返回无穷大
    func testCropRectNeverExceedsSourceBounds() {
        let source = CGSize(width: 1000, height: 1200)
        let rect = ImageCropper.cropRect(
            sourceSize: source,
            offset: CGSize(width: 9999, height: -9999),
            scale: 1.5,
            cropSide: 300
        )

        XCTAssertTrue(rect.width.isFinite, "不能是 CGRect.infinite —— 那会拿去裁一张无穷大的图")
        XCTAssertTrue(rect.height.isFinite)
        XCTAssertGreaterThanOrEqual(rect.minX, 0)
        XCTAssertGreaterThanOrEqual(rect.minY, 0)
        XCTAssertLessThanOrEqual(rect.maxX, source.width)
        XCTAssertLessThanOrEqual(rect.maxY, source.height)
    }

    /// 取景框完全跑到图外面时应该返回空矩形（此时不该裁切）
    func testCropRectFullyOutsideSourceIsEmpty() {
        let rect = ImageCropper.cropRect(
            sourceSize: CGSize(width: 1000, height: 1000),
            offset: CGSize(width: 100_000, height: 0),
            scale: 1,
            cropSide: 300
        )
        XCTAssertTrue(rect.isEmpty || rect == .zero)
        XCTAssertFalse(rect.width.isInfinite)
    }

    /// 非法输入应该返回零矩形而不是崩 / 返回 NaN
    func testCropRectHandlesDegenerateInput() {
        XCTAssertEqual(ImageCropper.cropRect(sourceSize: .zero, offset: .zero, scale: 1, cropSide: 300), .zero)
        XCTAssertEqual(
            ImageCropper.cropRect(sourceSize: CGSize(width: 100, height: 100), offset: .zero, scale: 0, cropSide: 300),
            .zero
        )
        XCTAssertEqual(
            ImageCropper.cropRect(sourceSize: CGSize(width: 100, height: 100), offset: .zero, scale: 1, cropSide: 0),
            .zero
        )
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

    func testEmptyDraftIsNotWorthInheriting() {
        XCTAssertFalse(ClothingEditView.Draft().hasInheritableContent)
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
