import SwiftUI
import SwiftData
import PhotosUI
import UIKit

/// 新建 / 编辑一件衣物。
///
/// 交互原则（DESIGN.md §5.2）：**所有字段都有默认值，能直接保存**。
/// 名称、品牌、价格都可以留空 —— 先让衣服进得来，细节以后再补。
struct ClothingEditView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    /// nil = 新建
    let clothing: Clothing?

    @State private var draft = Draft()
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?

    private var isEditing: Bool { clothing != nil }

    private static let temperaturePresets: [(String, Double, Double)] = [
        ("严寒", -15, 0),
        ("冷", -5, 10),
        ("凉", 5, 18),
        ("舒适", 15, 25),
        ("热", 22, 32),
        ("炎热", 28, 40)
    ]

    var body: some View {
        NavigationStack {
            Form {
                photoSection
                basicSection
                seasonSection
                temperatureSection
                styleSection
                statusSection
                if isEditing {
                    Section {
                        Button(role: .destructive) {
                            deleteItem()
                        } label: {
                            Label("删除这件衣物", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(isEditing ? "编辑衣物" : "添加衣物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving)
                }
            }
            .alert("保存失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .onChange(of: pickerItem) { _, newValue in
                guard let newValue else { return }
                Task { await loadPickedImage(from: newValue) }
            }
            .task {
                if let clothing {
                    draft = Draft(clothing)
                }
            }
        }
    }

    // MARK: - 区块

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    Group {
                        if let pickedImage {
                            Image(uiImage: pickedImage)
                                .resizable()
                                .scaledToFill()
                        } else if let clothing, !clothing.imageFile.isEmpty || !clothing.thumbFile.isEmpty {
                            PhotoThumbnailView(
                                thumbName: clothing.thumbFile,
                                mainName: clothing.imageFile,
                                contentMode: .fill
                            )
                        } else {
                            ZStack {
                                Color(.secondarySystemBackground)
                                Image(systemName: "camera")
                                    .font(.largeTitle)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    .frame(width: 200, height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 16))

                    HStack(spacing: 16) {
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label(pickedImage == nil && clothing == nil ? "选照片" : "换照片", systemImage: "photo")
                        }
                        if pickedImage != nil {
                            Button(role: .destructive) {
                                pickedImage = nil
                                pickerItem = nil
                            } label: {
                                Label("撤销", systemImage: "arrow.uturn.backward")
                            }
                        }
                    }
                    .font(.footnote)
                }
                Spacer()
            }
            .padding(.vertical, 4)
        } footer: {
            Text("照片只保存在这台手机上，不会上传到任何服务器。")
        }
    }

    private var basicSection: some View {
        Section("基本信息") {
            TextField("名称（可留空，会自动生成）", text: $draft.name)

            Picker("分类", selection: $draft.category) {
                ForEach(ClothingCategory.allCases) { category in
                    Text(category.displayName).tag(category)
                }
            }

            TextField("子类（如 大衣 / 阔腿裤）", text: $draft.subcategory)

            HStack {
                Text("颜色")
                Spacer()
                TextField("如 黑色", text: $draft.colorName)
                    .multilineTextAlignment(.trailing)
            }

            TextField("品牌（可留空）", text: $draft.brand)
        }
    }

    private var seasonSection: some View {
        Section {
            HStack(spacing: 8) {
                ForEach(Season.allCases) { season in
                    let isOn = draft.seasons.contains(season)
                    Button {
                        toggle(season)
                    } label: {
                        Text(season.displayName)
                            .font(.subheadline.weight(isOn ? .semibold : .regular))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                isOn ? Color.accentColor.opacity(0.18) : Color(.secondarySystemBackground),
                                in: RoundedRectangle(cornerRadius: 8)
                            )
                            .foregroundStyle(isOn ? Color.accentColor : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        } header: {
            Text("季节（可多选）")
        } footer: {
            Text("过渡季的衣服可以同时勾选两个季节，比如风衣选「春 + 秋」。")
        }
    }

    private var temperatureSection: some View {
        Section {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(Self.temperaturePresets, id: \.0) { preset in
                        Button {
                            draft.tempMin = preset.1
                            draft.tempMax = preset.2
                        } label: {
                            FilterChip(
                                title: "\(preset.0) \(Int(preset.1))~\(Int(preset.2))°",
                                isActive: draft.tempMin == preset.1 && draft.tempMax == preset.2
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 4)
            }

            Stepper("最低 \(Int(draft.tempMin))°C", value: $draft.tempMin, in: -30...45, step: 1)
            Stepper("最高 \(Int(draft.tempMax))°C", value: $draft.tempMax, in: -30...45, step: 1)

            Toggle("可叠穿（打底 / 开衫 / 薄外套）", isOn: $draft.isLayerable)
        } header: {
            Text("适合的温度区间")
        } footer: {
            Text("这是「什么天气适合穿它」。推荐时会拿当天温度落进这个区间来筛。")
        }
        .onChange(of: draft.tempMin) { _, newValue in
            if newValue > draft.tempMax { draft.tempMax = newValue }
        }
        .onChange(of: draft.tempMax) { _, newValue in
            if newValue < draft.tempMin { draft.tempMin = newValue }
        }
    }

    private var styleSection: some View {
        Section("适合的场景（可多选）") {
            FlowRow(spacing: 8) {
                ForEach(StyleTag.allCases) { tag in
                    let isOn = draft.styleTags.contains(tag)
                    Button {
                        if isOn {
                            draft.styleTags.removeAll { $0 == tag }
                        } else {
                            draft.styleTags.append(tag)
                        }
                    } label: {
                        FilterChip(title: tag.displayName, isActive: isOn)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 2)

            Toggle("标为常用", isOn: $draft.isFavorite)
        }
    }

    private var statusSection: some View {
        Section {
            Picker("状态", selection: $draft.status) {
                ForEach(ClothingStatus.allCases) { status in
                    Text(status.displayName).tag(status)
                }
            }
            TextField("备注", text: $draft.note, axis: .vertical)
                .lineLimit(1...4)
        } header: {
            Text("状态")
        } footer: {
            Text("换季收起来的衣服标成「已收纳」，就不会出现在推荐里。")
        }
    }

    // MARK: - 动作

    private func toggle(_ season: Season) {
        if let index = draft.seasons.firstIndex(of: season) {
            draft.seasons.remove(at: index)
        } else {
            draft.seasons.append(season)
        }
        draft.seasons.sort { $0.rawValue < $1.rawValue }
    }

    private func loadPickedImage(from item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else { return }
            pickedImage = image
        } catch {
            errorMessage = "读取照片失败：\(error.localizedDescription)"
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let target: Clothing
        if let clothing {
            target = clothing
        } else {
            let newItem = Clothing()
            context.insert(newItem)
            target = newItem
        }

        // 先存图片，再存数据 —— 这样库里不会出现指向不存在文件的引用
        if let pickedImage {
            do {
                let names = try await ImageStore.shared.save(pickedImage, id: target.id)
                target.imageFile = names.main
                target.thumbFile = names.thumb
            } catch {
                errorMessage = "图片保存失败：\(error.localizedDescription)"
                return
            }
        }

        draft.apply(to: target)
        target.touch()

        do {
            try context.save()
        } catch {
            errorMessage = "写入失败：\(error.localizedDescription)"
            return
        }
        dismiss()
    }

    private func deleteItem() {
        guard let clothing else { return }
        let main = clothing.imageFile
        let thumb = clothing.thumbFile
        let cutout = clothing.cutoutFile
        do {
            // 走 ClothingService 而不是直接 context.delete：
            // 必须先把引用它的搭配槽位置空，否则搭配卡会指向已删除的对象。
            try ClothingService.delete(clothing, in: context)
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
            return
        }
        Task { await ImageStore.shared.deleteAll(main: main, thumb: thumb, cutout: cutout) }
        dismiss()
    }
}

// MARK: - 表单草稿
//
// 为什么不直接绑定 `Clothing`：`@Model` 对象的字段直接双向绑定容易在
// 「取消」时留下脏数据。这里用一份值类型草稿，点保存才写回去。

extension ClothingEditView {
    struct Draft {
        var name = ""
        var category: ClothingCategory = .top
        var subcategory = ""
        var colorName = ""
        var brand = ""
        var seasons: [Season] = []
        var tempMin: Double = 15
        var tempMax: Double = 26
        var isLayerable = false
        var styleTags: [StyleTag] = []
        var isFavorite = false
        var status: ClothingStatus = .wearing
        var note = ""

        init() {}

        init(_ item: Clothing) {
            name = item.name
            category = item.category
            subcategory = item.subcategory
            colorName = item.colorName
            brand = item.brand
            seasons = item.seasons
            tempMin = item.tempMin
            tempMax = item.tempMax
            isLayerable = item.isLayerable
            styleTags = item.styleTags
            isFavorite = item.isFavorite
            status = item.status
            note = item.note
        }

        func apply(to item: Clothing) {
            item.name = name
            item.category = category
            item.subcategory = subcategory
            item.colorName = colorName
            item.brand = brand
            item.seasons = seasons
            item.tempMin = min(tempMin, tempMax)
            item.tempMax = max(tempMin, tempMax)
            item.isLayerable = isLayerable
            item.styleTags = styleTags
            item.isFavorite = isFavorite
            item.status = status
            item.note = note
        }
    }
}

// MARK: - 简单的自动换行布局

struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentY += rowHeight + spacing
                currentX = 0
                rowHeight = 0
            }
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? currentX : maxWidth, height: currentY + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var currentX = bounds.minX
        var currentY = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > bounds.maxX, currentX > bounds.minX {
                currentY += rowHeight + spacing
                currentX = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: currentX, y: currentY), proposal: ProposedViewSize(size))
            currentX += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
