import SwiftUI
import SwiftData
import UIKit
import PhotosUI

/// 录入流程的调度器：**入口页 → 拍照/相册 → 裁切 → 表单 →（批量）回到上一个来源**。
///
/// 这是整个 App 最重要的一条路径（DESIGN.md §5.2）。
/// 衡量它好坏的唯一标准是：同一季的衣服连拍 20 件要多久。
/// 所以每一步都把「不用做决定」当作设计目标：
/// - 相机 / 相册两个大按钮，不用先理解别的概念
/// - 裁切框打开就居中填满，直接点「完成」就行
/// - 表单的季节/温度/场景继承上一件，只需按「保存并继续」
/// - 「保存并继续」回到**你刚才用的那个来源**（拍照来的回相机，相册来的回相册）
///
/// ## 三条必须守住的规则（改之前务必先读，每条都对应一个线上 bug）
///
/// **1. 任何子视图都不许自己关闭自己。**
///    关闭一律由本视图改 `scene` 完成，子视图只回调。
///    之前 `ClothingEditView` 和 `CameraPicker` 各自调 `dismiss()`，结果
///    sheet 的绑定和真实状态对不上 —— 按钮点了没反应，只有手动下滑才关得掉。
///
/// **2. 只有在「模态 → 模态」时才需要等关闭动画；其余切换要同步完成。**
///    在同一次状态更新里既关 sheet 又开 cover，SwiftUI 会把两者一起丢掉
///    （表现为「点了使用照片什么都没发生」）。但**绝不能**给所有切换都加延时，
///    否则会出现「延时的二次状态变更把刚建好的页面拆掉」——
///    裁切页刚弹出就消失就是这么来的。
///
/// **3. 状态切换不能有「被丢弃就永久卡死」的守卫。**
///    之前 `enter()` 里的 `guard nextScene == nil else { return }` 一旦命中一次，
///    后面所有点击都静默失效。
struct CaptureFlowView: View {
    /// 流程结束
    let onFinish: () -> Void

    /// 当前场景。用**单选**状态机表达，避免多个布尔量互相矛盾。
    private enum Scene: Equatable {
        case idle
        case camera
        case cropping
        case form
    }

    /// 连续录入时，「保存并继续」要回到哪个来源
    private enum CaptureSource {
        case camera
        case library
    }

    @State private var scene: Scene = .idle
    @State private var captured: UIImage?
    /// 本批次已录入件数
    @State private var recordedCount = 0
    /// 下一件要继承的字段
    @State private var seed = ClothingEditView.Draft()
    /// 这一轮是从哪来的，决定「保存并继续」回哪里
    @State private var source: CaptureSource = .camera

    @State private var isPickingFromLibrary = false
    @State private var libraryItem: PhotosPickerItem?
    @State private var cameraUnavailableAlert = false

    var body: some View {
        Group {
            switch scene {
            case .idle:
                entryScreen
            case .camera:
                cameraScreen
            case .cropping:
                croppingScreen
            case .form:
                formScreen
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

    /// 关闭当前模态，必要时等它收干净，再打开目标场景。
    ///
    /// 只有 `.cropping → .form`（两个都是模态）需要等：同一次更新里关一个开一个，
    /// SwiftUI 会把两者一起丢掉。
    ///
    /// 这里**故意没有**「已经在切换中就忽略」的守卫 —— 那种守卫一旦命中就永久卡死。
    /// 重复调用是无害的：就是重新设一次目标场景。
    private func enter(_ target: Scene) {
        let needsWait = (scene == .cropping && target == .form)
        scene = .idle
        if target != .form { captured = nil }

        guard needsWait else {
            scene = target
            return
        }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            scene = target
        }
    }

    /// 结束整个录入流程。
    ///
    /// **必须等当前模态收干净**，不能直接 `onFinish()`：外层还有一个
    /// `fullScreenCover`，同时关「内层 sheet」和「外层 cover」会让 SwiftUI
    /// 把两者一起丢掉（表现为流程没退出去、或者界面错乱）。
    /// 这和 `enter(_:)` 里那个 400ms 是同一个道理。
    private func finishFlow() {
        scene = .idle
        captured = nil
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(400))
            onFinish()
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
                        startCamera()
                    } label: {
                        Label("拍照", systemImage: "camera.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button {
                        startLibrary()
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

    // MARK: - 入口动作

    private func startCamera() {
        guard CameraPicker.isAvailable else {
            cameraUnavailableAlert = true
            return
        }
        source = .camera
        captured = nil
        scene = .camera
    }

    private func startLibrary() {
        source = .library
        captured = nil
        scene = .idle
        isPickingFromLibrary = true
    }

    // MARK: - 相机（自己是一个全屏模态，不自己关闭）

    private var cameraScreen: some View {
        CameraPicker(
            onCapture: { image in
                // 同一个回调可能因为系统行为被触发两次，第二次会带着已经变过的
                // scene 进来。加个守卫避免把裁切页刚建好又拆掉。
                guard scene == .camera else { return }
                captured = image
                scene = .cropping
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
                    if continueBatch {
                        // 回到刚才用的那个来源，而不是一律回相机
                        switch source {
                        case .camera: startCamera()
                        case .library: startLibrary()
                        }
                    } else {
                        // 「保存并结束」= 退出整个录入流程（不是回到入口页）
                        finishFlow()
                    }
                },
                onCancel: { enter(.idle) }
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
        guard scene == .idle else { return }
        captured = image
        scene = .cropping
    }
}
