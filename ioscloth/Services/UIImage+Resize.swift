import UIKit

extension UIImage {
    /// 等比缩放，长边不超过 `maxDimension`。
    ///
    /// 用 `UIGraphicsImageRenderer` 重绘一遍是**故意的**：它同时把 EXIF 方向拍平，
    /// 否则从相册取的原图在缩略图里会躺倒。
    func resized(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension, longestSide > 0 else { return self }

        let scale = maxDimension / longestSide
        let target = CGSize(width: (size.width * scale).rounded(), height: (size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = true

        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            draw(in: CGRect(origin: .zero, size: target))
        }
    }

    func jpegData(quality: CGFloat) -> Data? {
        jpegData(compressionQuality: quality)
    }
}
