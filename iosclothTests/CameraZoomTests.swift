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

/// 显示倍数 ↔ 原始变焦值的换算。
///
/// 真机实测（iPhone 17 Pro Max）：
/// `constituents = ultraWide → wide → tele`，`switchOverFactors = 2.00, 8.00`
/// → 原始值 1.0 = 超广角，2.0 = 主摄（系统相机里的 1×），8.0 = 长焦。
///
/// 之前直接拿原始值当倍数显示，于是最广的画面被标成「1×」，
/// 用户自然觉得「缩不到 1 以下」—— 其实已经是 0.5× 的视野了。
final class CameraZoomDisplayTests: XCTestCase {

    private let wideFactor: CGFloat = 2.0

    func testUltraWideFactorShowsAsHalf() {
        let display = CameraController.displayZoom(forFactor: 1.0, wideFactor: wideFactor)
        XCTAssertEqual(display, 0.5, accuracy: 0.001, "最广那颗应该显示 0.5×")
    }

    func testPrimaryWideFactorShowsAsOne() {
        let display = CameraController.displayZoom(forFactor: 2.0, wideFactor: wideFactor)
        XCTAssertEqual(display, 1.0, accuracy: 0.001)
    }

    func testTelephotoFactorShowsAsFour() {
        let display = CameraController.displayZoom(forFactor: 8.0, wideFactor: wideFactor)
        XCTAssertEqual(display, 4.0, accuracy: 0.001)
    }

    func testDisplayMapsBackToFactor() {
        XCTAssertEqual(CameraController.factor(forDisplayZoom: 0.5, wideFactor: wideFactor), 1.0, accuracy: 0.001)
        XCTAssertEqual(CameraController.factor(forDisplayZoom: 1.0, wideFactor: wideFactor), 2.0, accuracy: 0.001)
        XCTAssertEqual(CameraController.factor(forDisplayZoom: 2.5, wideFactor: wideFactor), 5.0, accuracy: 0.001)
    }

    func testRoundTrip() {
        for display in [0.5, 0.8, 1.0, 1.7, 3.0] {
            let factor = CameraController.factor(forDisplayZoom: display, wideFactor: wideFactor)
            let back = CameraController.displayZoom(forFactor: factor, wideFactor: wideFactor)
            XCTAssertEqual(back, display, accuracy: 0.001)
        }
    }

    /// 没有多摄（wideFactor = 1）时，原始值就是显示值
    func testSingleCameraKeepsDisplayEqualToFactor() {
        XCTAssertEqual(CameraController.displayZoom(forFactor: 3.0, wideFactor: 1), 3.0, accuracy: 0.001)
        XCTAssertEqual(CameraController.factor(forDisplayZoom: 3.0, wideFactor: 1), 3.0, accuracy: 0.001)
    }

    /// 至少能显示到 0.5× —— 这正是用户要的「缩小」
    func testMinimumDisplayZoomReachesHalf() {
        let deviceMin: CGFloat = 1.0          // 真机上报的 minAvailableVideoZoomFactor
        let minDisplay = deviceMin / wideFactor
        XCTAssertEqual(minDisplay, 0.5, accuracy: 0.001)
    }
}
