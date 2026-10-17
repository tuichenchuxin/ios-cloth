import SwiftUI
import SwiftData
import UIKit

/// 录入流程的调度器：**入口页 → 拍照/选图（含系统裁剪）→ 填表 →（批量）回到同一来源**。
///
/// 这是整个 App 最重要的一条路径（DESIGN.md §5.2）。
/// 衡量它好坏的唯一标准是：同一季的衣服连拍 20 件要多久。
///
/// 裁剪交给系统组件 `SystemImagePicker`（`allowsEditing = true`），
/// 不再自己实现裁切页 —— 见那个文件顶部的说明。
///
/// ## 两条必须守住的规则（改之前务必先读，每条都对应一个真实的 bug）
///
/// **1. 任何子视图都不许自己关闭自己。**
///    关闭一律由本视图改 `scene` 完成，子视图只回调。
///    之前让 sheet / picker 各自 `dismiss()`，导致呈现状态和真实状态对不上 ——
///    按钮点了没反应，只有手动下滑才关得掉，而数据其实早就保存了。
///
/// **2. 模态之间直接切换时，必须等前一个收干净。**
///    同一次状态更新里既关 sheet 又开 cover，SwiftUI 会把两者一起丢掉。
///    所以 `enter(_:)` 先卸载当前模态，等 400ms 动画走完，再进目标模态。
struct CaptureFlowView: View {
    /// 流程结束
    let onFinish: () -> Void

    private enum Scene: Equatable {
        case idle
        case camera
        case photoLibrary
        case form

        /// 是否是一个「全屏/半屏模态」
        var isModal: Bool {
            switch self {
            case .camera, .photoLibrary, .form: true
            case .idle: false
            }
        }
    }

    /// 这一轮从哪来，决定「保存并继续」回哪里
    private enum Source {
        case camera
        case photoLibrary
    }

    @State private var scene: Scene = .idle
    @State private var captured: UIImage?
    /// 本批次已录入件数
    @State private var recordedCount = 0
    /// 下一件要继承的字段
    @State private var seed = ClothingEditView.Draft()
    /// 这一轮的来源
    @State private var source: Source = .camera
    @State private var cameraUnavailableAlert = false

    var body: some View {
        Group {
            switch scene {
            case .idle:
                entryScreen
            case .camera:
                cameraPickerScreen
            case .photoLibrary:
                libraryPickerScreen
            case .form:
                formScreen
            }
        }
        .alert("这台设备没有可用的相机", isPresented: $cameraUnavailableAlert) {
            Button("好", role: .cancel) {}
        } message: {
            Text("模拟器没有相机，请用「从相册选」。")
        }
    }

    // MARK: - 场景切换

    /// 卸载当前模态，必要时等它收干净，再进入目标场景。
    ///
    /// 只有「模态 → 模态」需要等：同一次更新里既关一个又开一个，
    /// SwiftUI 会把两者一起丢掉（表现为点击没反应或流程直接退出）。
    ///
    /// 这里**故意没有**「已经在切换中就忽略」的守卫 —— 那种守卫一旦命中就永久卡死。
    /// 重复调用是无害的，就是重新设一次目标场景。
    private func enter(_ target: Scene) {
        let needsWait = scene.isModal && target.isModal
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

    /// 结束整个录入流程：先让当前模态收干净，再关外层
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
                    Text("拍完后可以用系统裁剪把衣服抠成正方形，圈身和温度会自动沿用上一件。")
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

                    if !SystemImagePicker.isCameraAvailable {
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

    private func startCamera() {
        guard SystemImagePicker.isCameraAvailable else {
            cameraUnavailableAlert = true
            return
        }
        source = .camera
        captured = nil
        scene = .camera
    }

    private func startLibrary() {
        source = .photoLibrary
        captured = nil
        scene = .photoLibrary
    }

    // MARK: - 系统拍照 / 选图（内部自带裁剪）

    private var cameraPickerScreen: some View {
        SystemImagePicker(
            source: .camera,
            onPicked: handlePicked,
            onCancel: { enter(.idle) }
        )
        .ignoresSafeArea()
    }

    private var libraryPickerScreen: some View {
        SystemImagePicker(
            source: .photoLibrary,
            onPicked: handlePicked,
            onCancel: { enter(.idle) }
        )
    }

    /// 系统裁剪已经完成，直接进表单
    private func handlePicked(_ image: UIImage) {
        guard scene.isModal else { return }
        captured = image
        // 从「picker 模态」切到「表单模态」，需要等前者收干净
        enter(.form)
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
                        case .photoLibrary: startLibrary()
                        }
                    } else {
                        finishFlow()
                    }
                },
                onCancel: { enter(.idle) }
            )
        } else {
            Color.clear.onAppear { enter(.idle) }
        }
    }
}
