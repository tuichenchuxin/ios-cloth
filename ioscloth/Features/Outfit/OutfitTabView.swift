import SwiftUI
import SwiftData

/// 「今天穿什么」—— 默认 Tab，最高频的场景（DESIGN.md §6）。
struct OutfitTabView: View {
    @Environment(\.modelContext) private var context

    @Query(filter: #Predicate<Clothing> { $0.statusRaw == "wearing" })
    private var wearingItems: [Clothing]

    @State private var temperature: Double = 18
    @State private var season: Season = .current()
    @State private var styles: [StyleTag] = [.commute, .casual]
    @State private var drafts: [OutfitDraft<Clothing>] = []
    @State private var savedMessage: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    weatherBar
                    if wearingItems.isEmpty {
                        emptyState
                    } else {
                        results
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
            .navigationTitle("今天穿什么")
            .safeAreaInset(edge: .bottom) { bottomActionBar }
            .overlay(alignment: .top) {
                if let savedMessage {
                    Text(savedMessage)
                        .font(.footnote.weight(.medium))
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .onChange(of: temperature) { _, _ in generate() }
            .onChange(of: season) { _, _ in generate() }
            .onAppear { if drafts.isEmpty { generate() } }
        }
    }

    // MARK: - 天气条
    //
    // v1 手动输入温度。接天气 API 需要付费开发者账号，等确认后再说（DESIGN.md D5）。

    private var weatherBar: some View {
        VStack(spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("今天")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("\(Int(temperature.rounded()))°C")
                        .font(.system(size: 34, weight: .semibold, design: .rounded))
                }
                Spacer()
                Image(systemName: "thermometer.medium")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
            }

            Slider(value: $temperature, in: -15...38, step: 1) {
                Text("温度")
            } minimumValueLabel: {
                Text("-15°").font(.caption2).foregroundStyle(.secondary)
            } maximumValueLabel: {
                Text("38°").font(.caption2).foregroundStyle(.secondary)
            }

            Picker("季节", selection: $season) {
                ForEach(Season.allCases) { item in
                    Text(item.displayName).tag(item)
                }
            }
            .pickerStyle(.segmented)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(StyleTag.allCases) { tag in
                        Button {
                            toggle(tag)
                        } label: {
                            FilterChip(title: tag.displayName, isActive: styles.contains(tag))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - 结果

    @ViewBuilder
    private var results: some View {
        if drafts.isEmpty {
            ContentUnavailableView {
                Label("暂时搭不出来", systemImage: "wand.and.stars")
            } description: {
                Text("这个温度下没有合适的衣服。可能是温度区间没标对，或者衣服还在「已收纳」状态。")
            } actions: {
                Button("换一批") { generate() }
            }
            .padding(.top, 24)
        } else {
            ForEach(Array(drafts.enumerated()), id: \.offset) { index, draft in
                OutfitCardView(
                    draft: draft,
                    onSave: { save(draft) },
                    onRegenerate: { regenerate(at: index) }
                )
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("衣柜是空的", systemImage: "tshirt")
        } description: {
            Text("先去「衣柜」Tab 添加几件衣服，这里就会开始给你搭。")
        }
        .padding(.top, 24)
    }

    private var bottomActionBar: some View {
        HStack(spacing: 12) {
            Button {
                generate()
            } label: {
                Label("换一批", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Text("\(candidateCount) 件候选")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - 动作

    private var candidateCount: Int {
        OutfitEngine.candidates(from: wearingItems, request: currentRequest()).count
    }

    private func currentRequest(seed: UInt64? = nil) -> OutfitRequest {
        OutfitRequest(temperature: temperature, season: season, styles: styles, limit: 3, seed: seed)
    }

    private func toggle(_ tag: StyleTag) {
        if let index = styles.firstIndex(of: tag) {
            styles.remove(at: index)
        } else {
            styles.append(tag)
        }
    }

    private func generate() {
        let candidates = OutfitEngine.candidates(from: wearingItems, request: currentRequest())
        drafts = OutfitEngine.generate(from: candidates, request: currentRequest())
    }

    private func regenerate(at index: Int) {
        let candidates = OutfitEngine.candidates(from: wearingItems, request: currentRequest())
        // 生成几套候选，挑一个和当前这套成员不完全一样的
        let alternatives = OutfitEngine.generate(
            from: candidates,
            request: OutfitRequest(temperature: temperature, season: season, styles: styles, limit: 5)
        )
        let currentIDs = Set(drafts[index].itemIDs.map(\.uuidString))
        if let replacement = alternatives.first(where: { Set($0.itemIDs.map(\.uuidString)) != currentIDs }) {
            drafts[index] = replacement
        } else if let first = alternatives.first {
            drafts[index] = first
        }
    }

    private func save(_ draft: OutfitDraft<Clothing>) {
        let outfit = Outfit(
            name: "",
            styleTags: styles,
            seasons: [season],
            isGenerated: true
        )
        outfit.tempMin = draft.assignments.values.map(\.tempMin).min() ?? temperature
        outfit.tempMax = draft.assignments.values.map(\.tempMax).max() ?? temperature

        context.insert(outfit)
        for (slot, item) in draft.assignments {
            let outfitItem = OutfitItem(slot: slot, clothing: item)
            outfitItem.outfit = outfit
            context.insert(outfitItem)
            item.wearCount += 1
            item.lastWorn = .now
        }

        try? context.save()
        withAnimation { savedMessage = "已存入「我的搭配」" }
        Task {
            try? await Task.sleep(for: .seconds(2))
            withAnimation { savedMessage = nil }
        }
        generate()
    }
}
