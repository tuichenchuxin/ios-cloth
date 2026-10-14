import SwiftUI
import SwiftData

/// 「我的搭配」—— 存下来的搭配 + 穿着历史 + 数据体检入口。
struct SavedOutfitsView: View {
    @Environment(\.modelContext) private var context
    @Query private var outfits: [Outfit]

    @State private var showHealthCheck = false

    var body: some View {
        NavigationStack {
            Group {
                if outfits.isEmpty {
                    ContentUnavailableView {
                        Label("还没有存过搭配", systemImage: "heart")
                    } description: {
                        Text("在「搭配」Tab 里看到满意的组合，点「就这套」就会存到这里。")
                    }
                } else {
                    list
                }
            }
            .navigationTitle("我的搭配")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showHealthCheck = true
                    } label: {
                        Label("数据体检", systemImage: "stethoscope")
                    }
                }
            }
            .sheet(isPresented: $showHealthCheck) {
                DataHealthView()
            }
        }
    }

    private var list: some View {
        List {
            ForEach(sortedOutfits) { outfit in
                OutfitRow(outfit: outfit)
            }
            .onDelete(perform: delete)
        }
    }

    private var sortedOutfits: [Outfit] {
        outfits.sorted { lhs, rhs in
            if lhs.isFavorite != rhs.isFavorite { return lhs.isFavorite }
            return lhs.createdAt > rhs.createdAt
        }
    }

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { sortedOutfits[$0] }
        for outfit in targets {
            context.delete(outfit)
        }
        try? context.save()
    }
}

private struct OutfitRow: View {
    @Environment(\.modelContext) private var context
    let outfit: Outfit

    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(outfit.orderedItems) { item in
                        PhotoThumbnailView(
                            thumbName: item.clothing?.thumbFile ?? "",
                            mainName: item.clothing?.imageFile ?? ""
                        )
                        .frame(width: 46, height: 46)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .frame(maxWidth: 180, alignment: .leading)

            VStack(alignment: .leading, spacing: 3) {
                Text(outfit.displayName)
                    .font(.subheadline)
                    .lineLimit(1)
                Text("\(outfit.temperatureLabel) · \(outfit.seasons.map(\.displayName).joined(separator: "/"))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                outfit.isFavorite.toggle()
                try? context.save()
            } label: {
                Image(systemName: outfit.isFavorite ? "star.fill" : "star")
                    .foregroundStyle(outfit.isFavorite ? .yellow : .secondary)
            }
            .buttonStyle(.plain)
        }
    }
}

/// 数据体检：把「录得不完整的地方」列出来，方便一点点补齐（DESIGN.md §6）。
struct DataHealthView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query private var items: [Clothing]

    @State private var orphanCount = 0
    @State private var diskUsage: Int64 = 0

    var body: some View {
        NavigationStack {
            List {
                Section("待完善") {
                    healthRow("没有照片", items.filter { $0.imageFile.isEmpty && $0.thumbFile.isEmpty }.count)
                    healthRow("没有标季节", items.filter(\.seasons.isEmpty).count)
                    healthRow("没有标场景", items.filter(\.styleTags.isEmpty).count)
                    healthRow("超过 60 天没穿", items.filter { item in
                        guard let last = item.lastWorn else { return false }
                        let days = Calendar.current.dateComponents([.day], from: last, to: .now).day ?? 0
                        return days > 60
                    }.count)
                }

                Section("存储") {
                    healthRow("衣物总数", items.count)
                    LabeledContent("图片占用", value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                    LabeledContent("幽灵图片", value: "\(orphanCount) 个")
                }

                Section {
                    Text("幽灵图片 = 磁盘上存在、但数据库里已经没有引用的文件（多半是中途失败留下的）。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("数据体检")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await refresh() }
        }
    }

    private func healthRow(_ title: String, _ value: Int) -> some View {
        LabeledContent(title, value: "\(value)")
    }

    private func refresh() async {
        diskUsage = await ImageStore.shared.diskUsage()
        var known = Set<String>()
        for item in items {
            if !item.imageFile.isEmpty { known.insert(item.imageFile) }
            if !item.thumbFile.isEmpty { known.insert(item.thumbFile) }
            if !item.cutoutFile.isEmpty { known.insert(item.cutoutFile) }
        }
        orphanCount = await ImageStore.shared.orphanedFiles(knownNames: known).count
    }
}
