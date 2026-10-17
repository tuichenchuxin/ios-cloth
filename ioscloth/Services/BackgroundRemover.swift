import CoreImage
import UIKit
import Vision

/// 自动去背景：用 Vision 的主体分割把衣服抠出来，放到白底上。
///
/// 用的是 iOS 17 起可用的 `VNGenerateForegroundInstanceMaskRequest` ——
/// **完全本地运行、不联网、免费**，不需要任何第三方服务。
///
/// 为什么放在白底上而不是保留透明：衣柜和搭配里都是方形卡片，
/// 透明 PNG 在卡片上看不出好坏，白底更像商品图、也更统一。
///
/// 抠失败（比如画面里没有明显主体、或者多件衣服挤在一起）就返回 nil，
/// 调用方保留原图 —— 宁可不去背景，也不要给一张坏图。
enum BackgroundRemover {

    /// 去背景并合成到白底。失败返回 nil。
    static func subjectOnWhite(_ image: UIImage) async -> UIImage? {
        guard #available(iOS 17.0, *) else { return nil }

        let upright = image.upright()
        guard let cgImage = upright.cgImage else { return nil }
        let scale = upright.scale

        return await withCheckedContinuation { continuation in
            // Vision 是同步的 CPU 活，放后台线程，别卡住相机/表单
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: mask(cgImage: cgImage, scale: scale))
            }
        }
    }

    @available(iOS 17.0, *)
    private static func mask(cgImage: CGImage, scale: CGFloat) -> UIImage? {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              !observation.allInstances.isEmpty else {
            return nil
        }

        do {
            let maskedPixelBuffer = try observation.generateMaskedImage(
                ofInstances: observation.allInstances,
                from: handler,
                croppedToInstancesExtent: false
            )
            return compositeOnWhite(maskedPixelBuffer, scale: scale)
        } catch {
            return nil
        }
    }

    /// 把带 alpha 的主体图叠到白底上
    static func compositeOnWhite(_ buffer: CVPixelBuffer, scale: CGFloat) -> UIImage? {
        let subject = CIImage(cvPixelBuffer: buffer)
        let extent = subject.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let white = CIImage(color: .white).cropped(to: extent)
        let composed = subject.composited(over: white)

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let output = context.createCGImage(composed, from: extent) else { return nil }
        return UIImage(cgImage: output, scale: scale, orientation: .up)
    }
}
