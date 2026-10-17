import Foundation
import SwiftData

/// 一件衣物。整个 App 的核心实体。
///
/// 设计要点见 DESIGN.md §3.2：
/// - 季节/场景用 `[String]`（rawValue）存，而不是枚举数组 —— SwiftData 的 `#Predicate`
///   不支持自定义 Codable 类型数组，用 rawValue 才能写筛选条件。
/// - 图片只在库里存**文件名**，文件本身在沙盒（见 `ImageStore`）。
@Model
final class Clothing {
    // MARK: 身份
    var id: UUID = UUID()
    var name: String = ""

    // MARK: 分类
    var categoryRaw: String = ClothingCategory.top.rawValue
    var subcategory: String = ""

    // MARK: 季节与温度（核心筛选维度）
    var seasonRaws: [String] = []
    /// 适合穿的最低气温（℃）
    var tempMin: Double = 10
    /// 适合穿的最高气温（℃）
    var tempMax: Double = 26
    /// 预留：标记「打底 / 开衫 / 薄外套」这类能和别的衣服一起穿的。
    ///
    /// 目前**不参与任何计算**。一套搭配现在每个部位只能放一件，
    /// 所以这个标记暂时没有意义，界面上也已经去掉了开关。
    /// 等做「打底 + 毛衣 + 外套」的多层搭配时再启用（见 OutfitEngine 的 TODO）。
    var isLayerable: Bool = false

    // MARK: 外观
    var colorName: String = ""
    var colorHex: String = ""
    var pattern: String = ""
    var material: String = ""
    var styleRaws: [String] = []

    // MARK: 图片（相对文件名，不是绝对路径）
    var imageFile: String = ""
    var thumbFile: String = ""
    /// 预留：M3 用 VisionKit 抠白底后写入
    var cutoutFile: String = ""

    // MARK: 购买信息
    var brand: String = ""
    var price: Double?
    var purchaseDate: Date?
    var note: String = ""

    // MARK: 状态与推荐信号
    var statusRaw: String = ClothingStatus.wearing.rawValue
    var isFavorite: Bool = false
    var wearCount: Int = 0
    var lastWorn: Date?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    /// 「这两件别一起穿」—— 搭配冲突
    var avoidItemIDsRaw: [String] = []

    init(
        id: UUID = UUID(),
        name: String = "",
        category: ClothingCategory = .top,
        subcategory: String = "",
        seasons: [Season] = [],
        tempMin: Double = 10,
        tempMax: Double = 26,
        isLayerable: Bool = false,
        colorName: String = "",
        styleTags: [StyleTag] = [],
        imageFile: String = "",
        thumbFile: String = "",
        status: ClothingStatus = .wearing,
        isFavorite: Bool = false,
        createdAt: Date = .now
    ) {
        self.id = id
        self.name = name
        self.categoryRaw = category.rawValue
        self.subcategory = subcategory
        self.seasonRaws = seasons.map(\.rawValue)
        self.tempMin = tempMin
        self.tempMax = tempMax
        self.isLayerable = isLayerable
        self.colorName = colorName
        self.styleRaws = styleTags.map(\.rawValue)
        self.imageFile = imageFile
        self.thumbFile = thumbFile
        self.statusRaw = status.rawValue
        self.isFavorite = isFavorite
        self.createdAt = createdAt
        self.updatedAt = createdAt
    }
}

// MARK: - 类型安全的计算属性
// 计算属性不参与持久化，只负责在 rawValue 与枚举之间来回转换。

extension Clothing {
    var category: ClothingCategory {
        get { ClothingCategory(rawValue: categoryRaw) ?? .top }
        set { categoryRaw = newValue.rawValue }
    }

    var seasons: [Season] {
        get { seasonRaws.compactMap(Season.init(rawValue:)) }
        set { seasonRaws = newValue.map(\.rawValue) }
    }

    var styleTags: [StyleTag] {
        get { styleRaws.compactMap(StyleTag.init(rawValue:)) }
        set { styleRaws = newValue.map(\.rawValue) }
    }

    var status: ClothingStatus {
        get { ClothingStatus(rawValue: statusRaw) ?? .wearing }
        set { statusRaw = newValue.rawValue }
    }

    var avoidItemIDs: [UUID] {
        get { avoidItemIDsRaw.compactMap(UUID.init(uuidString:)) }
        set { avoidItemIDsRaw = newValue.map(\.uuidString) }
    }

    /// 展示名：用户没填就自动生成，避免图墙上一堆空白标签
    var displayName: String {
        if !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        let parts = [colorName, subcategory.isEmpty ? category.displayName : subcategory]
        let joined = parts.filter { !$0.isEmpty }.joined()
        return joined.isEmpty ? category.displayName : joined
    }

    /// 季节标签文案
    var seasonLabel: String {
        seasons.isEmpty ? "未标季节" : seasons.map(\.displayName).joined(separator: "/")
    }

    /// 温度区间文案
    var temperatureLabel: String {
        "\(Int(tempMin.rounded()))–\(Int(tempMax.rounded()))°C"
    }

    func matches(temperature: Double, tolerance: Double = 0) -> Bool {
        temperature >= tempMin - tolerance && temperature <= tempMax + tolerance
    }

    func touch() {
        updatedAt = .now
    }
}
