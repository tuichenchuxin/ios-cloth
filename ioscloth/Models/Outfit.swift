import Foundation
import SwiftData

/// 一套搭配。可以是手动搭的，也可以来自推荐引擎。
@Model
final class Outfit {
    var id: UUID = UUID()
    var name: String = ""
    var styleRaws: [String] = []
    var seasonRaws: [String] = []

    /// 温度适配区间。手动创建后由 `OutfitService.refreshTemperatureRange` 从成员衣物推导。
    var tempMin: Double = 5
    var tempMax: Double = 28

    var isFavorite: Bool = false
    /// 0–5 分，0 表示未评分
    var rating: Int = 0
    var wearCount: Int = 0
    var lastWorn: Date?
    /// 可选：整套合影（用户自拍/对镜拍）
    var imageFile: String = ""
    var note: String = ""
    var createdAt: Date = Date()
    /// true = 由推荐引擎生成，false = 手动搭的
    var isGenerated: Bool = false

    @Relationship(deleteRule: .cascade, inverse: \OutfitItem.outfit)
    var items: [OutfitItem] = []

    init(
        id: UUID = UUID(),
        name: String = "",
        styleTags: [StyleTag] = [],
        seasons: [Season] = [],
        isGenerated: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.styleRaws = styleTags.map(\.rawValue)
        self.seasonRaws = seasons.map(\.rawValue)
        self.isGenerated = isGenerated
        self.createdAt = createdAt
    }
}

extension Outfit {
    var styleTags: [StyleTag] {
        get { styleRaws.compactMap(StyleTag.init(rawValue:)) }
        set { styleRaws = newValue.map(\.rawValue) }
    }

    var seasons: [Season] {
        get { seasonRaws.compactMap(Season.init(rawValue:)) }
        set { seasonRaws = newValue.map(\.rawValue) }
    }

    /// 按槽位顺序排好的成员，用于展示
    var orderedItems: [OutfitItem] {
        items.sorted { $0.slot.sortOrder < $1.slot.sortOrder }
    }

    var temperatureLabel: String {
        "\(Int(tempMin.rounded()))–\(Int(tempMax.rounded()))°C"
    }

    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let parts = orderedItems.prefix(3).map { $0.clothing?.displayName ?? $0.slot.displayName }
        return parts.isEmpty ? "未命名搭配" : parts.joined(separator: " + ")
    }
}

/// 搭配里的一个槽位 → 指向具体衣物。
@Model
final class OutfitItem {
    var id: UUID = UUID()
    var slotRaw: String = OutfitSlot.top.rawValue

    /// 衣物删除时置空（不连带删掉搭配）—— 搭配记录的是「当时的选择」，值得保留。
    /// 注意：光靠这个 deleteRule **不够**，删衣物时必须显式置空，
    /// 见 `ClothingService.delete`。
    @Relationship(deleteRule: .nullify)
    var clothing: Clothing?
    var outfit: Outfit?

    init(id: UUID = UUID(), slot: OutfitSlot, clothing: Clothing?) {
        self.id = id
        self.slotRaw = slot.rawValue
        self.clothing = clothing
    }
}

extension OutfitItem {
    var slot: OutfitSlot {
        get { OutfitSlot(rawValue: slotRaw) ?? .top }
        set { slotRaw = newValue.rawValue }
    }
}
