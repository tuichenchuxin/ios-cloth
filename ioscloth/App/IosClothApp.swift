import SwiftUI
import SwiftData

@main
struct IosClothApp: App {
    /// 唯一的事实来源：SwiftData 容器。
    /// 注意：这里不额外 `Schema([...])` —— 让 SwiftData 从 models 自动推导 schema，
    /// 否则每个 @Model 类型要写两遍，容易写漏导致「实体找不到」。
    let sharedModelContainer: ModelContainer = {
        let schema = Schema([Clothing.self, Outfit.self, OutfitItem.self, WearRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            let container = try ModelContainer(for: schema, configurations: [configuration])
            resetIfRequested(container)
            return container
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }()

    /// UI 测试要求每次从干净状态开始。
    ///
    /// 数据是持久化的，上一条 UI 测试存进去的衣物会污染下一条
    /// （例如「取消录入不该产生任何衣物」会看到上次留下的数据）。
    /// 这里只在测试显式传参时才清空，正常使用永远不会触发。
    @MainActor
    private static func resetIfRequested(_ container: ModelContainer) {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("-uitest-reset-data") else { return }
        try? BackupService.deleteEverything(in: container.mainContext)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(sharedModelContainer)
    }
}
