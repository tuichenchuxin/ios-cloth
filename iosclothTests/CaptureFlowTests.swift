import XCTest
import UIKit
@testable import ioscloth

/// 录入流程里可以纯函数验证的逻辑：草稿继承、温度档位多选、图片方向归一。
///
/// 裁切本身已经交给系统组件（`SystemImagePicker.allowsEditing`），
/// 所以这里不再有裁切坐标换算的测试 —— 那类计算随自研裁切页一起删掉了。
final class CaptureFlowTests: XCTestCase {

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

    /// 最低温高于最高温时，写回对象要自动纠正
    func testApplyNormalizesInvertedTemperatureRange() {
        var draft = ClothingEditView.Draft()
        draft.tempMin = 30
        draft.tempMax = 10

        let item = Clothing()
        draft.apply(to: item)

        XCTAssertEqual(item.tempMin, 10)
        XCTAssertEqual(item.tempMax, 30)
    }

    // MARK: - 温度档位多选

    private func preset(_ name: String) -> (name: String, min: Double, max: Double) {
        guard let found = ClothingEditView.Draft.temperaturePresets.first(where: { $0.name == name }) else {
            fatalError("没有这个档位：\(name)")
        }
        return found
    }

    /// 多选「冷」+「凉」应该拼出 −5~18（取并集）
    func testSelectingTwoPresetsCombinesRange() {
        var draft = ClothingEditView.Draft()
        draft.togglePreset(preset("冷"))
        XCTAssertEqual(draft.tempMin, -5, accuracy: 0.01)
        XCTAssertEqual(draft.tempMax, 10, accuracy: 0.01)

        draft.togglePreset(preset("凉"))
        XCTAssertEqual(draft.tempMin, -5, accuracy: 0.01, "取两档的最小下限")
        XCTAssertEqual(draft.tempMax, 18, accuracy: 0.01, "取两档的最大上限")
    }

    func testSelectionOrderDoesNotMatter() {
        var a = ClothingEditView.Draft()
        a.togglePreset(preset("冷"))
        a.togglePreset(preset("凉"))

        var b = ClothingEditView.Draft()
        b.togglePreset(preset("凉"))
        b.togglePreset(preset("冷"))

        XCTAssertEqual(a.tempMin, b.tempMin, accuracy: 0.01)
        XCTAssertEqual(a.tempMax, b.tempMax, accuracy: 0.01)
    }

    func testDeselectingRecomputesFromRemaining() {
        var draft = ClothingEditView.Draft()
        draft.togglePreset(preset("冷"))
        draft.togglePreset(preset("凉"))
        draft.togglePreset(preset("冷"))

        XCTAssertFalse(draft.isPresetSelected(preset("冷")))
        XCTAssertTrue(draft.isPresetSelected(preset("凉")))
        XCTAssertEqual(draft.tempMin, 5, accuracy: 0.01)
        XCTAssertEqual(draft.tempMax, 18, accuracy: 0.01)
    }

    /// 取消最后一个档位时保留当前区间（用户可能已手动微调过）
    func testDeselectingLastPresetKeepsRange() {
        var draft = ClothingEditView.Draft()
        draft.togglePreset(preset("热"))
        draft.tempMax = 35

        draft.togglePreset(preset("热"))
        XCTAssertTrue(draft.presetNames.isEmpty)
        XCTAssertEqual(draft.tempMin, 22, accuracy: 0.01, "不该被重置")
        XCTAssertEqual(draft.tempMax, 35, accuracy: 0.01, "手动微调的值要保留")
    }

    /// 从已有衣物反推：完全落在区间内的档位显示为已选
    func testDraftFromClothingDerivesSelectedPresets() {
        let item = Clothing(tempMin: -5, tempMax: 18)
        let draft = ClothingEditView.Draft(item)

        XCTAssertTrue(draft.isPresetSelected(preset("冷")))
        XCTAssertTrue(draft.isPresetSelected(preset("凉")))
        XCTAssertFalse(draft.isPresetSelected(preset("热")))
        XCTAssertFalse(draft.isPresetSelected(preset("严寒")))
    }

    /// 批量录入继承：温度档位也要跟着走
    func testInheritedCarriesPresets() {
        var draft = ClothingEditView.Draft()
        draft.togglePreset(preset("冷"))
        draft.togglePreset(preset("凉"))

        let next = draft.inherited()
        XCTAssertEqual(next.presetNames.sorted(), ["凉", "冷"].sorted())
        XCTAssertEqual(next.tempMin, -5, accuracy: 0.01)
        XCTAssertEqual(next.tempMax, 18, accuracy: 0.01)
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
