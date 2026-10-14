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
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("无法创建 ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(sharedModelContainer)
    }
}
