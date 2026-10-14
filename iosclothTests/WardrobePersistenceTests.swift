import XCTest
import SwiftData
@testable import ioscloth

/// M1 的端到端验收：在**真的 SwiftData 数据库**（内存态）上跑通
/// 「录入衣物 → 按季节/温度筛选 → 生成搭配 → 存搭配 → 导出/导入备份」这条主链路。
@MainActor
final class WardrobePersistenceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let schema = Schema([Clothing.self, Outfit.self, OutfitItem.self, WearRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        container = try ModelContainer(for: schema, configurations: [configuration])
        context = container.mainContext
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    // MARK: - 录入

    func testInsertAndFetchClothing() throws {
        let coat = Clothing(
            name: "黑色羊毛大衣",
            category: .outerwear,
            subcategory: "大衣",
            seasons: [.winter, .autumn],
            tempMin: -5,
            tempMax: 10,
            colorName: "黑色",
            styleTags: [.commute]
        )
        context.insert(coat)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Clothing>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].displayName, "黑色羊毛大衣")
        XCTAssertEqual(fetched[0].category, .outerwear)
        XCTAssertEqual(fetched[0].seasons, [.winter, .autumn])
        XCTAssertEqual(fetched[0].status, .wearing)
        XCTAssertEqual(fetched[0].temperatureLabel, "-5–10°C")
    }

    func testDisplayNameIsGeneratedWhenNameIsBlank() throws {
        let item = Clothing(category: .top, subcategory: "高领毛衣", colorName: "米色")
        context.insert(item)
        try context.save()
        XCTAssertEqual(item.displayName, "米色高领毛衣")
    }

    func testEnumsRoundTripThroughRawValues() throws {
        let item = Clothing(category: .shoes, seasons: [.spring, .summer], styleTags: [.sporty, .casual])
        item.status = .stored
        context.insert(item)
        try context.save()

        // 重新取一次，确认不是靠内存里的对象，而是真的从库里读回来的
        let fetched = try context.fetch(FetchDescriptor<Clothing>()).first
        XCTAssertEqual(fetched?.category, .shoes)
        XCTAssertEqual(Set(fetched?.seasons ?? []), Set([.spring, .summer]))
        XCTAssertEqual(Set(fetched?.styleTags ?? []), Set([.sporty, .casual]))
        XCTAssertEqual(fetched?.status, .stored)
        XCTAssertEqual(fetched?.status.isRecommendable, false)
    }

    func testAvoidRelationshipsRoundTrip() throws {
        let pants = Clothing(name: "条纹裤", category: .bottom)
        let top = Clothing(name: "条纹上衣", category: .top)
        context.insert(pants)
        context.insert(top)
        top.avoidItemIDs = [pants.id]
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Clothing>())
            .first { $0.name == "条纹上衣" }
        XCTAssertEqual(fetched?.avoidItemIDs, [pants.id])
    }

    // MARK: - 筛选（@Query 用的那条 predicate 必须真的能跑）

    func testPredicateFilterOnStatusWorks() throws {
        let wearing = Clothing(name: "在穿的", category: .top, status: .wearing)
        let stored = Clothing(name: "收纳的", category: .top, status: .stored)
        context.insert(wearing)
        context.insert(stored)
        try context.save()

        // 这和 OutfitTabView 里的 @Query 完全一致
        let descriptor = FetchDescriptor<Clothing>(predicate: #Predicate<Clothing> { $0.statusRaw == "wearing" })
        let results = try context.fetch(descriptor)

        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0].name, "在穿的")
    }

    func testSeasonAndTemperatureFilteringViaEngine() throws {
        for item in makeWardrobe() {
            context.insert(
                Clothing(
                    name: item.name,
                    category: item.category,
                    seasons: item.seasons,
                    tempMin: item.tempMin,
                    tempMax: item.tempMax,
                    styleTags: item.styleTags
                )
            )
        }
        try context.save()

        let all = try context.fetch(FetchDescriptor<Clothing>())
        XCTAssertEqual(all.count, makeWardrobe().count)

        let request = OutfitRequest(temperature: 0, season: .winter)
        let candidates = OutfitEngine.candidates(from: all, request: request)
        let names = Set(candidates.map(\.item.name))

        XCTAssertTrue(names.contains("羽绒服"))
        XCTAssertFalse(names.contains("短裤"))
    }

    // MARK: - 搭配的持久化

    func testSavingOutfitPersistsAssignments() throws {
        let top = Clothing(name: "毛衣", category: .top, seasons: [.winter], tempMin: -5, tempMax: 12)
        let bottom = Clothing(name: "羊毛裤", category: .bottom, seasons: [.winter], tempMin: -5, tempMax: 10)
        let shoes = Clothing(name: "短靴", category: .shoes, seasons: [.winter], tempMin: -5, tempMax: 15)
        [top, bottom, shoes].forEach(context.insert)

        let outfit = Outfit(name: "周三通勤", styleTags: [.commute], seasons: [.winter], isGenerated: true)
        context.insert(outfit)
        for (slot, item) in [(OutfitSlot.top, top), (.bottom, bottom), (.shoes, shoes)] {
            let outfitItem = OutfitItem(slot: slot, clothing: item)
            outfitItem.outfit = outfit
            context.insert(outfitItem)
        }
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<Outfit>())
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched[0].items.count, 3)
        XCTAssertEqual(fetched[0].orderedItems.map(\.slot), [.top, .bottom, .shoes])
        XCTAssertEqual(Set(fetched[0].items.compactMap { $0.clothing?.name }), Set(["毛衣", "羊毛裤", "短靴"]))
    }

    func testDeletingOutfitCascadesToItsItems() throws {
        let top = Clothing(name: "毛衣", category: .top)
        context.insert(top)
        let outfit = Outfit(name: "一套")
        context.insert(outfit)
        let outfitItem = OutfitItem(slot: .top, clothing: top)
        outfitItem.outfit = outfit
        context.insert(outfitItem)
        try context.save()

        context.delete(outfit)
        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Outfit>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutfitItem>()).count, 0, "删搭配应级联删掉槽位")
        XCTAssertEqual(try context.fetch(FetchDescriptor<Clothing>()).count, 1, "衣物本身不该被删")
    }

    func testDeletingClothingLeavesOutfitIntactButSlotEmpty() throws {
        // 一件上衣 + 一条裤子组成的搭配，删掉上衣之后：
        //   搭配还在（记录「当时的选择」），上衣那个槽位被置空，裤子那个槽位不动。
        let top = Clothing(name: "毛衣", category: .top)
        let bottom = Clothing(name: "羊毛裤", category: .bottom)
        context.insert(top)
        context.insert(bottom)
        let outfit = Outfit(name: "一套")
        context.insert(outfit)
        let topSlot = OutfitItem(slot: .top, clothing: top)
        topSlot.outfit = outfit
        context.insert(topSlot)
        let bottomSlot = OutfitItem(slot: .bottom, clothing: bottom)
        bottomSlot.outfit = outfit
        context.insert(bottomSlot)
        try context.save()

        try ClothingService.delete(top, in: context)

        let outfits = try context.fetch(FetchDescriptor<Outfit>())
        XCTAssertEqual(outfits.count, 1, "搭配记录的是「当时的决定」，不该因为衣服删了就消失")
        XCTAssertEqual(outfits[0].items.count, 2, "槽位本身要保留，只是里面没衣服了")
        XCTAssertEqual(outfits[0].orderedItems.map(\.slot), [.top, .bottom])

        let slots = try context.fetch(FetchDescriptor<OutfitItem>())
        XCTAssertEqual(slots.count, 2)
        XCTAssertNil(slots.first { $0.slot == .top }?.clothing, "被删衣物的槽位必须置空，不能指向已删除对象")
        XCTAssertEqual(slots.first { $0.slot == .bottom }?.clothing?.name, "羊毛裤", "别的槽位不该受影响")

        XCTAssertEqual(try context.fetch(FetchDescriptor<Clothing>()).count, 1)
    }

    func testDeletingClothingRemovesOutfitThatBecomesEmpty() throws {
        // 只剩一个槽位的搭配，删掉那件衣服后整套变成空壳 → 顺手删掉，
        // 免得「我的搭配」里堆一排点开是空的卡片。
        let top = Clothing(name: "毛衣", category: .top)
        context.insert(top)
        let outfit = Outfit(name: "孤零零一套")
        context.insert(outfit)
        let slot = OutfitItem(slot: .top, clothing: top)
        slot.outfit = outfit
        context.insert(slot)
        try context.save()

        try ClothingService.delete(top, in: context)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Outfit>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutfitItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Clothing>()).count, 0)
    }

    func testDeleteEverythingOnPopulatedWardrobeDoesNotThrow() throws {
        // 这里专门防的一个回归：用 `context.delete(model:)` 批量删除会抛
        // "Constraint trigger violation: Batch delete failed due to mandatory
        //  OTO nullify inverse on OutfitItem/outfit"
        let top = Clothing(name: "毛衣", category: .top)
        context.insert(top)
        let outfit = Outfit(name: "一套")
        context.insert(outfit)
        let slot = OutfitItem(slot: .top, clothing: top)
        slot.outfit = outfit
        context.insert(slot)
        context.insert(WearRecord(outfit: outfit, weatherTemp: 3))
        try context.save()

        XCTAssertNoThrow(try BackupService.deleteEverything(in: context))

        XCTAssertEqual(try context.fetch(FetchDescriptor<Clothing>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Outfit>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<OutfitItem>()).count, 0)
        XCTAssertEqual(try context.fetch(FetchDescriptor<WearRecord>()).count, 0)
    }

    // MARK: - 穿着记录

    func testWearRecordRoundTrip() throws {
        let record = WearRecord(
            weatherTemp: 8,
            weatherCondition: "多云",
            feedback: .tooCold,
            note: "早上出门有点凉"
        )
        context.insert(record)
        try context.save()

        let fetched = try context.fetch(FetchDescriptor<WearRecord>()).first
        XCTAssertEqual(fetched?.weatherTemp, 8)
        XCTAssertEqual(fetched?.weatherCondition, "多云")
        XCTAssertEqual(fetched?.feedback, .tooCold)
        XCTAssertEqual(fetched?.feedback.displayName, "太冷")
    }

    // MARK: - 备份：导出 → 清空 → 导入

    func testExportThenImportRestoresData() throws {
        let coat = Clothing(
            name: "大衣",
            category: .outerwear,
            seasons: [.winter],
            tempMin: -5,
            tempMax: 10,
            status: .wearing
        )
        let top = Clothing(name: "毛衣", category: .top, seasons: [.winter])
        context.insert(coat)
        context.insert(top)

        let outfit = Outfit(name: "冬装", seasons: [.winter])
        context.insert(outfit)
        let outfitItem = OutfitItem(slot: .top, clothing: top)
        outfitItem.outfit = outfit
        context.insert(outfitItem)

        context.insert(WearRecord(weatherTemp: 2, feedback: .justRight))
        try context.save()

        let snapshot = try BackupService.snapshot(from: context)
        XCTAssertEqual(snapshot.clothing.count, 2)
        XCTAssertEqual(snapshot.outfits.count, 1)
        XCTAssertEqual(snapshot.wearRecords.count, 1)

        // 模拟「手机丢了，只有备份文件」
        try BackupService.deleteEverything(in: context)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Clothing>()).count, 0)

        let outcome = try BackupService.merge(snapshot, into: context)
        XCTAssertEqual(outcome.added, 4, "2 件衣物 + 1 套搭配 + 1 条记录")

        let restored = try context.fetch(FetchDescriptor<Clothing>())
        XCTAssertEqual(restored.count, 2)
        XCTAssertEqual(restored.first { $0.name == "大衣" }?.category, .outerwear)
        XCTAssertEqual(restored.first { $0.name == "大衣" }?.temperatureLabel, "-5–10°C")
        XCTAssertEqual(restored.first { $0.name == "大衣" }?.seasons, [.winter])
    }

    func testImportIsIdempotentAndDoesNotDuplicate() throws {
        context.insert(Clothing(name: "毛衣", category: .top, seasons: [.winter]))
        try context.save()

        let snapshot = try BackupService.snapshot(from: context)

        // 连续导入两次：第一次跳过（已存在），第二次也跳过
        let first = try BackupService.merge(snapshot, into: context)
        XCTAssertEqual(first.added, 0)
        XCTAssertEqual(first.skipped, 1)

        let second = try BackupService.merge(snapshot, into: context)
        XCTAssertEqual(second.added, 0)

        XCTAssertEqual(try context.fetch(FetchDescriptor<Clothing>()).count, 1, "重复导入不该产生重复衣物")
    }

    func testBackupJSONRoundTripsThroughEncoder() throws {
        context.insert(Clothing(
            name: "碎花连衣裙",
            category: .dress,
            seasons: [.summer],
            tempMin: 22,
            tempMax: 34,
            styleTags: [.date]
        ))
        try context.save()

        let snapshot = try BackupService.snapshot(from: context)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackupService.Snapshot.self, from: data)

        XCTAssertEqual(decoded.schemaVersion, BackupService.schemaVersion)
        XCTAssertEqual(decoded.clothing.count, 1)
        XCTAssertEqual(decoded.clothing[0].name, "碎花连衣裙")
        XCTAssertEqual(decoded.clothing[0].seasons, ["summer"])
        XCTAssertEqual(decoded.clothing[0].styles, ["date"])
    }

    func testImportRejectsNewerSchemaVersion() throws {
        let snapshot = BackupService.Snapshot(
            schemaVersion: BackupService.schemaVersion + 1,
            exportedAt: .now,
            clothing: [],
            outfits: [],
            wearRecords: []
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("future-backup-\(UUID().uuidString).json")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try BackupService.decode(from: url)) { error in
            guard case BackupService.ImportError.unsupportedVersion = error else {
                return XCTFail("应该报「备份版本过高」，实际是 \(error)")
            }
        }
    }

    // MARK: - 完整主链路

    func testFullHappyPathFromEmptyWardrobeToSavedOutfit() throws {
        // 1. 空衣柜 → 引擎出不了搭配
        var all = try context.fetch(FetchDescriptor<Clothing>())
        XCTAssertTrue(all.isEmpty)

        let request = OutfitRequest(temperature: 0, season: .winter, styles: [.commute], limit: 3, seed: 1234)
        XCTAssertTrue(OutfitEngine.generate(from: OutfitEngine.candidates(from: all, request: request), request: request).isEmpty)

        // 2. 录入一个完整衣柜
        for item in makeWardrobe() {
            context.insert(
                Clothing(
                    name: item.name,
                    category: item.category,
                    seasons: item.seasons,
                    tempMin: item.tempMin,
                    tempMax: item.tempMax,
                    styleTags: item.styleTags
                )
            )
        }
        try context.save()
        all = try context.fetch(FetchDescriptor<Clothing>())

        // 3. 生成搭配
        let candidates = OutfitEngine.candidates(from: all, request: request)
        let drafts = OutfitEngine.generate(from: candidates, request: request)
        XCTAssertFalse(drafts.isEmpty, "有完整衣柜之后应该能搭出衣服")

        // 4. 把第一套存下来（和 OutfitTabView.save 的逻辑一致）
        guard let draft = drafts.first else { return XCTFail("没有生成搭配") }
        let outfit = Outfit(styleTags: request.styles, seasons: [request.season], isGenerated: true)
        context.insert(outfit)
        for (slot, item) in draft.assignments {
            let outfitItem = OutfitItem(slot: slot, clothing: item)
            outfitItem.outfit = outfit
            context.insert(outfitItem)
            item.wearCount += 1
            item.lastWorn = .now
        }
        try context.save()

        // 5. 校验落库结果
        let savedOutfits = try context.fetch(FetchDescriptor<Outfit>())
        XCTAssertEqual(savedOutfits.count, 1)
        XCTAssertEqual(savedOutfits[0].items.count, draft.assignments.count)
        XCTAssertEqual(savedOutfits[0].items.count, Set(savedOutfits[0].items.map(\.id)).count)

        // 6. 穿过的衣服 wearCount 应该被记上
        let worn = try context.fetch(FetchDescriptor<Clothing>()).filter { $0.wearCount > 0 }
        XCTAssertEqual(worn.count, draft.assignments.count)
        XCTAssertTrue(worn.allSatisfy { $0.lastWorn != nil })

        // 7. 再生成一次：刚穿过的应该被扣分（新鲜度惩罚）
        let again = OutfitEngine.candidates(from: try context.fetch(FetchDescriptor<Clothing>()), request: request)
        let penalized = again.filter { $0.breakdown.freshness < 0 }
        XCTAssertFalse(penalized.isEmpty, "刚穿过的衣服应该吃到新鲜度惩罚，避免天天推荐同几件")
    }
}
