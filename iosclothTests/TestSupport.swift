import XCTest
@testable import ioscloth

/// 一个不依赖 SwiftData 的测试替身。
/// 引擎是纯函数，所以测试不用起数据库 —— 这也是把它设计成纯函数的主要理由。
struct TestItem: RecommendableClothing {
    let id: UUID
    var name: String
    var seasons: [Season]
    var tempMin: Double
    var tempMax: Double
    var category: ClothingCategory
    var styleTags: [StyleTag]
    var isLayerable: Bool
    var isFavorite: Bool
    var lastWorn: Date?
    var avoidItemIDs: [UUID]

    var attribution: String { name }

    init(
        id: UUID = UUID(),
        name: String,
        seasons: [Season] = [],
        tempMin: Double = 10,
        tempMax: Double = 26,
        category: ClothingCategory = .top,
        styleTags: [StyleTag] = [],
        isLayerable: Bool = false,
        isFavorite: Bool = false,
        lastWorn: Date? = nil,
        avoidItemIDs: [UUID] = []
    ) {
        self.id = id
        self.name = name
        self.seasons = seasons
        self.tempMin = tempMin
        self.tempMax = tempMax
        self.category = category
        self.styleTags = styleTags
        self.isLayerable = isLayerable
        self.isFavorite = isFavorite
        self.lastWorn = lastWorn
        self.avoidItemIDs = avoidItemIDs
    }
}

/// 生成一批「正常衣柜」：各槽位都有几件，覆盖不同温度。
func makeWardrobe() -> [TestItem] {
    [
        TestItem(name: "薄T恤", seasons: [.summer], tempMin: 22, tempMax: 34, category: .top, styleTags: [.casual]),
        TestItem(name: "长袖上衣", seasons: [.spring, .autumn], tempMin: 12, tempMax: 22, category: .top, styleTags: [.commute]),
        TestItem(name: "毛衣", seasons: [.winter], tempMin: -2, tempMax: 12, category: .top, styleTags: [.commute]),
        TestItem(name: "短裤", seasons: [.summer], tempMin: 24, tempMax: 36, category: .bottom, styleTags: [.casual]),
        TestItem(name: "牛仔裤", seasons: [.spring, .autumn, .winter], tempMin: 5, tempMax: 22, category: .bottom, styleTags: [.casual]),
        TestItem(name: "羊毛裤", seasons: [.winter], tempMin: -5, tempMax: 10, category: .bottom, styleTags: [.commute]),
        TestItem(name: "羽绒服", seasons: [.winter], tempMin: -15, tempMax: 5, category: .outerwear, styleTags: [.casual]),
        TestItem(name: "风衣", seasons: [.spring, .autumn], tempMin: 8, tempMax: 20, category: .outerwear, styleTags: [.commute]),
        TestItem(name: "球鞋", seasons: [.spring, .summer, .autumn, .winter], tempMin: -5, tempMax: 35, category: .shoes, styleTags: [.casual]),
        TestItem(name: "短靴", seasons: [.autumn, .winter], tempMin: -5, tempMax: 15, category: .shoes, styleTags: [.commute]),
    ]
}
