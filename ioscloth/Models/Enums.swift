import Foundation

// MARK: - 分类（衣物部位）

enum ClothingCategory: String, Codable, CaseIterable, Identifiable {
    case top, bottom, outerwear, dress, shoes, bag, accessory, underwear, sportswear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: "上衣"
        case .bottom: "下装"
        case .outerwear: "外套"
        case .dress: "连衣裙"
        case .shoes: "鞋子"
        case .bag: "包"
        case .accessory: "配饰"
        case .underwear: "内衣"
        case .sportswear: "运动服"
        }
    }

    /// 该部位在「一套搭配」里占据的槽位；配饰/内衣不参与组装
    var slot: OutfitSlot? {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .outerwear: .outerwear
        case .dress: .dress
        case .shoes: .shoes
        case .bag: .bag
        case .accessory: .accessory
        case .underwear, .sportswear: nil
        }
    }
}

// MARK: - 季节

enum Season: String, Codable, CaseIterable, Identifiable {
    case spring, summer, autumn, winter

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .spring: "春"
        case .summer: "夏"
        case .autumn: "秋"
        case .winter: "冬"
        }
    }

    /// 由月份粗略推断当前季节（后续接天气 API 后改用温度推断）
    static func current(for date: Date = .now, calendar: Calendar = .current) -> Season {
        switch calendar.component(.month, from: date) {
        case 3, 4, 5: .spring
        case 6, 7, 8: .summer
        case 9, 10, 11: .autumn
        default: .winter
        }
    }
}

// MARK: - 场景

enum StyleTag: String, Codable, CaseIterable, Identifiable {
    case commute, casual, sporty, formal, date, home

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .commute: "通勤"
        case .casual: "休闲"
        case .sporty: "运动"
        case .formal: "正式"
        case .date: "约会"
        case .home: "居家"
        }
    }
}

// MARK: - 衣物状态

enum ClothingStatus: String, Codable, CaseIterable, Identifiable {
    /// 在穿 —— 会出现在推荐候选里
    case wearing
    /// 已收纳（换季收起来）—— 不会被推荐
    case stored
    /// 待处理 / 断舍离
    case toDonate
    /// 借出
    case lent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wearing: "在穿"
        case .stored: "已收纳"
        case .toDonate: "待处理"
        case .lent: "借出"
        }
    }

    /// 是否能进入推荐候选池
    var isRecommendable: Bool { self == .wearing }
}

// MARK: - 搭配槽位

enum OutfitSlot: String, Codable, CaseIterable, Identifiable {
    case top, bottom, dress, outerwear, shoes, bag, accessory

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .top: "上衣"
        case .bottom: "下装"
        case .dress: "连衣裙"
        case .outerwear: "外套"
        case .shoes: "鞋"
        case .bag: "包"
        case .accessory: "配饰"
        }
    }

    /// 组装一套搭配时的固定展示顺序
    var sortOrder: Int {
        switch self {
        case .outerwear: 0
        case .top: 1
        case .dress: 2
        case .bottom: 3
        case .shoes: 4
        case .bag: 5
        case .accessory: 6
        }
    }
}

// MARK: - 穿着反馈（用于日后校准温度区间）

enum WearFeedback: Int, Codable, CaseIterable, Identifiable {
    case tooCold = -1
    case justRight = 0
    case tooHot = 1

    var id: Int { rawValue }

    var displayName: String {
        switch self {
        case .tooCold: "太冷"
        case .justRight: "刚好"
        case .tooHot: "太热"
        }
    }
}
