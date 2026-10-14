import XCTest
@testable import ioscloth

/// 打分的每条规则都要有测试 —— 引擎一旦悄悄改坏，早上的推荐就会开始胡说。
final class ScoringTests: XCTestCase {

    private let winter = OutfitRequest(temperature: 0, season: .winter, styles: [.commute])
    private let now = Date()

    // MARK: - 温度

    func testTemperatureInsideRangeGetsFullMarks() {
        let item = TestItem(name: "毛衣", seasons: [.winter], tempMin: -5, tempMax: 10)
        let scored = OutfitEngine.score(item, request: winter, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.temperature, 45, accuracy: 0.001)
    }

    func testTemperatureBelowRangeIsPenalized() {
        // 目标 0°C，衣服适合 20–30°C → 差 20°C → 45 − 20×6 = 0（不会变成负数）
        let item = TestItem(name: "薄T恤", seasons: [.summer], tempMin: 20, tempMax: 30)
        let scored = OutfitEngine.score(item, request: winter, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.temperature, 0, accuracy: 0.001)
    }

    func testTemperatureSlightlyAboveRangeIsSoftlyPenalized() {
        // 目标 0°C，衣服适合 2–10°C → 差 2°C → 45 − 2×6 = 33（衰减是软的，不是一刀切为 0）
        let item = TestItem(name: "薄外套", seasons: [.winter], tempMin: 2, tempMax: 10)
        let scored = OutfitEngine.score(item, request: winter, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.temperature, 33, accuracy: 0.001)
    }

    func testTemperatureGapIsZeroInsideRange() {
        let item = TestItem(name: "毛衣", tempMin: -5, tempMax: 10)
        XCTAssertEqual(OutfitEngine.temperatureGap(item, temperature: 3), 0, accuracy: 0.001)
        XCTAssertEqual(OutfitEngine.temperatureGap(item, temperature: -9), 4, accuracy: 0.001)
        XCTAssertEqual(OutfitEngine.temperatureGap(item, temperature: 12), 2, accuracy: 0.001)
    }

    // MARK: - 季节

    func testSeasonMatchGetsBonus() {
        let item = TestItem(name: "毛衣", seasons: [.winter], tempMin: -5, tempMax: 10)
        let scored = OutfitEngine.score(item, request: winter, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.season, 35, accuracy: 0.001)
    }

    func testSeasonMissButTemperatureOverlapGetsPartialCredit() {
        // 没标冬季，但温度覆盖目标温度附近 → 12 分而不是 0
        let item = TestItem(name: "过渡款", seasons: [.autumn], tempMin: -3, tempMax: 8)
        let scored = OutfitEngine.score(item, request: winter, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.season, 12, accuracy: 0.001)
    }

    func testCompletelyUnrelatedItemGetsNoSeasonScore() {
        let item = TestItem(name: "沙滩裤", seasons: [.summer], tempMin: 28, tempMax: 38)
        let scored = OutfitEngine.score(item, request: winter, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.season, 0, accuracy: 0.001)
    }

    // MARK: - 场景

    func testStyleOverlapIsCappedAtTwenty() {
        let item = TestItem(name: "通勤休闲两用", seasons: [.winter], styleTags: [.commute, .casual])
        let request = OutfitRequest(temperature: 0, season: .winter, styles: [.commute, .casual, .home])
        let scored = OutfitEngine.score(item, request: request, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.style, 20, accuracy: 0.001)
    }

    func testStyleSingleHitGetsTen() {
        let item = TestItem(name: "通勤款", seasons: [.winter], styleTags: [.commute])
        let scored = OutfitEngine.score(item, request: winter, now: now, jitter: 0)
        XCTAssertEqual(scored.breakdown.style, 10, accuracy: 0.001)
    }

    // MARK: - 新鲜度

    func testFreshnessPenalizesRecentlyWorn() {
        let justNow = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        XCTAssertEqual(OutfitEngine.freshnessScore(lastWorn: justNow, now: now), -20)
    }

    func testFreshnessSmallPenaltyWithinAWeek() {
        let fourDaysAgo = Calendar.current.date(byAdding: .day, value: -4, to: now)!
        XCTAssertEqual(OutfitEngine.freshnessScore(lastWorn: fourDaysAgo, now: now), -10)
    }

    func testFreshnessBonusForLongUnworn() {
        let longAgo = Calendar.current.date(byAdding: .day, value: -45, to: now)!
        XCTAssertEqual(OutfitEngine.freshnessScore(lastWorn: longAgo, now: now), 8)
    }

    func testFreshnessNeutralWhenNeverWorn() {
        XCTAssertEqual(OutfitEngine.freshnessScore(lastWorn: nil, now: now), 0)
    }

    // MARK: - 偏好

    func testFavoriteGetsSmallBonus() {
        let normal = TestItem(name: "普通", seasons: [.winter])
        let favorite = TestItem(name: "常用", seasons: [.winter], isFavorite: true)
        let a = OutfitEngine.score(normal, request: winter, now: now, jitter: 0)
        let b = OutfitEngine.score(favorite, request: winter, now: now, jitter: 0)
        XCTAssertEqual(b.breakdown.preference - a.breakdown.preference, 5, accuracy: 0.001)
    }

    func testJitterStaysWithinThreePoints() {
        let item = TestItem(name: "普通", seasons: [.winter])
        for _ in 0..<50 {
            let scored = OutfitEngine.score(item, request: winter, now: now)
            XCTAssertLessThanOrEqual(abs(scored.breakdown.jitter), 3.0001)
        }
    }

    // MARK: - 候选池

    func testCandidatesExcludeUnrelatedSeasonsAndTemperatures() {
        let candidates = OutfitEngine.candidates(from: makeWardrobe(), request: winter)
        let names = Set(candidates.map(\.item.name))
        XCTAssertTrue(names.contains("羽绒服"))
        XCTAssertTrue(names.contains("羊毛裤"))
        XCTAssertFalse(names.contains("短裤"), "夏季短裤不该出现在 0°C 的候选里")
        XCTAssertFalse(names.contains("薄T恤"), "夏季 T 恤不该出现在 0°C 的候选里")
    }

    func testCandidatesAreSortedByScoreDescending() {
        let candidates = OutfitEngine.candidates(from: makeWardrobe(), request: winter)
        let scores = candidates.map(\.score)
        XCTAssertEqual(scores, scores.sorted(by: >))
    }

    func testStatusFilterExcludesStoredItems() {
        let wardrobe = makeWardrobe()
        let candidates = OutfitEngine.candidates(from: wardrobe, request: winter) { item in
            item.name != "羽绒服"
        }
        XCTAssertFalse(candidates.map(\.item.name).contains("羽绒服"))
    }
}
