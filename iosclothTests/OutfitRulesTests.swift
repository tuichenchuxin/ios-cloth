import XCTest
import SwiftData
@testable import ioscloth

/// 「自己搭一套」的规则：完整性、缺失提示、区间推导、自动命名、部位互斥。
final class OutfitRulesTests: XCTestCase {

    private func item(_ name: String, _ category: ClothingCategory) -> Clothing {
        Clothing(name: name, category: category)
    }

    // MARK: - 完整性

    func testTopAndBottomIsComplete() {
        let selection: [OutfitSlot: Clothing] = [
            .top: item("衬衫", .top),
            .bottom: item("牛仔裤", .bottom),
        ]
        XCTAssertTrue(OutfitRules.isComplete(selection))
        XCTAssertNil(OutfitRules.missingHint(selection))
    }

    func testDressAloneIsComplete() {
        let selection: [OutfitSlot: Clothing] = [.dress: item("连衣裙", .dress)]
        XCTAssertTrue(OutfitRules.isComplete(selection))
    }

    func testTopAloneIsIncomplete() {
        let selection: [OutfitSlot: Clothing] = [.top: item("衬衫", .top)]
        XCTAssertFalse(OutfitRules.isComplete(selection))
        XCTAssertEqual(OutfitRules.missingHint(selection), "还差：下装")
    }

    func testEmptySaysWhatIsMissing() {
        let hint = OutfitRules.missingHint([:])
        XCTAssertNotNil(hint)
        XCTAssertTrue(hint?.contains("上装") == true)
        XCTAssertTrue(hint?.contains("下装") == true)
    }

    /// 鞋和外套不强制：在家的搭配可能没有鞋
    func testShoesAndOuterwearAreOptional() {
        let selection: [OutfitSlot: Clothing] = [
            .top: item("T恤", .top),
            .bottom: item("短裤", .bottom),
        ]
        XCTAssertTrue(OutfitRules.isComplete(selection))
    }

    // MARK: - 温度区间

    func testTemperatureRangeIsUnionOfMembers() {
        let top = Clothing(name: "毛衣", category: .top, tempMin: -5, tempMax: 12)
        let bottom = Clothing(name: "羊毛裤", category: .bottom, tempMin: -10, tempMax: 8)
        let shoes = Clothing(name: "短靴", category: .shoes, tempMin: 0, tempMax: 15)

        let range = OutfitRules.temperatureRange(of: [top, bottom, shoes])
        XCTAssertEqual(range.min, -10, accuracy: 0.01, "取所有成员里最低的下限")
        XCTAssertEqual(range.max, 15, accuracy: 0.01, "取所有成员里最高的上限")
    }

    func testTemperatureRangeOfEmptyIsZero() {
        let range = OutfitRules.temperatureRange(of: [])
        XCTAssertEqual(range.min, 0)
        XCTAssertEqual(range.max, 0)
    }

    // MARK: - 自动命名

    func testAutoNameFollowsSlotOrder() {
        let selection: [OutfitSlot: Clothing] = [
            .shoes: item("短靴", .shoes),
            .top: item("米色毛衣", .top),
            .outerwear: item("黑色大衣", .outerwear),
        ]
        // 顺序：外套 → 上装 → 鞋
        XCTAssertEqual(OutfitRules.autoName(selection), "黑色大衣 + 米色毛衣 + 短靴")
    }

    func testAutoNameCapsAtThreeItems() {
        let selection: [OutfitSlot: Clothing] = [
            .outerwear: item("大衣", .outerwear),
            .top: item("毛衣", .top),
            .bottom: item("裤子", .bottom),
            .shoes: item("鞋", .shoes),
            .bag: item("包", .bag),
        ]
        let name = OutfitRules.autoName(selection)
        XCTAssertEqual(name.components(separatedBy: " + ").count, 3, "最多取 3 件，太长没法看")
    }

    func testAutoNameOfEmpty() {
        XCTAssertEqual(OutfitRules.autoName([:]), "我的搭配")
    }

    // MARK: - 部位互斥

    func testDressHidesTopAndBottom() {
        let slots = OutfitRules.visibleSlots(for: [.dress: item("连衣裙", .dress)])
        XCTAssertFalse(slots.contains(.top))
        XCTAssertFalse(slots.contains(.bottom))
        XCTAssertTrue(slots.contains(.shoes))
    }

    func testTopHidesDress() {
        let slots = OutfitRules.visibleSlots(for: [.top: item("衬衫", .top)])
        XCTAssertFalse(slots.contains(.dress))
        XCTAssertTrue(slots.contains(.bottom))
    }

    func testSelectingDressClearsTopAndBottom() {
        XCTAssertEqual(Set(OutfitRules.slotsToClear(whenPicking: .dress)), Set([.top, .bottom]))
    }

    func testSelectingTopClearsDress() {
        XCTAssertEqual(OutfitRules.slotsToClear(whenPicking: .top), [.dress])
        XCTAssertEqual(OutfitRules.slotsToClear(whenPicking: .bottom), [.dress])
    }

    func testOtherSlotsClearNothing() {
        XCTAssertTrue(OutfitRules.slotsToClear(whenPicking: .shoes).isEmpty)
        XCTAssertTrue(OutfitRules.slotsToClear(whenPicking: .bag).isEmpty)
        XCTAssertTrue(OutfitRules.slotsToClear(whenPicking: .outerwear).isEmpty)
    }

    func testVisibleSlotsIncludesAllWhenEmpty() {
        let slots = OutfitRules.visibleSlots(for: [:])
        XCTAssertTrue(slots.contains(.top))
        XCTAssertTrue(slots.contains(.bottom))
        XCTAssertTrue(slots.contains(.dress))
        XCTAssertEqual(slots.count, 7)
    }
}
