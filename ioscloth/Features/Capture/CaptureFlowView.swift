import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// 录入流程的调度器：**入口页 → 拍照/相册 → 裁切 → 表单 →（批量）回到相机**。
///
/// 这是整个 App 最重要的一条路径（DESIGN.md §5.2）。
/// 衡量它好坏的唯一标准是：同一季的衣服连拍 20 件要多久。
/// 所以每一步都把「不用做决定」当作设计目标：
/// - 相机 / 相册两个大按钮，不用先理解别的概念
/// - 裁切框打开就居中填满，直接点「完成」就行
/// - 表单的季节/温度/场景继承上一件，只需按「保存并继续」
///
/// ## 两条必须守住的规则（改之前务必先读，这里踩过两次坑）
///
/// **1. 任何子视图都不许自己关闭自己。**
///    关闭一律由本视图改 `scene` 完成，子视图只回调。
///    之前 `ClothingEditView` 和 `CameraPicker` 各自调 `dismiss()`，结果
///    sheet 的绑定和真实状态对不上 —— 按钮点了没反应，只有手动下滑才关得掉，
///    而数据其实早就保存成功了。
///
/// **2. 关掉一个模态、再开另一个（或反过来）时，必须等前一个收干净。**
///    正在关闭的 sheet 和正在打开的 cover 撞在一起，SwiftUI 会把两者一起丢掉
///    （表现为「点了使用照片什么都没发生」）。所以切场景走 `enter(_:)`，
///    它保证「先关旧的 → 等动画 → 再开新的」。
struct CaptureFlowView: View {
    /// 流程结束
    let onFinish: () -> Void

    private enum Scene: Equatable {
        case idle
        case camera
        case cropping
        case form
    }

    @State private var scene: Scene = .idle
    /// 本轮正在进入的场景。非 nil 时 `presentedScene` 保持旧值，
    /// 好让 SwiftUI 保留旧的呈现容器到动画结束。
    @State private var nextScene: Scene?
    @State private var captured: UIImage?
    /// 本批次已录入件数
    @State private var recordedCount = 0
    /// 下一件要继承的字段
    @State private var seed = ClothingEditView.Draft()

    @State private var isPickingFromLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var cameraUnavailableAlert = false

    /// 实际参与呈现的场景。切场景时**故意滞后**，等旧模态收干净。
    private var presentedScene: Scene { nextScene ?? scene }

    var body: some View {
        Group {
            switch presentedScene {
            case .camera:
                cameraScreen
            case .cropping:
                croppingScreen
            case .form:
                formScreen
            case .idle:
                entryScreen
            }
        }
        .photosPicker(isPresented: $isPickingFromLibrary, selection: $libraryItem, matching: .images)
        .onChange(of: libraryItem) { _, newValue in
            guard let newValue else { return }
            Task { await handleLibraryPick(newValue) }
        }
        .alert("这台设备没有可用的相机", isPresented: $cameraUnavailableAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("模拟器没有相机，请用「从相册选」。")
        }
    }

    // MARK: - 场景切换

    /// 关闭当前模态、等它收干净、再打开目标场景。
    ///
    /// 这个 400ms 不是凑数：sheet / cover 的收起动画约 0.35 秒，
    /// 在同一次状态更新里既关旧的又开新的，SwiftUI 会把两者一起丢掉。
    private func enter(_ target: Scene) {
        guard nextScene == nil else { return }

        let closingModal = scene != .idle

        if !closingModal {
            scene = target
            return
        }

        nextScene = target
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            // 只有离开表单时才丢掉这轮的照片：提前丢会让表单/裁切页提前变空，
            // 过渡期间闪一下，甚至把容器拆掉。
            if target != .form { captured = nil }
            scene = target
            nextScene = nil
        }
    }

    // MARK: - 入口页

    private var entryScreen: some View {
        NavigationStack {
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
                        if CameraPicker.isAvailable {
                            enter(.camera)
                        } else {
                            cameraUnavailableAlert = true
                        }
                    } label: {
                        Label("拍照", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

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
    }

    // MARK: - 相机（自己是一个全屏模态，不自己关闭）

    private var cameraScreen: some View {
        CameraPicker(
            onCapture: { image in
                captured = image
                enter(.cropping)
            },
            onCancel: { enter(.idle) }
        )
        .ignoresSafeArea()
    }

    // MARK: - 裁切

    @ViewBuilder
    private var croppingScreen: some View {
        if let captured {
            NavigationStack {
                ImageCropper(
                    image: captured,
                    onDone: { cropped in
                        self.captured = cropped
                        enter(.form)
                    },
                    onCancel: { enter(.idle) }
                )
            }
        } else {
            Color.clear.onAppear { enter(.idle) }
        }
    }

    // MARK: - 表单（自己是一个模态，不自己关闭）

    @ViewBuilder
    private var formScreen: some View {
        if let captured {
            ClothingEditView(
                capturedImage: captured,
                seed: $seed,
                onSaved: { continueBatch in
                    recordedCount += 1
                    enter(continueBatch ? .camera : .idle)
                },
                onCancel: {
                    enter(.idle)
                }
            )
        } else {
            Color.clear.onAppear { enter(.idle) }
        }
    }

    // MARK: - 相册

    private func handleLibraryPick(_ item: PhotosPickerItem) async {
        defer { libraryItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }
        captured = image
        enter(.cropping)
    }
}
