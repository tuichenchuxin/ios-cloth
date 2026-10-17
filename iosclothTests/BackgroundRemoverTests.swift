import XCTest
import UIKit
@testable import ioscloth

/// 自动去背景不能崩、不能返回坏图。
///
/// 抠图质量没法在单测里断言（依赖画面内容），但下面这些必须成立：
/// - 无论识别成功与否，都不能崩
/// - 成功时保持原图画布尺寸（`croppedToInstancesExtent: false`）
/// - 失败时返回 nil，让调用方保留原图
final class BackgroundRemoverTests: XCTestCase {

    func testBlankImageDoesNotCrash() async {
        let image = Self.makeImage(size: CGSize(width: 400, height: 400)) { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 400))
        }

        let result = await BackgroundRemover.subjectOnWhite(image)
        if let result {
            XCTAssertEqual(result.size.width, 400, accuracy: 2, "成功时应保持画布尺寸")
            XCTAssertEqual(result.size.height, 400, accuracy: 2)
        }
        // nil 也是合法结果：纯色图没有主体，调用方会用原图
    }

    func testImageWithSubjectEitherFailsGracefullyOrKeepsCanvas() async {
        // 白底上一个深色圆，模拟「一件衣服」的粗轮廓
        let image = Self.makeImage(size: CGSize(width: 600, height: 800)) { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 600, height: 800))
            UIColor.darkGray.setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 150, y: 200, width: 300, height: 400))
        }

        let result = await BackgroundRemover.subjectOnWhite(image)
        if let result {
            XCTAssertEqual(result.size.width, 600, accuracy: 2)
            XCTAssertEqual(result.size.height, 800, accuracy: 2)
            XCTAssertEqual(result.imageOrientation, .up)
        }
    }

    func testPhotoSizedImageIsHandled() async {
        let image = Self.makeImage(size: CGSize(width: 1200, height: 1600)) { context in
            UIColor.lightGray.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1600))
        }
        // 只是确认大图不会卡死/崩
        _ = await BackgroundRemover.subjectOnWhite(image)
    }

    private static func makeImage(size: CGSize, draw: (UIGraphicsImageRendererContext) -> Void) -> UIImage {
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image(actions: draw)
    }
}
