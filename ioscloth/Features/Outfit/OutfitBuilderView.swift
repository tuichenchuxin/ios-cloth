import SwiftUI
import SwiftData

/// 自己搭一套：按部位一行一行挑衣服，随时保存。
///
/// 这是 App 的**核心功能** —— 用户要的是「我自己挑衣服配成一套」，
/// 随机推荐只是不知道穿什么时的辅助。
///
/// 交互要点：
/// - 一行一个部位，点一下弹出该部位的候选（只列**在穿**的衣服）
/// - 已选的部位显示缩略图和名称，再点一下可以换/清除
/// - 选了连衣裙会自动隐藏上装/下装（连衣裙自带上下身）
/// - 底部实时提示「还差什么」，凑齐才能保存
struct OutfitBuilderView: View {
    /// 参考温度：用来把候选按当前天气排序，方便先看到合适的
    let temperature: Double?
    let season: Season

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @Query(filter: #Predicate<Clothing> { $0.statusRaw == "wearing" })
    private var wearingItems: [Clothing]

    @State private var selection: [OutfitSlot: Clothing] = [:]
    @State private var pickingSlot: OutfitSlot?
    @State private var name = ""

    var body: some View {
        NavigationStack {
            List {
                if let hint = OutfitRules.missingHint(selection) {
                    Section {
                        Label(hint, systemImage: "exclamationmark.circle")
                            .font(.footnote)
                            .foregroundStyle(.orange)
                    }
                }

                Section {
                    ForEach(OutfitRules.visibleSlots(for: selection), id: \.self) { slot in
                        slotRow(slot)
                    }
                } header: {
                    Text("挑衣服")
                } footer: {
                    Text("点一行选衣服；再点一次可以换或清空。")
                }

                Section("这套的名字（可留空）") {
                    TextField(OutfitRules.autoName(selection), text: $name)
                }
            }
            .navigationTitle("自己搭一套")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(!OutfitRules.isComplete(selection))
                }
            }
            .sheet(item: $pickingSlot) { slot in
                SlotPickerSheet(
                    slot: slot,
                    temperature: temperature,
                    season: season,
                    items: candidates(for: slot),
                    selected: selection[slot]
                ) { picked in
                    apply(picked, to: slot)
                    pickingSlot = nil
                }
            }
        }
    }

    // MARK: - 行

    private func slotRow(_ slot: OutfitSlot) -> some View {
        Button {
            pickingSlot = slot
        } label: {
            HStack(spacing: 12) {
                if let item = selection[slot] {
                    PhotoThumbnailView(thumbName: item.thumbFile, mainName: item.imageFile)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(.secondarySystemBackground))
                        .frame(width: 48, height: 48)
                        .overlay {
                            Image(systemName: "plus")
                                .foregroundStyle(.secondary)
                        }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(slot.displayName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(selection[slot]?.displayName ?? "未选择")
                        .font(.subheadline)
                        .foregroundStyle(selection[slot] == nil ? .tertiary : .primary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            // 关键：让整行都可点。否则中间那段 Spacer 不接收点击，
            // 用户点在行的空白处会没反应（自己测的时候也踩到了）。
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("slot-\(slot.rawValue)")
    }

    // MARK: - 数据

    /// 该部位的候选：只列在穿的、分类能对上的
    private func candidates(for slot: OutfitSlot) -> [Clothing] {
        wearingItems
            .filter { $0.category.slot == slot }
            .sorted { lhs, rhs in
                // 先把符合当前温度的排在前面，其次是最近录入的
                let lhsFit = temperature.map { lhs.matches(temperature: $0, tolerance: 5) } ?? false
                let rhsFit = temperature.map { rhs.matches(temperature: $0, tolerance: 5) } ?? false
                if lhsFit != rhsFit { return lhsFit }
                return lhs.createdAt > rhs.createdAt
            }
    }

    private func apply(_ picked: Clothing?, to slot: OutfitSlot) {
        if let picked {
            for other in OutfitRules.slotsToClear(whenPicking: slot) {
                selection[other] = nil
            }
            selection[slot] = picked
        } else {
            selection[slot] = nil
        }
    }

    // MARK: - 保存

    private func save() {
        guard OutfitRules.isComplete(selection) else { return }

        let outfit = Outfit(
            name: name.trimmingCharacters(in: .whitespaces),
            seasons: [season]
        )
        let items = selection.values.map { $0 }
        let range = OutfitRules.temperatureRange(of: items)
        outfit.tempMin = range.min
        outfit.tempMax = range.max
        context.insert(outfit)

        for (slot, item) in selection {
            let outfitItem = OutfitItem(slot: slot, clothing: item)
            outfitItem.outfit = outfit
            context.insert(outfitItem)
        }

        try? context.save()
        dismiss()
    }
}

// MARK: - 部位候选选择

/// 某个部位的候选衣物网格。点一件就返回。
private struct SlotPickerSheet: View {
    let slot: OutfitSlot
    let temperature: Double?
    let season: Season
    let items: [Clothing]
    /// 当前已选的（用来高亮）
    let selected: Clothing?
    let onPick: (Clothing?) -> Void

    @Environment(\.dismiss) private var dismiss

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 10)]

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    ContentUnavailableView {
                        Label("这个部位还没有衣服", systemImage: "tshirt")
                    } description: {
                        Text("先去「衣柜」里加几件「\(slot.displayName)」，并且状态是「在穿」。")
                    }
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 10) {
                            ForEach(items) { item in
                                Button {
                                    onPick(item)
                                } label: {
                                    candidateCard(item)
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("candidate-\(item.displayName)")
                            }
                        }
                        .padding(.horizontal)
                    }
                }
            }
            .navigationTitle("选\(slot.displayName)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                if selected != nil {
                    ToolbarItem(placement: .primaryAction) {
                        Button("清空", role: .destructive) { onPick(nil) }
                    }
                }
            }
        }
    }

    private func candidateCard(_ item: Clothing) -> some View {
        let isSelected = selected?.id == item.id
        return VStack(alignment: .leading, spacing: 4) {
            PhotoThumbnailView(thumbName: item.thumbFile, mainName: item.imageFile)
                .frame(height: 110)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 3)
                    }
                }

            Text(item.displayName)
                .font(.caption)
                .lineLimit(1)
            Text(item.temperatureLabel)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}
