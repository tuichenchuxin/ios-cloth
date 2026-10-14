import Foundation
import SwiftData

/// 衣物的写操作。
///
/// 存在的理由：删除一件衣物时，**必须**手动把引用它的搭配槽位置空。
/// SwiftData 在这里不会自动帮你做（`@Relationship` 的 deleteRule 在
/// 删除衣物这条边上不可靠），不处理就会让搭配卡指向一个已经删掉的对象。
@MainActor
enum ClothingService {

    /// 删除衣物，并清掉所有引用它的搭配槽位。
    ///
    /// - 搭配**不删**：它记录的是「当时的选择」，比衣物本身更值得留。
    ///   但如果一套搭配因此变成空壳，顺手删掉它，免得「我的搭配」里堆一排空的。
    /// - 图片文件交给调用方删除（`ImageStore` 是 actor，需要 await）。
    static func delete(_ item: Clothing, in context: ModelContext) throws {
        let itemID = item.id
        try clearReferences(to: itemID, in: context)

        context.delete(item)
        try context.save()
        try removeEmptyOutfits(in: context)
    }

    /// 批量删除（长按多选时用）
    static func delete(_ items: [Clothing], in context: ModelContext) throws {
        for item in items {
            try clearReferences(to: item.id, in: context)
            context.delete(item)
        }
        try context.save()
        try removeEmptyOutfits(in: context)
    }

    /// 把引用某件衣物的搭配槽位置空
    private static func clearReferences(to clothingID: UUID, in context: ModelContext) throws {
        let outfitItems = try context.fetch(FetchDescriptor<OutfitItem>())
        for outfitItem in outfitItems where outfitItem.clothing?.id == clothingID {
            outfitItem.clothing = nil
        }
    }

    /// 清掉变成空壳的搭配
    private static func removeEmptyOutfits(in context: ModelContext) throws {
        let outfits = try context.fetch(FetchDescriptor<Outfit>())
        for outfit in outfits where outfit.items.allSatisfy({ $0.clothing == nil }) {
            context.delete(outfit)
        }
        try context.save()
    }
}
