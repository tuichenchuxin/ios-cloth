import SwiftUI
import SwiftData
import UIKit

struct ClosetView: View {
    @Environment(\.modelContext) private var context
    @Query private var allItems: [Clothing]

    @State private var filter = ClosetFilter()
    @State private var search = ""
    @State private var isCapturing = false
    @State private var isAddingBlank = false
    @State private var editingItem: Clothing?

    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 12)]

    var body: some View {
        NavigationStack {
            Group {
                if visibleItems.isEmpty {
                    emptyState
                } else {
                    grid
                }
            }
            .navigationTitle("衣柜")
            .searchable(text: $search, prompt: "名称 / 颜色 / 子类")
            .safeAreaInset(edge: .top) { filterBar }
            .toolbar {
                ToolbarItem(placement: .primaryAction) { addMenu }
            }
            .fullScreenCover(isPresented: $isCapturing) {
                // ⚠️ 录入**只有这一条路**。
                // 这里曾经另外挂过一个 `.photosPicker` + `.sheet(mode: .singlePhoto)`，
                // 结果相册走那条老路、拍照走 CaptureFlowView，两套代码行为不一致：
                // 相册会跳过裁切页、也没有「保存并继续」。
                // 新增录入方式时请一律加进 CaptureFlowView 的入口页，不要再在这里并行开一条。
                CaptureFlowView { isCapturing = false }
            }
            .sheet(isPresented: $isAddingBlank) {
                ClothingEditView(mode: .singlePhoto)
            }
            .sheet(item: $editingItem) { item in
                ClothingEditView(clothing: item, mode: .editing)
            }
        }
    }

    /// 添加衣物的入口。
    private var addMenu: some View {
        Menu {
            Button {
                isCapturing = true
            } label: {
                Label("拍照 / 从相册录入", systemImage: "camera.fill")
            }

            Divider()

            Button {
                editingItem = nil
                isAddingBlank = true
            } label: {
                Label("手动新建（不拍照）", systemImage: "square.and.pencil")
            }
        } label: {
            Label("添加", systemImage: "plus")
        }
    }

    // MARK: - 计算后的可见列表

    private var visibleItems: [Clothing] {
        let keyword = search.trimmingCharacters(in: .whitespaces).lowercased()
        return allItems
            .filter { filter.matches($0) }
            .filter { item in
                guard !keyword.isEmpty else { return true }
                return item.displayName.lowercased().contains(keyword)
                    || item.colorName.lowercased().contains(keyword)
                    || item.brand.lowercased().contains(keyword)
                    || item.subcategory.lowercased().contains(keyword)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: - 子视图

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(visibleItems) { item in
                    Button {
                        editingItem = item
                    } label: {
                        ClothingGridCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 24)
        }
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    Picker("状态", selection: $filter.status) {
                        Text("全部状态").tag(ClothingStatus?.none)
                        ForEach(ClothingStatus.allCases) { status in
                            Text(status.displayName).tag(ClothingStatus?.some(status))
                        }
                    }
                } label: {
                    FilterChip(
                        title: filter.status?.displayName ?? "状态",
                        isActive: filter.status != nil
                    )
                }

                Menu {
                    Picker("季节", selection: $filter.season) {
                        Text("全部季节").tag(Season?.none)
                        ForEach(Season.allCases) { season in
                            Text(season.displayName).tag(Season?.some(season))
                        }
                    }
                } label: {
                    FilterChip(
                        title: filter.season?.displayName ?? "季节",
                        isActive: filter.season != nil
                    )
                }

                Menu {
                    Picker("分类", selection: $filter.category) {
                        Text("全部分类").tag(ClothingCategory?.none)
                        ForEach(ClothingCategory.allCases) { category in
                            Text(category.displayName).tag(ClothingCategory?.some(category))
                        }
                    }
                } label: {
                    FilterChip(
                        title: filter.category?.displayName ?? "分类",
                        isActive: filter.category != nil
                    )
                }

                if filter.isActive {
                    Button {
                        filter = ClosetFilter()
                    } label: {
                        FilterChip(title: "清除", isActive: false)
                    }
                }

                Text("\(visibleItems.count) 件")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .background(.bar)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(allItems.isEmpty ? "衣柜还是空的" : "没有符合条件的衣服", systemImage: "tshirt")
        } description: {
            if allItems.isEmpty {
                Text("点右上角 + 开始录入。\n同一季的衣服可以连着拍，季节和温度会自动沿用上一件。")
            } else {
                Text("换个筛选条件，或清空搜索关键词。")
            }
        } actions: {
            if allItems.isEmpty {
                Button("拍照录入") { isCapturing = true }
                    .buttonStyle(.borderedProminent)
            } else {
                Button("清除筛选") { filter = ClosetFilter() }
            }
        }
    }
}

// MARK: - 筛选条件

struct ClosetFilter {
    var status: ClothingStatus?
    var season: Season?
    var category: ClothingCategory?

    var isActive: Bool {
        status != nil || season != nil || category != nil
    }

    func matches(_ item: Clothing) -> Bool {
        if let status, item.status != status { return false }
        if let season, !item.seasons.contains(season) { return false }
        if let category, item.category != category { return false }
        return true
    }
}

// MARK: - 图墙卡片

struct ClothingGridCard: View {
    let item: Clothing

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            PhotoThumbnailView(thumbName: item.thumbFile, mainName: item.imageFile)
                .frame(height: 128)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .topTrailing) {
                    if item.isFavorite {
                        Image(systemName: "star.fill")
                            .font(.caption)
                            .padding(5)
                            .background(.thinMaterial, in: Circle())
                            .padding(5)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if item.status != .wearing {
                        Text(item.status.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.thinMaterial, in: Capsule())
                            .padding(5)
                    }
                }

            Text(item.displayName)
                .font(.subheadline)
                .lineLimit(1)

            HStack(spacing: 4) {
                Text(item.seasonLabel)
                Text("·")
                Text(item.temperatureLabel)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }
    }
}

// MARK: - 通用胶囊

struct FilterChip: View {
    let title: String
    var isActive: Bool = false

    var body: some View {
        Text(title)
            .font(.footnote.weight(isActive ? .semibold : .regular))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isActive ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground), in: Capsule())
            .foregroundStyle(isActive ? Color.accentColor : Color.primary)
    }
}
