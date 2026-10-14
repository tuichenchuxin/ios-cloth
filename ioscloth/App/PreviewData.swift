import Foundation
import SwiftData

/// SwiftUI 预览用的内存数据库（Xcode 预览不该碰真实数据）
enum PreviewData {
    @MainActor
    static let container: ModelContainer = {
        let schema = Schema([Clothing.self, Outfit.self, OutfitItem.self, WearRecord.self])
        let configuration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        let container = try! ModelContainer(for: schema, configurations: [configuration])
        seed(container.mainContext)
        return container
    }()

    @MainActor
    static func seed(_ context: ModelContext) {
        let samples: [(String, ClothingCategory, String, [Season], Double, Double, [StyleTag], Bool)] = [
            ("黑色羊毛大衣", .outerwear, "大衣", [.winter], -5, 10, [.commute, .formal], false),
            ("米色高领毛衣", .top, "毛衣", [.winter, .autumn], 0, 14, [.commute], true),
            ("牛仔直筒裤", .bottom, "牛仔裤", [.spring, .autumn, .winter], 5, 22, [.casual], false),
            ("白色衬衫", .top, "衬衫", [.spring, .summer, .autumn], 15, 28, [.commute, .formal], true),
            ("灰色阔腿裤", .bottom, "阔腿裤", [.spring, .summer, .autumn], 16, 30, [.commute], false),
            ("藏青风衣", .outerwear, "风衣", [.spring, .autumn], 8, 20, [.commute, .casual], false),
            ("白色运动鞋", .shoes, "球鞋", [.spring, .summer, .autumn], 10, 32, [.casual, .sporty], true),
            ("黑色短靴", .shoes, "靴子", [.autumn, .winter], -5, 15, [.casual, .commute], false),
            ("碎花连衣裙", .dress, "连衣裙", [.summer], 22, 34, [.date, .casual], false),
        ]

        for sample in samples {
            let item = Clothing(
                name: sample.0,
                category: sample.1,
                subcategory: sample.2,
                seasons: sample.3,
                tempMin: sample.4,
                tempMax: sample.5,
                isLayerable: sample.7,
                styleTags: sample.6
            )
            context.insert(item)
        }

        try? context.save()
    }
}
