import XCTest

/// 临时：截「放大后往下拖到底」的图，用像素判断上边缘是否可达。
final class DebugEdgeTests: XCTestCase {
    func testCaptureDraggedToTop() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-reset-data", "-keep-saved-photos", "YES"]
        app.launch()

        app.tabBars.buttons["衣柜"].firstMatch.tap()
        app.buttons["添加"].firstMatch.tap()
        app.buttons["拍照 / 从相册录入"].firstMatch.tap()
        app.buttons["从相册选"].firstMatch.tap()

        let close = app.buttons["Close"].firstMatch
        if close.waitForExistence(timeout: 8) { close.tap() }
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(photo.waitForExistence(timeout: 30))
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()

        XCTAssertTrue(app.buttons["完成"].firstMatch.waitForExistence(timeout: 20))
        sleep(3)

        let canvas = app.images.firstMatch
        canvas.pinch(withScale: 5.0, velocity: 1.0)
        sleep(2)

        // 使劲往下拖，想把图片上边缘拉进框
        for _ in 0..<8 {
            canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
                .press(forDuration: 0.05, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.98)))
        }
        sleep(3)

        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "dragged-top-max"
        shot.lifetime = .keepAlways
        add(shot)
    }
}
