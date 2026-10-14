import Foundation
import SwiftData

/// 一次「今天穿了什么」的记录。
///
/// 这是全项目**最有复利价值**的一张表：攒够几十条 `feedback` 之后，
/// 就能自动校准每件衣物标称的温度区间（DESIGN.md §3.4）。
@Model
final class WearRecord {
    var id: UUID = UUID()
    var date: Date = Date()

    var outfit: Outfit?
    /// 单件记录（没成套时也记）—— 存 UUID 字符串，避免多对多关系
    var clothingIDsRaw: [String] = []

    // 当时的天气（用户手填或来自天气 API）
    var weatherTemp: Double?
    var weatherCondition: String = ""

    /// 体感反馈：太冷 = -1 / 刚好 = 0 / 太热 = +1
    var feedbackRaw: Int = WearFeedback.justRight.rawValue

    var note: String = ""

    init(
        id: UUID = UUID(),
        date: Date = .now,
        outfit: Outfit? = nil,
        clothingIDs: [UUID] = [],
        weatherTemp: Double? = nil,
        weatherCondition: String = "",
        feedback: WearFeedback = .justRight,
        note: String = ""
    ) {
        self.id = id
        self.date = date
        self.outfit = outfit
        self.clothingIDsRaw = clothingIDs.map(\.uuidString)
        self.weatherTemp = weatherTemp
        self.weatherCondition = weatherCondition
        self.feedbackRaw = feedback.rawValue
        self.note = note
    }
}

extension WearRecord {
    var feedback: WearFeedback {
        get { WearFeedback(rawValue: feedbackRaw) ?? .justRight }
        set { feedbackRaw = newValue.rawValue }
    }

    var clothingIDs: [UUID] {
        get { clothingIDsRaw.compactMap(UUID.init(uuidString:)) }
        set { clothingIDsRaw = newValue.map(\.uuidString) }
    }
}
