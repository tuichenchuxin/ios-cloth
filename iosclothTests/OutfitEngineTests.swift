import XCTest
@testable import ioscloth

final class OutfitEngineTests: XCTestCase {

    // MARK: - 固定种子必须可复现

    func testSameSeedProducesIdenticalOutfits() {
        let wardrobe = makeWardrobe()
        let request = OutfitRequest(temperature: 5, season: .winter, styles: [.commute], seed: 42)
        let candidates = OutfitEngine.candidates(from: wardrobe, request: request)

        let first = OutfitEngine.generate(from: candidates, request: request)
        let second = OutfitEngine.generate(from: candidates, request: request)

        XCTAssertEqual(first.count, second.count)
        for (a, b) in zip(first, second) {
            XCTAssertEqual(a.itemIDs, b.itemIDs, "固定种子下两次生成必须完全一样，否则测试没法信")
        }
    }

    // MARK: - 低温必须有外套

    func testColdWeatherAlwaysIncludesOuterwear() {
        let wardrobe = makeWardrobe()
        let request = OutfitRequest(temperature: -5, season: .winter, styles: [.casual], limit: 5, seed: 7)
        let candidates = OutfitEngine.candidates(from: wardrobe, request: request)
        let drafts = OutfitEngine.generate(from: candidates, request: request)

        XCTAssertFalse(drafts.isEmpty, "0°C 以下应该能搭出至少一套")
        for draft in drafts {
            XCTAssertNotNil(draft.item(for: .outerwear), "低于 \(OutfitEngine.outerwearRequiredBelow)°C 必须有外套")
            XCTAssertNotNil(draft.item(for: .top))
            XCTAssertNotNil(draft.item(for: .bottom))
            XCTAssertNotNil(draft.item(for: .shoes))
        }
    }

    func testHotWeatherDoesNotRequireOuterwear() {
        let wardrobe = makeWardrobe()
        let request = OutfitRequest(temperature: 30, season: .summer, styles: [.casual], limit: 3, seed: 3)
        let candidates = OutfitEngine.candidates(from: wardrobe, request: request)
        let drafts = OutfitEngine.generate(from: candidates, request: request)

        for draft in drafts {
            let hasTopAndBottom = draft.item(for: .top) != nil && draft.item(for: .bottom) != nil
            let hasDress = draft.item(for: .dress) != nil
            XCTAssertTrue(hasTopAndBottom || hasDress, "上衣+下装 或 连衣裙，二者必居其一")
        }
    }

    // MARK: - 数量与去重

    func testGeneratesNoMoreThanRequestedLimit() {
        let request = OutfitRequest(temperature: 5, season: .winter, limit: 2, seed: 11)
        let candidates = OutfitEngine.candidates(from: makeWardrobe(), request: request)
        let drafts = OutfitEngine.generate(from: candidates, request: request)
        XCTAssertLessThanOrEqual(drafts.count, 2)
    }

    func testGeneratedOutfitsAreDistinct() {
        let request = OutfitRequest(temperature: 5, season: .winter, limit: 3, seed: 99)
        let candidates = OutfitEngine.candidates(from: makeWardrobe(), request: request)
        let drafts = OutfitEngine.generate(from: candidates, request: request)

        let signatures = drafts.map { $0.itemIDs }
        XCTAssertEqual(signatures.count, Set(signatures).count, "同一批里不该出现两套完全相同的搭配")
    }

    func testEmptyCandidatePoolReturnsNoOutfitsInsteadOfCrashing() {
        let request = OutfitRequest(temperature: 5, season: .winter, seed: 1)
        let drafts = OutfitEngine.generate(from: [ScoredClothing<TestItem>](), request: request)
        XCTAssertTrue(drafts.isEmpty)
    }

    func testIncompleteWardrobeReturnsNoOutfitsInsteadOfCrashing() {
        // 只有上衣，没有下装和鞋 → 搭不出来，但不该崩
        let onlyTops = [TestItem(name: "唯一上衣", seasons: [.winter], category: .top)]
        let request = OutfitRequest(temperature: 0, season: .winter, seed: 5)
        let candidates = OutfitEngine.candidates(from: onlyTops, request: request)
        XCTAssertTrue(OutfitEngine.generate(from: candidates, request: request).isEmpty)
    }

    // MARK: - 冲突规则

    func testAvoidRulesAreRespected() {
        let pants = TestItem(name: "条纹裤", seasons: [.winter], tempMin: -10, tempMax: 15, category: .bottom)
        let top = TestItem(
            name: "条纹上衣",
            seasons: [.winter],
            tempMin: -10,
            tempMax: 15,
            category: .top,
            avoidItemIDs: [pants.id]
        )
        let shoes = TestItem(name: "鞋", seasons: [.winter], tempMin: -20, tempMax: 20, category: .shoes)
        let outer = TestItem(name: "外套", seasons: [.winter], tempMin: -20, tempMax: 5, category: .outerwear)

        let wardrobe = [top, pants, shoes, outer]
        let request = OutfitRequest(temperature: 0, season: .winter, limit: 3, seed: 21)
        let candidates = OutfitEngine.candidates(from: wardrobe, request: request)
        let drafts = OutfitEngine.generate(from: candidates, request: request)

        for draft in drafts {
            let ids = draft.itemIDs
            XCTAssertFalse(
                ids.contains(top.id) && ids.contains(pants.id),
                "标了「别一起穿」的两件不该出现在同一套里"
            )
        }
    }

    // MARK: - 结构

    func testRequiredSlotsAlwaysIncludeTopBottomShoes() {
        let slots = OutfitEngine.requiredSlots(forTemperature: 20)
        XCTAssertEqual(Set(slots), Set([.top, .bottom, .shoes]))
    }

    func testOuterwearRequiredBelowThreshold() {
        XCTAssertLessThan(OutfitEngine.outerwearRequiredBelow, 12.1)
        XCTAssertGreaterThan(OutfitEngine.outerwearRequiredBelow, 11.9)
    }

    func testOrderedAssignmentsFollowDisplayOrder() {
        let request = OutfitRequest(temperature: -5, season: .winter, styles: [.casual], limit: 1, seed: 8)
        let candidates = OutfitEngine.candidates(from: makeWardrobe(), request: request)
        guard let draft = OutfitEngine.generate(from: candidates, request: request).first else {
            return XCTFail("低温下应该能搭出一套")
        }
        let orders = draft.orderedAssignments.map(\.slot.sortOrder)
        XCTAssertEqual(orders, orders.sorted(), "展示顺序必须是外套 → 上衣 → 下装 → 鞋")
    }
}
