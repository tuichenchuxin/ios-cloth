import SwiftUI
import UIKit
import PhotosUI

/// 录入表单的内容。
///
/// ## 职责边界（重要）
/// 这个视图**只管表单本身**：没有 `NavigationStack`、没有工具栏、不自己关闭自己。
/// 标题和按钮由外层（`ClothingEditView`）提供。
///
/// 之所以这么切：之前的版本自己带 `NavigationStack` + 工具栏，还用
/// `@Environment(\.dismiss)` 关自己，结果按钮点了没反应（界面对不上真实状态），
/// 只有手动下滑才关掉。**让子视图自己关闭自己是万恶之源**，
/// 现在关闭动作一律由外层发起，外层持有 `isPresented`/`path`，状态永远一致。
///
/// 本地保留一份 `draft` 值类型副本，点保存时才写回 `Binding`，
/// 这样「取消」不会留下脏数据。
struct ClothingForm: View {
    /// 编辑已有衣物时传入；nil 表示新建
    let clothing: Clothing?
    /// 拍照/相册来的图片。有它就锁住，不允许再换照片（要换就退出重来，避免流程分叉）
    let capturedImage: UIImage?
    /// 新建时的初始值（批量录入靠它继承上一件的季节/温度/场景）
    @Binding var seed: ClothingEditView.Draft
    /// 保存成功
    let onSave: () -> Void
    /// 外层工具栏发来的保存请求
    @Binding var saveRequest: ClothingEditView.SaveRequest?
    /// 外层工具栏发来的删除请求
    @Binding var deleteRequest: Bool

    @Environment(\.modelContext) private var context

    @State private var draft = ClothingEditView.Draft()
    @State private var pickerItem: PhotosPickerItem?
    @State private var pickedImage: UIImage?
    @State private var isSaving = false
    @State private var errorMessage: String?
    @FocusState private var isNameFocused: Bool

    init(
        clothing: Clothing?,
        capturedImage: UIImage?,
        seed: Binding<ClothingEditView.Draft>,
        saveRequest: Binding<ClothingEditView.SaveRequest?>,
        deleteRequest: Binding<Bool>,
        onSave: @escaping () -> Void
    ) {
        self.clothing = clothing
        self.capturedImage = capturedImage
        self._seed = seed
        self._saveRequest = saveRequest
        self._deleteRequest = deleteRequest
        self.onSave = onSave

        // 编辑已有衣物就回填；新建就用外层给的继承值
        if let clothing {
            _draft = State(initialValue: ClothingEditView.Draft(clothing))
        } else {
            _draft = State(initialValue: seed.wrappedValue)
        }
    }

    /// 当前展示的照片：优先拍照来的，其次相册刚选的，最后是已保存的
    private var displayImage: UIImage? {
        capturedImage ?? pickedImage
    }

    var body: some View {
        Form {
            photoSection
            basicSection
            seasonSection
            temperatureSection
            styleSection
            statusSection
        }
        .scrollDismissesKeyboard(.interactively)
        .alert("出错了", isPresented: Binding(
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
        // 保存/删除按钮在**外层工具栏**（那里不会被键盘挡住），
        // 表单只负责响应请求。这样避免了「底部工具栏被键盘盖住点不到」的老问题。
        .onChange(of: saveRequest) { _, newValue in
            guard let newValue else { return }
            saveRequest = nil
            Task { await save(continueBatch: newValue == .continueBatch) }
        }
        .onChange(of: deleteRequest) { _, newValue in
            guard newValue else { return }
            deleteRequest = false
            deleteItem()
        }
    }

    // MARK: - 区块

    private var photoSection: some View {
        Section {
            HStack {
                Spacer()
                VStack(spacing: 12) {
                    Group {
                        if let displayImage {
                            Image(uiImage: displayImage)
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

                    // 从相册来的图已经锁定了，就不再给相册入口
                    if capturedImage == nil {
                        HStack(spacing: 16) {
                            PhotosPicker(selection: $pickerItem, matching: .images) {
                                Label(displayImage == nil ? "选照片" : "换照片", systemImage: "photo")
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
                .accessibilityIdentifier("衣物名称输入框")
                .focused($isNameFocused)

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
                    ForEach(ClothingEditView.Draft.temperaturePresets, id: \.name) { preset in
                        Button {
                            draft.tempMin = preset.min
                            draft.tempMax = preset.max
                        } label: {
                            FilterChip(
                                title: "\(preset.name) \(Int(preset.min))~\(Int(preset.max))°",
                                isActive: draft.tempMin == preset.min && draft.tempMax == preset.max
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

            if clothing != nil {
                Button(role: .destructive) {
                    deleteItem()
                } label: {
                    Label("删除这件衣物", systemImage: "trash")
                }
            }
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

    private func save(continueBatch: Bool = true) async {
        isSaving = true
        defer { isSaving = false }

        let target = clothing ?? Clothing()
        if clothing == nil { context.insert(target) }

        // 先存图片，再存数据 —— 库里不会出现指向不存在文件的引用
        if let image = displayImage {
            do {
                let names = try await ImageStore.shared.save(image, id: target.id)
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

        // 把这次填的值交回给外层，供下一件继承
        seed = draft
        onSave()
    }

    private func deleteItem() {
        guard let clothing else { return }
        let main = clothing.imageFile
        let thumb = clothing.thumbFile
        let cutout = clothing.cutoutFile
        do {
            try ClothingService.delete(clothing, in: context)
        } catch {
            errorMessage = "删除失败：\(error.localizedDescription)"
            return
        }
        Task { await ImageStore.shared.deleteAll(main: main, thumb: thumb, cutout: cutout) }
        onSave()
    }
}
