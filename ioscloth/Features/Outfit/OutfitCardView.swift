import SwiftUI

/// 一张搭配卡：成员缩略图 + 为什么推荐 + 操作按钮。
///
/// 「为什么推荐」是信任感的来源，不是装饰（DESIGN.md §4.4）。
struct OutfitCardView: View {
    let draft: OutfitDraft<Clothing>
    var onSave: () -> Void
    var onRegenerate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(draft.orderedAssignments, id: \.slot) { entry in
                        VStack(spacing: 4) {
                            TappablePhoto(
                                mainName: entry.item.imageFile,
                                thumbName: entry.item.thumbFile,
                                title: entry.item.displayName,
                                size: 100,
                                cornerRadius: 10
                            )

                            Text(entry.slot.displayName)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            Text(entry.item.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: 100)
                        }
                    }
                }
                .padding(.horizontal, 2)
            }

            VStack(alignment: .leading, spacing: 3) {
                ForEach(draft.orderedAssignments, id: \.slot) { entry in
                    Text("· \(entry.item.displayName)　\(OutfitEngine.buildReason(item: entry.item, request: request))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 10) {
                Button {
                    onRegenerate()
                } label: {
                    Label("换一套", systemImage: "shuffle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                Button {
                    onSave()
                } label: {
                    Label("就这套", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var request: OutfitRequest {
        OutfitRequest(temperature: draft.temperature, season: draft.season)
    }
}
