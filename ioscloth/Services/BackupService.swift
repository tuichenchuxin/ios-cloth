import Foundation
import SwiftData

/// 结构化数据的 JSON 备份。
///
/// **v1 只有这个和 AirDrop，没有云同步** —— 手机丢了不至于把录入的几百件衣服一起丢掉。
/// 图片不打包进去（体积大、且 `Images/` 本来就在 Documents 里随 iTunes/Finder 备份），
/// 这里只保证「数据 + 文件名」不丢。
enum BackupService {

    static let schemaVersion = 1

    // MARK: - DTO

    struct Snapshot: Codable {
        var schemaVersion: Int
        var exportedAt: Date
        var clothing: [ClothingDTO]
        var outfits: [OutfitDTO]
        var wearRecords: [WearRecordDTO]

        var summary: String {
            "衣物 \(clothing.count) 件 · 搭配 \(outfits.count) 套 · 记录 \(wearRecords.count) 条"
        }
    }

    struct ClothingDTO: Codable {
        var id: UUID
        var name: String
        var category: String
        var subcategory: String
        var seasons: [String]
        var tempMin: Double
        var tempMax: Double
        var isLayerable: Bool
        var colorName: String
        var colorHex: String
        var pattern: String
        var material: String
        var styles: [String]
        var imageFile: String
        var thumbFile: String
        var cutoutFile: String
        var brand: String
        var price: Double?
        var purchaseDate: Date?
        var note: String
        var status: String
        var isFavorite: Bool
        var wearCount: Int
        var lastWorn: Date?
        var createdAt: Date
        var avoidItemIDs: [String]
    }

    struct OutfitDTO: Codable {
        var id: UUID
        var name: String
        var styles: [String]
        var seasons: [String]
        var tempMin: Double
        var tempMax: Double
        var isFavorite: Bool
        var rating: Int
        var wearCount: Int
        var lastWorn: Date?
        var imageFile: String
        var note: String
        var createdAt: Date
        var isGenerated: Bool
        var items: [OutfitItemDTO]
    }

    struct OutfitItemDTO: Codable {
        var slot: String
        var clothingID: UUID?
    }

    struct WearRecordDTO: Codable {
        var id: UUID
        var date: Date
        var outfitID: UUID?
        var clothingIDs: [UUID]
        var weatherTemp: Double?
        var weatherCondition: String
        var feedback: Int
        var note: String
    }

    enum ImportError: LocalizedError {
        case unsupportedVersion(Int)

