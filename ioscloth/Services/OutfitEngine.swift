import Foundation

/// 推荐引擎能「看见」的衣物属性。
///
/// 让 `OutfitEngine` 依赖这个协议而不是 SwiftData 的 `Clothing`，有两个好处：
/// 1. 引擎是**纯函数**，单元测试不用起数据库；
/// 2. 将来想换持久化方案（Core Data / JSON），引擎一行都不用改。
protocol RecommendableClothing {
    var id: UUID { get }
    var seasons: [Season] { get }
    var tempMin: Double { get }
    var tempMax: Double { get }
    var category: ClothingCategory { get }
    var styleTags: [StyleTag] { get }
    var isLayerable: Bool { get }
    var isFavorite: Bool { get }
    var lastWorn: Date? { get }
    var avoidItemIDs: [UUID] { get }
    /// 展示用名称（`Clothing` 返回 `displayName`）
    var attribution: String { get }
}

extension Clothing: RecommendableClothing {
    var attribution: String { displayName }
}

/// 一次推荐请求。
struct OutfitRequest {
    /// 目标温度 ℃
    var temperature: Double
    /// 目标季节
    var season: Season
    /// 目标场景
    var styles: [StyleTag]
    /// 最多生成几套
    var limit: Int = 3
    /// 每个槽位的候选池大小
    var candidatePoolSize: Int = 4
    /// 随机种子：测试里固定，运行时用 nil
    var seed: UInt64?

    init(
        temperature: Double,
        season: Season,
        styles: [StyleTag] = [],
        limit: Int = 3,
        candidatePoolSize: Int = 4,
        seed: UInt64? = nil
    ) {
        self.temperature = temperature
        self.season = season
        self.styles = styles
        self.limit = limit
        self.candidatePoolSize = candidatePoolSize
        self.seed = seed
    }
}

/// 打分明细。拆开是为了**可解释 + 可单测**：出问题时能一眼看出是哪一项在作怪。
struct ScoreBreakdown {
    var season: Double = 0
    var temperature: Double = 0
    var style: Double = 0
    var freshness: Double = 0
    var preference: Double = 0
    /// ±3 的随机抖动，让「换一套」真的有变化
    var jitter: Double = 0

    var total: Double { season + temperature + style + freshness + preference + jitter }
}

struct ScoredClothing<Item: RecommendableClothing> {
    let item: Item
    let breakdown: ScoreBreakdown
    let reason: String

    var score: Double { breakdown.total }
}

/// 生成的一套搭配。槽位 → 衣物。
struct OutfitDraft<Item: RecommendableClothing> {
    let assignments: [OutfitSlot: Item]
    let explanation: String
    let season: Season
    let temperature: Double

    func item(for slot: OutfitSlot) -> Item? { assignments[slot] }

    /// 按展示顺序排好的成员
    var orderedAssignments: [(slot: OutfitSlot, item: Item)] {
        assignments
            .map { (slot: $0.key, item: $0.value) }
            .sorted { $0.slot.sortOrder < $1.slot.sortOrder }
    }

    /// 这套搭配能覆盖的成员 id（写测试、查冲突用）
    var itemIDs: Set<UUID> { Set(assignments.values.map(\.id)) }
}

/// 规则 + 打分的搭配引擎。v1 的原则：**可解释、可信、可干预**（DESIGN.md §4）。
///
/// 刻意不引入任何 AI 生成 —— 推荐一件她根本没有的衣服会瞬间摧毁信任。
enum OutfitEngine {

    // MARK: - 打分

    /// 给单件衣物打分。`now` 可注入，保证测试可复现。
    static func score<Item: RecommendableClothing>(
        _ item: Item,
        request: OutfitRequest,
        now: Date = .now,
        jitter: Double? = nil
    ) -> ScoredClothing<Item> {
        var breakdown = ScoreBreakdown()

        // 1) 季节：命中 35 分；没标季节但温度区间覆盖目标温度，给 12 分（过渡季的衣服）
        if item.seasons.contains(request.season) {
            breakdown.season = 35
        } else if item.tempMin <= request.temperature + 3 && item.tempMax >= request.temperature - 3 {
            breakdown.season = 12
        }

        // 2) 温度：落在区间内 45 分；超出后每 1℃ 扣 6 分
        let gap = temperatureGap(item, temperature: request.temperature)
        breakdown.temperature = max(0, 45 - gap * 6)

        // 3) 场景：每命中一个标签 10 分，最多 20 分
        let hits = Set(item.styleTags).intersection(request.styles).count
        breakdown.style = min(20, Double(hits) * 10)

        // 4) 新鲜度：近 3 天穿过的重罚，避免天天推荐同几件
        breakdown.freshness = freshnessScore(lastWorn: item.lastWorn, now: now)

        // 5) 偏好与抖动
        breakdown.preference = item.isFavorite ? 5 : 0
        breakdown.jitter = jitter ?? Double.random(in: -3...3)

        let reason = buildReason(item: item, request: request, now: now)
        return ScoredClothing(item: item, breakdown: breakdown, reason: reason)
    }

