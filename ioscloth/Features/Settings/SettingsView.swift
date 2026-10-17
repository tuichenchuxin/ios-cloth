import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var context
    @Query private var items: [Clothing]

    @State private var backupURL: URL?
    @State private var statusMessage: String?
    @State private var showDeleteConfirm = false
    @State private var isImporting = false
    /// 拍照/选图后是否自动去背景，默认开启
    @AppStorage(AppSettings.autoRemoveBackgroundKey) private var autoRemoveBackground = true

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("衣物", value: "\(items.count) 件")
                    LabeledContent("搭配", value: "\(outfitCount) 套")
                } header: {
                    Text("数据")
                } footer: {
                    Text("所有数据都在这台手机上，没有账号、没有后端、不会上传。")
                }

                Section {
                    Button {
                        do {
                            backupURL = try BackupService.exportToFile(context: context)
                            statusMessage = "已导出备份"
                        } catch {
                            statusMessage = "导出失败：\(error.localizedDescription)"
                        }
                    } label: {
                        Label("导出 JSON 备份", systemImage: "square.and.arrow.up")
                    }

                    if let backupURL {
                        ShareLink(item: backupURL) {
                            Label("分享备份文件（隔空投送 / 存到文件）", systemImage: "paperplane")
                        }
                    }

                    Button {
                        isImporting = true
                    } label: {
                        Label("从备份导入", systemImage: "square.and.arrow.down")
                    }
                } header: {
                    Text("备份")
                } footer: {
                    Text("图片不进 JSON（体积太大），但会在 iTunes / Finder 备份里一起保留。导入按 id 去重合并，不会覆盖已有数据。")
                }

                Section {
                    Toggle(isOn: $autoRemoveBackground) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("拍照后自动去背景")
                            Text("用系统的主体识别把衣服抠出来放到白底上；识别不出来就保留原图。全部在本机处理，不联网。")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityIdentifier("auto-remove-background")
                } header: {
                    Text("录入")
                }

                Section {
                    NavigationLink {
                        DataHealthView()
                    } label: {
                        Label("数据体检", systemImage: "stethoscope")
                    }

                    Button(role: .destructive) {
                        showDeleteConfirm = true
                    } label: {
                        Label("清空全部数据", systemImage: "trash")
                    }
                } header: {
                    Text("维护")
                }

                Section("关于") {
                    LabeledContent("版本", value: appVersion)
                    LabeledContent("最低系统", value: "iOS 18.0")
                    LabeledContent("Bundle ID", value: "com.chuxinchen.ioscloth")
                }
            }
            .navigationTitle("设置")
            .fileImporter(
                isPresented: $isImporting,
                allowedContentTypes: [.json]
            ) { result in
                handleImport(result)
            }
            .alert("清空全部数据？", isPresented: $showDeleteConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    do {
                        try BackupService.deleteEverything(in: context)
                        statusMessage = "已清空"
                    } catch {
                        statusMessage = "清空失败：\(error.localizedDescription)"
                    }
                }
            } message: {
                Text("衣物、搭配、穿着记录都会删除，且**无法撤销**。建议先导出备份。")
            }
            .alert("提示", isPresented: Binding(
                get: { statusMessage != nil },
                set: { if !$0 { statusMessage = nil } }
            )) {
                Button("好", role: .cancel) { statusMessage = nil }
            } message: {
                Text(statusMessage ?? "")
            }
        }
    }

    @Query private var outfits: [Outfit]

    private var outfitCount: Int { outfits.count }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(version) (\(build))"
    }

    private func handleImport(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url):
            do {
                // fileImporter 给的 URL 在沙盒外，必须先申请访问权限
                let needsScope = url.startAccessingSecurityScopedResource()
                defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

                let snapshot = try BackupService.decode(from: url)
                let outcome = try BackupService.merge(snapshot, into: context)
                statusMessage = "导入完成：新增 \(outcome.added) 条，跳过已存在 \(outcome.skipped) 条"
            } catch {
                statusMessage = "导入失败：\(error.localizedDescription)"
            }
        case .failure(let error):
            statusMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }
}