        var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version):
                "备份文件版本 \(version) 高于当前 App 支持的 \(BackupService.schemaVersion)，请先升级 App。"
            }
        }
    }

    // MARK: - 导出

    @MainActor
    static func snapshot(from context: ModelContext) throws -> Snapshot {
        let clothing = try context.fetch(FetchDescriptor<Clothing>())
        let outfits = try context.fetch(FetchDescriptor<Outfit>())
        let records = try context.fetch(FetchDescriptor<WearRecord>())

        return Snapshot(
            schemaVersion: schemaVersion,
            exportedAt: .now,
            clothing: clothing.map { item in
                ClothingDTO(
                    id: item.id,
                    name: item.name,
                    category: item.categoryRaw,
                    subcategory: item.subcategory,
                    seasons: item.seasonRaws,
                    tempMin: item.tempMin,
                    tempMax: item.tempMax,
                    isLayerable: item.isLayerable,
                    colorName: item.colorName,
                    colorHex: item.colorHex,
                    pattern: item.pattern,
                    material: item.material,
                    styles: item.styleRaws,
                    imageFile: item.imageFile,
                    thumbFile: item.thumbFile,
                    cutoutFile: item.cutoutFile,
                    brand: item.brand,
                    price: item.price,
                    purchaseDate: item.purchaseDate,
                    note: item.note,
                    status: item.statusRaw,
                    isFavorite: item.isFavorite,
                    wearCount: item.wearCount,
                    lastWorn: item.lastWorn,
                    createdAt: item.createdAt,
                    avoidItemIDs: item.avoidItemIDsRaw
                )
            },
            outfits: outfits.map { outfit in
                OutfitDTO(
                    id: outfit.id,
                    name: outfit.name,
                    styles: outfit.styleRaws,
                    seasons: outfit.seasonRaws,
                    tempMin: outfit.tempMin,
                    tempMax: outfit.tempMax,
                    isFavorite: outfit.isFavorite,
                    rating: outfit.rating,
                    wearCount: outfit.wearCount,
                    lastWorn: outfit.lastWorn,
                    imageFile: outfit.imageFile,
                    note: outfit.note,
                    createdAt: outfit.createdAt,
                    isGenerated: outfit.isGenerated,
                    items: outfit.orderedItems.map { OutfitItemDTO(slot: $0.slotRaw, clothingID: $0.clothing?.id) }
                )
            },
            wearRecords: records.map { record in
                WearRecordDTO(
                    id: record.id,
                    date: record.date,
                    outfitID: record.outfit?.id,
                    clothingIDs: record.clothingIDs,
                    weatherTemp: record.weatherTemp,
                    weatherCondition: record.weatherCondition,
                    feedback: record.feedbackRaw,
                    note: record.note
                )
            }
        )
    }

    /// 序列化成 JSON 并落盘，返回文件 URL（交给 `ShareLink` 分享出去）
    @MainActor
    static func exportToFile(context: ModelContext, fileName: String? = nil) throws -> URL {
        let snapshot = try snapshot(from: context)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(snapshot)

        let directory = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let name = fileName ?? "wardrobe-\(formatter.string(from: .now)).json"
        let url = directory.appendingPathComponent(name)

        try data.write(to: url, options: .atomic)
        return url
    }

    // MARK: - 导入

    static func decode(from url: URL) throws -> Snapshot {
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(Snapshot.self, from: data)
        guard snapshot.schemaVersion <= schemaVersion else {
            throw ImportError.unsupportedVersion(snapshot.schemaVersion)
        }
        return snapshot
    }

    /// 导入策略：按 id 去重合并（已存在的 id 跳过），**不做覆盖删除**。
    /// 宁可导重也不能误删用户已有的数据。
    @MainActor
    @discardableResult
    static func merge(_ snapshot: Snapshot, into context: ModelContext) throws -> (added: Int, skipped: Int) {
        let existingClothing = try context.fetch(FetchDescriptor<Clothing>())
        let existingOutfits = try context.fetch(FetchDescriptor<Outfit>())
        let existingRecords = try context.fetch(FetchDescriptor<WearRecord>())

        var existingClothingIDs = Set(existingClothing.map(\.id))
        var existingOutfitIDs = Set(existingOutfits.map(\.id))
        var existingRecordIDs = Set(existingRecords.map(\.id))

        // 已有衣物按 id 建索引，方便搭配里引用到「本地已存在」的衣物。
        // 这里刻意用 Swift 过滤而不是 #Predicate —— 衣柜只有几百件，
        // 而在 #Predicate 宏里引用外部局部变量很容易踩到 SwiftData 的崩溃路径。
        var clothingByID: [UUID: Clothing] = Dictionary(
            existingClothing.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )

        var added = 0
        var skipped = 0

        for dto in snapshot.clothing {
            if existingClothingIDs.contains(dto.id) {
                skipped += 1
                continue
            }
            let item = Clothing(
                id: dto.id,
                name: dto.name,
                category: ClothingCategory(rawValue: dto.category) ?? .top,
                subcategory: dto.subcategory,
                seasons: dto.seasons.compactMap(Season.init(rawValue:)),
                tempMin: dto.tempMin,
                tempMax: dto.tempMax,
                isLayerable: dto.isLayerable,
                colorName: dto.colorName,
                styleTags: dto.styles.compactMap(StyleTag.init(rawValue:)),
                imageFile: dto.imageFile,
                thumbFile: dto.thumbFile,
                status: ClothingStatus(rawValue: dto.status) ?? .wearing,
                isFavorite: dto.isFavorite,
                createdAt: dto.createdAt
            )
            item.colorHex = dto.colorHex
            item.pattern = dto.pattern
            item.material = dto.material
            item.cutoutFile = dto.cutoutFile
            item.brand = dto.brand
            item.price = dto.price
            item.purchaseDate = dto.purchaseDate
            item.note = dto.note
            item.wearCount = dto.wearCount
            item.lastWorn = dto.lastWorn
            item.avoidItemIDsRaw = dto.avoidItemIDs

            context.insert(item)
            clothingByID[dto.id] = item
            existingClothingIDs.insert(dto.id)
            added += 1
        }

        var outfitByID: [UUID: Outfit] = [:]
        for dto in snapshot.outfits {
            if existingOutfitIDs.contains(dto.id) {
                skipped += 1
                continue
            }
            let outfit = Outfit(
                id: dto.id,
                name: dto.name,
                styleTags: dto.styles.compactMap(StyleTag.init(rawValue:)),
                seasons: dto.seasons.compactMap(Season.init(rawValue:)),
                isGenerated: dto.isGenerated,
                createdAt: dto.createdAt
            )
            outfit.tempMin = dto.tempMin
            outfit.tempMax = dto.tempMax
            outfit.isFavorite = dto.isFavorite
            outfit.rating = dto.rating
            outfit.wearCount = dto.wearCount
            outfit.lastWorn = dto.lastWorn
            outfit.imageFile = dto.imageFile
            outfit.note = dto.note

            context.insert(outfit)
            outfitByID[dto.id] = outfit

            for itemDTO in dto.items {
                let clothing = itemDTO.clothingID.flatMap { clothingByID[$0] }
                let outfitItem = OutfitItem(
                    slot: OutfitSlot(rawValue: itemDTO.slot) ?? .top,
                    clothing: clothing
                )
                outfitItem.outfit = outfit
                context.insert(outfitItem)
            }

            existingOutfitIDs.insert(dto.id)
            added += 1
        }

        for dto in snapshot.wearRecords {
            if existingRecordIDs.contains(dto.id) {
                skipped += 1
                continue
            }
            let record = WearRecord(
                id: dto.id,
                date: dto.date,
                outfit: dto.outfitID.flatMap { outfitByID[$0] },
                clothingIDs: dto.clothingIDs,
                weatherTemp: dto.weatherTemp,
                weatherCondition: dto.weatherCondition,
                feedback: WearFeedback(rawValue: dto.feedback) ?? .justRight,
                note: dto.note
            )
            context.insert(record)
            existingRecordIDs.insert(dto.id)
            added += 1
        }

        try context.save()
        return (added, skipped)
    }

    // MARK: - 危险操作（仅用于开发/测试）

    /// 清空全部数据。UI 上必须二次确认。
    ///
    /// ⚠️ 刻意**逐条删除**而不是用 `context.delete(model:)` 批量删除：
    /// 批量删除是 SQL 级的，会绕过级联规则，撞上
    /// `Constraint trigger violation: Batch delete failed due to mandatory OTO nullify inverse
    /// on OutfitItem/outfit` 而直接抛错。逐条删走的是完整的对象图逻辑。
    @MainActor
    static func deleteEverything(in context: ModelContext) throws {
        // 先断开「搭配槽位 → 衣物」的引用，避免删除衣物时留下悬空引用
        for outfitItem in try context.fetch(FetchDescriptor<OutfitItem>()) {
            outfitItem.clothing = nil
        }
        // 记录引用了搭配，先删记录
        for record in try context.fetch(FetchDescriptor<WearRecord>()) {
            context.delete(record)
        }
        // 删搭配，级联带走它的槽位
        for outfit in try context.fetch(FetchDescriptor<Outfit>()) {
            context.delete(outfit)
        }
        // 兜底：个别槽位可能没能随级联删掉
        for outfitItem in try context.fetch(FetchDescriptor<OutfitItem>()) {
            context.delete(outfitItem)
        }
        for item in try context.fetch(FetchDescriptor<Clothing>()) {
            context.delete(item)
        }
        try context.save()
    }
}