    /// 温度超出适配区间的度数（落在区间内为 0）
    static func temperatureGap<Item: RecommendableClothing>(_ item: Item, temperature: Double) -> Double {
        if temperature < item.tempMin { return item.tempMin - temperature }
        if temperature > item.tempMax { return temperature - item.tempMax }
        return 0
    }

    static func freshnessScore(lastWorn: Date?, now: Date = .now) -> Double {
        guard let lastWorn else { return 0 }
        let days = Calendar.current.dateComponents([.day], from: lastWorn, to: now).day ?? 999
        if days < 3 { return -20 }
        if days < 7 { return -10 }
        if days > 30 { return 8 }
        return 0
    }

    // MARK: - 候选池

    /// 筛选能进入推荐的衣物：在穿 + （季节命中 或 温度区间覆盖 `temperature ± 3`）
    static func candidates<Item: RecommendableClothing>(
        from all: [Item],
        request: OutfitRequest,
        statusFilter: (Item) -> Bool = { _ in true }
    ) -> [ScoredClothing<Item>] {
        all
            .filter(statusFilter)
            .filter { item in
                let seasonHit = item.seasons.contains(request.season)
                let tempHit = item.tempMin <= request.temperature + 3
                    && item.tempMax >= request.temperature - 3
                return seasonHit || tempHit
            }
            .map { score($0, request: request) }
            .sorted { $0.score > $1.score }
    }

    // MARK: - 组装一套搭配

    /// 按温度决定一套搭配的「主结构」（DESIGN.md §4.3）
    static func requiredSlots(forTemperature temperature: Double) -> [OutfitSlot] {
        // 24°C 以上理论上可以只要连衣裙；这里给出的基础结构，
        // 是否真的用连衣裙由 `assemble` 随机决定。
        [.top, .bottom, .shoes]
    }

    /// 低于这个温度就必须有外套
    static let outerwearRequiredBelow: Double = 12

    /// 生成至多 `request.limit` 套搭配。生成不出来就返回更少（可能为空）。
    static func generate<Item: RecommendableClothing>(
        from candidates: [ScoredClothing<Item>],
        request: OutfitRequest,
        now: Date = .now
    ) -> [OutfitDraft<Item>] {
        guard !candidates.isEmpty, request.limit > 0 else { return [] }

        var generator = SeededGenerator(seed: request.seed ?? UInt64.random(in: .min ... .max))
        var drafts: [OutfitDraft<Item>] = []
        var usedCombinations: Set<Set<UUID>> = []
        var attempts = 0
        let maxAttempts = request.limit * 6

        while drafts.count < request.limit && attempts < maxAttempts {
            attempts += 1

            // 从打分靠前的池子里随机抽样，保证「换一套」有变化但不会推出奇葩组合
            let pool = Array(candidates.prefix(max(request.candidatePoolSize, 3) * 3)).shuffled(using: &generator)

            guard let draft = assemble(pool: pool, request: request, generator: &generator) else { continue }
            guard !usedCombinations.contains(draft.itemIDs) else { continue }

            usedCombinations.insert(draft.itemIDs)
            drafts.append(draft)
        }

        return drafts
    }

    // MARK: - 内部

    private static func assemble<Item: RecommendableClothing>(
        pool: [ScoredClothing<Item>],
        request: OutfitRequest,
        generator: inout SeededGenerator
    ) -> OutfitDraft<Item>? {
        var assignments: [OutfitSlot: Item] = [:]
        let needOuterwear = request.temperature < outerwearRequiredBelow
        let required = requiredSlots(forTemperature: request.temperature)

        // 高温天偶尔只用一条连衣裙代替「上衣 + 下装」
        let hasDress = !candidatesFor(.dress, in: pool, request: request).isEmpty
        let useDress = request.temperature >= 20
            && hasDress
            && Double.random(in: 0...1, using: &generator) < 0.3

        if useDress {
            guard let dress = pick(.dress, from: pool, request: request, generator: &generator) else { return nil }
            assignments[.dress] = dress
        } else {
            guard let top = pick(.top, from: pool, request: request, generator: &generator) else { return nil }
            guard let bottom = pick(.bottom, from: pool, request: request, generator: &generator) else { return nil }
            assignments[.top] = top
            assignments[.bottom] = bottom
        }

        // 外套：冷天必须有；温度的中间地带可有可无
        if needOuterwear {
            guard let outer = pick(.outerwear, from: pool, request: request, generator: &generator) else {
                return nil
            }
            assignments[.outerwear] = outer
        } else if Double.random(in: 0...1, using: &generator) < 0.4 {
            if let outer = pick(.outerwear, from: pool, request: request, generator: &generator) {
                assignments[.outerwear] = outer
            }
        }

        // 鞋子：优先，但选不到也不该让整套失败
        if required.contains(.shoes), let shoes = pick(.shoes, from: pool, request: request, generator: &generator) {
            assignments[.shoes] = shoes
        }

        // 冲突过滤：「这两件别一起穿」
        guard !hasConflict(assignments.values.map(\.id), items: assignments.values.map { $0 }) else { return nil }

        let explanation = explain(draftItems: assignments, request: request)
        return OutfitDraft(
            assignments: assignments,
            explanation: explanation,
            season: request.season,
            temperature: request.temperature
        )
    }

