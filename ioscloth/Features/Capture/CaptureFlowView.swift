import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// 录入流程的调度器：**拍照 → 调整 → 填表 →（批量）回到拍照**。
///
/// 这是整个 App 最重要的一条路径（DESIGN.md §5.2）。
/// 衡量它好坏的唯一标准是：同一季的衣服连拍 20 件要多久。
/// 所以每一步都把「不用做决定」当作设计目标：
/// - 打开就是拍照状态，不用先选「从哪导入」
/// - 裁切框打开就居中填满，直接点「完成」就行
/// - 表单的季节/温度/场景继承上一件，只需按「保存并继续」
///
/// ## 模态结构（改之前务必先读，这里踩过坑）
///
/// 三种步骤各用一种呈现方式，**互不嵌套**：
/// - 相机 → `fullScreenCover`（系统相机自己就是全屏）
/// - 裁切 → 在 `NavigationStack` 里 push
/// - 表单 → `sheet`
///
/// 三条铁律：
/// 1. 任何子视图**不自己 dismiss 自己**，一律回调给本视图改状态；
/// 2. `fullScreenCover` 的 `isPresented` **必须是真实绑定**，不能是 `.constant(true)`
///    （之前用常量绑定 + 相机自己 dismiss，点「使用照片」时会把整个流程一起拆掉，
///    表现成「点了 Use 什么都没发生」）；
/// 3. 表单保存后**先关 sheet，等它真的收起来了再切页**，
///    否则「正在关闭的 sheet」和「新页面的切换」撞在一起，SwiftUI 会把两者一起拆掉。
///    这就是 `pendingStage` 存在的原因。
struct CaptureFlowView: View {
    /// 流程结束
    let onFinish: () -> Void

    @State private var captured: UIImage?
    /// 本批次已录入件数。既用来显示进度，也用来给表单换身份，保证继承生效。
    @State private var recordedCount = 0
    /// 下一件要继承的字段
    @State private var inheritedSeed: ClothingEditView.Draft?

    @State private var path: [Step] = []
    @State private var isCameraPresented = false
    @State private var isFormPresented = false
    /// 表单关掉之后要切到哪个页面（见上面铁律 3）
    @State private var pendingStage: PendingStage?

    @State private var isPickingFromLibrary = false
    @State private var libraryItem: PhotosPickerItem?

    /// 会被 push 的页面
    private enum Step: Hashable {
        case cropping
    }

    private enum PendingStage {
        case camera
        case finish
    }

    var body: some View {
        NavigationStack(path: $path) {
            entryScreen
                .navigationDestination(for: Step.self) { step in
                    switch step {
                    case .cropping:
                        croppingScreen
                    }
                }
        }
        .fullScreenCover(isPresented: $isCameraPresented) {
            if CameraPicker.isAvailable {
                CameraPicker(
                    onCapture: { image in
                        captured = image
                        isCameraPresented = false
                        path = [.cropping]
                    },
                    onCancel: { isCameraPresented = false }
                )
                .ignoresSafeArea()
            }
        }
        .sheet(isPresented: $isFormPresented, onDismiss: handleFormDismissed) {
            formScreen
        }
        .photosPicker(isPresented: $isPickingFromLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, newValue in
            guard let newValue else { return }
            Task { await handleLibraryPick(newValue) }
        }
    }

    // MARK: - 入口页

    private var entryScreen: some View {
        VStack(spacing: 24) {
            Spacer()

            if recordedCount > 0 {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text("已录入 \(recordedCount) 件")
                        .font(.headline)
                }
            }

            VStack(spacing: 10) {
                Image(systemName: "tshirt")
                    .font(.system(size: 52))
                    .foregroundStyle(.tertiary)
                Text(recordedCount > 0 ? "继续录下一件" : "开始录入衣物")
                    .font(.title3.weight(.medium))
                Text("同一季的衣服连着拍，季节和温度会自动沿用上一件。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()

            VStack(spacing: 12) {
                Button {
                    isCameraPresented = true
                } label: {
                    Label("拍照", systemImage: "camera.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!CameraPicker.isAvailable)

                Button {
                    isPickingFromLibrary = true
                } label: {
                    Label("从相册选", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                if !CameraPicker.isAvailable {
                    Text("模拟器没有相机，请用「从相册选」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .navigationTitle("添加衣物")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(recordedCount > 0 ? "完成" : "取消", action: onFinish)
            }
        }
    }

    // MARK: - 裁切页（push 进来，不自己关闭）

    @ViewBuilder
    private var croppingScreen: some View {
        if let captured {
            ImageCropper(
                image: captured,
                onDone: { cropped in
                    self.captured = cropped
                    path.removeAll()
                    isFormPresented = true
                },
                onCancel: {
                    self.captured = nil
                    path.removeAll()
                }
            )
        } else {
            // 理论上到不了；真到了就退回去，别白屏
            Color.clear.onAppear { path.removeAll() }
        }
    }

    // MARK: - 表单（sheet，不自己关闭）

    @ViewBuilder
    private var formScreen: some View {
        if let captured {
            ClothingEditView(
                capturedImage: captured,
                mode: recordedCount == 0 ? .firstInBatch : .continuingBatch,
                seed: inheritedSeed,
                onSaved: { continueBatch, draft in
                    recordedCount += 1
                    if continueBatch {
                        inheritedSeed = draft.inherited()
                        pendingStage = .camera
                    } else {
                        pendingStage = .finish
                    }
                },
                onCancel: {
                    pendingStage = nil
                }
            )
            // 每件换一个身份，保证下一次进来重新读 seed（继承才会生效）
            .id(recordedCount)
        } else {
            Color.clear
        }
    }

    /// sheet 已经完全收起来之后才切页 —— 避免「正在关闭的 sheet」和「新页面」互相拆台
    private func handleFormDismissed() {
        guard let pendingStage else { return }
        self.pendingStage = nil
        self.captured = nil
        switch pendingStage {
        case .camera:
            isCameraPresented = true
        case .finish:
            onFinish()
        }
    }

    // MARK: - 相册

    private func handleLibraryPick(_ item: PhotosPickerItem) async {
        defer { libraryItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        // 相册里的图多半已经裁好了，但统一走裁切页 —— 风格一致，也方便再修一下
        captured = image
        path = [.cropping]
    }
}
