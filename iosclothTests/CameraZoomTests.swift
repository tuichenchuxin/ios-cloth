import XCTest
@testable import ioscloth

/// 变焦夹取逻辑。
///
/// 这条守住一个真实 bug：以前下限写死 1，导致「只能放大、不能缩小」。
/// 有超广角时下限应该是 0.5。
final class CameraZoomTests: XCTestCase {

    func testCanZoomOutToUltraWideWhenAvailable() {
        let result = CameraController.clampedZoom(0.5, min: 0.5, max: 6)
        XCTAssertEqual(result, 0.5, accuracy: 0.0001, "有超广角时应该能缩到 0.5×")
    }

    func testCannotGoBelowDeviceMinimum() {
        let result = CameraController.clampedZoom(0.1, min: 0.5, max: 6)
        XCTAssertEqual(result, 0.5, accuracy: 0.0001)
    }

    func testCannotGoAboveMaximum() {
        let result = CameraController.clampedZoom(20, min: 0.5, max: 6)
        XCTAssertEqual(result, 6, accuracy: 0.0001)
    }

    func testDevicesWithoutUltraWideStopAtOne() {
        let result = CameraController.clampedZoom(0.5, min: 1, max: 6)
        XCTAssertEqual(result, 1, accuracy: 0.0001, "没有超广角时最小就是 1×")
    }

    func testPassthroughForNormalValues() {
        XCTAssertEqual(CameraController.clampedZoom(2.3, min: 0.5, max: 6), 2.3, accuracy: 0.0001)
        XCTAssertEqual(CameraController.clampedZoom(1, min: 0.5, max: 6), 1, accuracy: 0.0001)
    }

    func testNaNOrInfiniteFallsBackToOne() {
        XCTAssertEqual(CameraController.clampedZoom(.nan, min: 0.5, max: 6), 1, accuracy: 0.0001)
        XCTAssertEqual(CameraController.clampedZoom(.infinity, min: 0.5, max: 6), 1, accuracy: 0.0001)
    }
}