    /// 从池子里选出该槽位的候选，按分数排序
    private static func candidatesFor<Item: RecommendableClothing>(
        _ slot: OutfitSlot,
        in pool: [ScoredClothing<Item>],
        request: OutfitRequest
    ) -> [ScoredClothing<Item>] {
        pool.filter { $0.item.category.slot == slot }
    }

    /// 按分数加权随机挑一件（分数高不代表必然被选中，否则搭配永远一样）
    private static func pick<Item: RecommendableClothing>(
        _ slot: OutfitSlot,
        from pool: [ScoredClothing<Item>],
        request: OutfitRequest,
        generator: inout SeededGenerator
    ) -> Item? {
        let candidates = Array(candidatesFor(slot, in: pool, request: request).prefix(request.candidatePoolSize))
        guard !candidates.isEmpty else { return nil }
        return weightedPick(candidates, using: &generator)?.item
    }

    // TODO(M3): 支撑「打底 + 毛衣 + 外套」的多层搭配。
    // 现在一套里每个槽位只能放一件，`isLayerable` 因此只用于展示标注、不参与组装。
    // 要让中层真正生效，需要把 `OutfitDraft.assignments` 从 `[槽位: 衣物]`
    // 改成 `[槽位: [衣物]]`（有序层），届时要一并迁移 `OutfitItem`。

    /// 加权随机：权重 = 分数归一化后的平方，分数高的更容易被抽到但不是必然
    private static func weightedPick<Item: RecommendableClothing>(
        _ candidates: [ScoredClothing<Item>],
        using generator: inout SeededGenerator
    ) -> ScoredClothing<Item>? {
        guard let best = candidates.map(\.score).max(), best > 0 else { return candidates.first }

        let weights = candidates.map { max(pow(max($0.score, 0) / best, 3), 0.02) }
        let total = weights.reduce(0, +)
        guard total > 0 else { return candidates.first }

        var threshold = Double.random(in: 0...total, using: &generator)
        for (candidate, weight) in zip(candidates, weights) {
            threshold -= weight
            if threshold <= 0 { return candidate }
        }
        return candidates.last
    }

    private static func hasConflict<Item: RecommendableClothing>(_ ids: [UUID], items: [Item]) -> Bool {
        let idSet = Set(ids)
        for item in items {
            if !Set(item.avoidItemIDs).isDisjoint(with: idSet.subtracting([item.id])) {
                return true
            }
        }
        return false
    }

    // MARK: - 文案

    static func buildReason<Item: RecommendableClothing>(
        item: Item,
        request: OutfitRequest,
        now: Date = .now
    ) -> String {
        var parts: [String] = []
        if item.seasons.contains(request.season) {
            parts.append("匹配\(request.season.displayName)季")
        }
        parts.append("适配 \(Int(item.tempMin.rounded()))–\(Int(item.tempMax.rounded()))°C")

        if let lastWorn = item.lastWorn {
            let days = Calendar.current.dateComponents([.day], from: lastWorn, to: now).day ?? 0
            parts.append(days <= 0 ? "今天穿过" : "近 \(days) 天未穿")
        }
        return parts.joined(separator: " · ")
    }

    static func explain<Item: RecommendableClothing>(
        draftItems: [OutfitSlot: Item],
        request: OutfitRequest
    ) -> String {
        let lines = draftItems
            .map { (slot: $0.key, item: $0.value) }
            .sorted { $0.slot.sortOrder < $1.slot.sortOrder }
            .map { "· \($0.item.attribution)　\($0.slot.displayName)" }

        let header = "今天 \(Int(request.temperature.rounded()))°C · \(request.season.displayName)季，为你选了这套："
        return ([header] + lines).joined(separator: "\n")
    }
}

// MARK: - 可复现的随机数发生器

/// `SystemRandomNumberGenerator` 无法固定种子，测试里需要确定性。
/// 这是个 SplitMix64 实现，只用于打乱顺序和加权抽样，不涉及安全用途。
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
