import Foundation

/// 手动搭配的规则。全部是纯函数，便于单测。
///
/// 和 `OutfitEngine` 的分工：
/// - `OutfitEngine` 负责「推荐」（打分、随机组合）
/// - `OutfitRules` 负责「自己搭」时的校验、命名、区间推导
enum OutfitRules {

    /// 一套搭配要成立，至少满足其中一组：
    /// - 上装 + 下装
    /// - 连衣裙（自带上下身）
    ///
    /// 鞋、外套、包、配饰都不强制 —— 在家的搭配可能没有鞋，
    /// 强制要求只会让人烦。
    static func isComplete(_ selection: [OutfitSlot: Clothing]) -> Bool {
        if selection[.dress] != nil { return true }
        return selection[.top] != nil && selection[.bottom] != nil
    }

    /// 还缺什么。完整时返回 nil。
    static func missingHint(_ selection: [OutfitSlot: Clothing]) -> String? {
        if isComplete(selection) { return nil }
        if selection[.dress] == nil {
            if selection[.top] == nil, selection[.bottom] == nil {
                return "还差：上装 + 下装（或一条连衣裙）"
            }
            if selection[.top] == nil { return "还差：上装" }
            if selection[.bottom] == nil { return "还差：下装" }
        }
        return "还差：上装 + 下装（或一条连衣裙）"
    }

    /// 由成员衣物推导整段的适配温度区间：取各件下限的最小、上限的最大。
    ///
    /// 这个区间代表「这套衣服整体能穿的天气跨度」，用于在列表里按天气筛选和展示。
    static func temperatureRange(of items: [Clothing]) -> (min: Double, max: Double) {
        guard !items.isEmpty else { return (0, 0) }
        let mins = items.map(\.tempMin)
        let maxes = items.map(\.tempMax)
        return (mins.min() ?? 0, maxes.max() ?? 0)
    }

    /// 自动命名：按部位顺序取前 3 件，例如「黑色大衣 + 米色高领毛衣 + 牛仔裤」。
    static func autoName(_ selection: [OutfitSlot: Clothing]) -> String {
        let names = orderedMembers(selection).prefix(3).map { $0.item.displayName }
        guard !names.isEmpty else { return "我的搭配" }
        return names.joined(separator: " + ")
    }

    /// 按展示顺序排好的成员
    static func orderedMembers(_ selection: [OutfitSlot: Clothing]) -> [(slot: OutfitSlot, item: Clothing)] {
        selection
            .map { (slot: $0.key, item: $0.value) }
            .sorted { $0.slot.sortOrder < $1.slot.sortOrder }
    }

    /// 当前这套里哪些部位还有意义。
    ///
    /// 选了连衣裙就不该再让用户填上装/下装（连衣裙自带上下身），
    /// 反过来选了上装/下装也不该再显示连衣裙。
    static func visibleSlots(for selection: [OutfitSlot: Clothing]) -> [OutfitSlot] {
        let bases: [OutfitSlot] = [.outerwear, .top, .bottom, .dress, .shoes, .bag, .accessory]
        if selection[.dress] != nil {
            return bases.filter { $0 != .top && $0 != .bottom }
        }
        if selection[.top] != nil || selection[.bottom] != nil {
            return bases.filter { $0 != .dress }
        }
        return bases
    }

    /// 换一个部位的内容时，需要连带清掉的部位（连衣裙 ↔ 上装/下装 互斥）
    static func slotsToClear(whenPicking slot: OutfitSlot) -> [OutfitSlot] {
        switch slot {
        case .dress: [.top, .bottom]
        case .top, .bottom: [.dress]
        default: []
        }
    }
}
