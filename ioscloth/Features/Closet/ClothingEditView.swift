import SwiftUI
import SwiftData
import UIKit

/// 表单的「外壳」：标题 + 工具栏，内容交给 `ClothingForm`。
///
/// **它不自己关闭自己**，也不持有 sheet / path。关闭由调用方改自己的
/// `isPresented` 完成 —— 这是刻意的，原因见 `ClothingForm` 顶部注释。
struct ClothingEditView: View {
    /// 工具栏发起的保存请求
    enum SaveRequest: Equatable {
        case continueBatch
        case finish
    }

    /// 编辑已有衣物时传入；nil 表示新建
    let clothing: Clothing?
    /// 拍照 / 相册来的图片
    let capturedImage: UIImage?
    /// 新建时的初始值；保存后会被写回继承值，供下一件使用
    @Binding var seed: Draft
    /// 保存成功
    let onSaved: (_ continueBatch: Bool) -> Void
    /// 用户放弃录入
    let onCancel: () -> Void

    @State private var browseDraft = Draft()
    @State private var saveRequest: SaveRequest?
    @State private var deleteRequest = false

    init(
        clothing: Clothing? = nil,
        capturedImage: UIImage? = nil,
        seed: Binding<Draft>,
        onSaved: @escaping (_ continueBatch: Bool) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.clothing = clothing
        self.capturedImage = capturedImage
        self._seed = seed
        self.onSaved = onSaved
        self.onCancel = onCancel
        _browseDraft = State(initialValue: seed.wrappedValue)
    }

    /// 批量录入中（有照片、不是编辑已有的）→ 工具栏给两个保存按钮
    private var isBatchEntry: Bool {
        clothing == nil && capturedImage != nil
    }

    var body: some View {
        NavigationStack {
            ClothingForm(
                clothing: clothing,
                capturedImage: capturedImage,
                seed: $browseDraft,
                saveRequest: $saveRequest,
                deleteRequest: $deleteRequest,
                onSave: { request in
                    // 之前这里写成了恒定的 onSaved(true)，导致「保存并结束」
                    // 也被当成「保存并继续」处理，于是永远回到相机。
                    onSaved(request == .continueBatch)
                }
            )
            .navigationTitle(clothing == nil ? "添加衣物" : "编辑衣物")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(clothing == nil ? "返回" : "取消", action: onCancel)
                }
            }
            // 保存按钮用 safeAreaInset 固定在底部：它在滚动区之外**永远可见**，
            // 不像工具栏按钮那样会被键盘挡住的滚动区盖住（踩过这个坑）。
            .safeAreaInset(edge: .bottom) { saveBar }
        }
    }

    /// 底部保存栏
    @ViewBuilder
    private var saveBar: some View {
        HStack(spacing: 12) {
            if isBatchEntry {
                Button {
                    save(.continueBatch)
                } label: {
                    Label("保存并继续", systemImage: "checkmark.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    save(.finish)
                } label: {
                    Label("保存并结束", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    save(.finish)
                } label: {
                    Label("保存", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .controlSize(.large)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .background(.bar)
    }

    /// 把这次填的值整理成下一件的继承值，并请表单执行保存
    private func save(_ request: SaveRequest) {
        seed = browseDraft.inherited()
        saveRequest = request
    }
}

// MARK: - 表单草稿
//
// 用值类型草稿而不是直接绑定 `Clothing`：`@Model` 对象直接双向绑定
// 在「取消」时会留下脏数据。点保存才写回。

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

        static let temperaturePresets: [(name: String, min: Double, max: Double)] = [
            ("严寒", -15, 0),
            ("冷", -5, 10),
            ("凉", 5, 18),
            ("舒适", 15, 25),
            ("热", 22, 32),
            ("炎热", 28, 40)
        ]

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

        /// 下一件要继承的部分：只留「同一季的衣服通常一样」的字段。
        ///
        /// 刻意不继承 `name` / `subcategory`（每件都不一样）、
        /// `isFavorite`（偏个人的标记）、`note`（这一件特有的）。
        func inherited() -> Draft {
            var next = Draft()
            next.category = category
            next.colorName = colorName
            next.brand = brand
            next.seasons = seasons
            next.tempMin = tempMin
            next.tempMax = tempMax
            next.isLayerable = isLayerable
            next.styleTags = styleTags
            next.status = status
            return next
        }
    }
}

// MARK: - 自动换行布局

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
