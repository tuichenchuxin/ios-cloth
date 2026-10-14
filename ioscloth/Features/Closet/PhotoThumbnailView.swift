import SwiftUI
import SwiftData
import UIKit

/// 显示一件衣物的缩略图。图片在沙盒文件里，所以要异步读。
struct PhotoThumbnailView: View {
    let thumbName: String
    let mainName: String
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                placeholder
            }
        }
        .task(id: thumbName + mainName) {
            // 名字为空就别去敲磁盘
            guard !thumbName.isEmpty || !mainName.isEmpty else {
                image = nil
                return
            }
            image = await ImageStore.shared.loadThumbnail(preferring: thumbName, fallback: mainName)
        }
    }

    private var placeholder: some View {
        ZStack {
            Color(.secondarySystemBackground)
            Image(systemName: "tshirt")
                .font(.title3)
                .foregroundStyle(.tertiary)
        }
    }
}
