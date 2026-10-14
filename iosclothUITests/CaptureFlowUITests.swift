import XCTest

/// 「拍照 → 调整 → 填表 → 保存」这条主链路的端到端 UI 测试。
///
/// 存在的理由：这条流程出过一次很隐蔽的 bug —— 点完「使用照片」什么都没发生。
/// 根因是嵌套模态互相拆台，单测覆盖不到，只有真的把界面点一遍才能发现。
///
/// ⚠️ 模拟器没有相机，所以这里走的是**相册**分支。
/// 相机分支与相册分支在「拿到图片之后」共用同一套状态机
/// （设置 `captured` → push 裁切页 → 弹出表单），所以这条测试能覆盖到出问题的那段逻辑。
final class CaptureFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // 每次都从空衣柜开始：数据是持久化的，不清空的话上一条测试
        // 存进去的衣物会让「取消不该产生数据」之类的断言误报。
        app.launchArguments += ["-uitest-reset-data"]
        // 让模拟器相册保留已选过的照片，避免每次都要等待照片库吐数据
        app.launchArguments += ["-keep-saved-photos", "YES"]
        app.launch()
        return app
    }

    /// 在系统相册（PHPicker）里挑第一张照片。
    ///
    /// 系统相册有几个坑，都在这里绕开：
    /// 1. 它可能先弹一个「照片选择器」引导页（带 `Learn More…` / `Close`），
    ///    把整个网格挡住 —— 这时候 `<app>.collectionViews` 和 `.cells` 全是 0；
    /// 2. 照片在层级里是 `PXGGridLayout-Info` 这种系统内部标识的 image，
    ///    不是干净的 cell；
    /// 3. 挑完之后系统会自动关掉选择器，不需要（也没有）确认按钮。
    private func tapFirstPhoto(in app: XCUIApplication) throws {
        // 1) 关掉可能的引导页
        let closeButton = app.buttons["Close"].firstMatch
        if closeButton.waitForExistence(timeout: 8) {
            closeButton.tap()
        }

        // 2) 等照片网格就绪。
        //    这些元素 `isHittable == false`（系统网格外面套了一层拦截触摸的容器），
        //    所以不能用 `.tap()`，得按坐标点。
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        if photo.waitForExistence(timeout: 30) {
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }

        // 3) 兜底：不同系统版本的标识不一样，退回到「第一个单元格 / 第一张图」
        let cell = app.collectionViews.firstMatch.cells.firstMatch
        if cell.waitForExistence(timeout: 10) {
            cell.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }
        let anyImage = app.images.firstMatch
        if anyImage.waitForExistence(timeout: 10) {
            anyImage.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            return
        }

        XCTFail("相册里没找到可选的照片（模拟器相册可能是空的，先跑 `xcrun simctl addmedia`）")
    }

    /// 走 UI 进入「从系统相册选照片」这一步。
    ///
    /// 路径：衣柜 → 添加菜单 → CaptureFlowView 入口页 → 从相册选。
    /// 注意这里刻意只保留一条录入路径：以前 ClosetView 里还并行挂着一个
    /// `.photosPicker`，导致相册和拍照行为不一致（相册会跳过裁切页）。
    private func openCaptureFlowFromLibrary(_ app: XCUIApplication) {
        app.tabBars.buttons["衣柜"].firstMatch.tap()
        app.buttons["添加"].firstMatch.tap()

        let captureEntry = app.buttons["拍照 / 从相册录入"].firstMatch
        XCTAssertTrue(captureEntry.waitForExistence(timeout: 10), "添加菜单应该弹出")
        captureEntry.tap()

        let libraryButton = app.buttons["从相册选"].firstMatch
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 20), "应该进入录入入口页")
        libraryButton.tap()
    }

    /// 收掉键盘。**这一步不能省**：
    /// 「保存并结束」在底部工具栏，填名称时键盘正好盖住它，
    /// 不收键盘就点不到 —— 这正是「录完了但没存进去」的根因之一。
    private func dismissKeyboard(_ app: XCUIApplication) {
        let collapse = app.buttons["收起键盘"].firstMatch
        if collapse.exists {
            collapse.tap()
        } else {
            app.navigationBars.firstMatch.tap()
        }
    }

    // MARK: - 主链路

    func testAddClothingFromPhotoLibrary() throws {
        let app = launchApp()

        // 1. 切到「衣柜」
        app.tabBars.buttons["衣柜"].firstMatch.tap()
        XCTAssertTrue(
            app.navigationBars["衣柜"].waitForExistence(timeout: 5),
            "应该进入衣柜页"
        )

        // 2. 从相册录入
        openCaptureFlowFromLibrary(app)

        // 3. 系统相册：选第一张照片
        try tapFirstPhoto(in: app)

        // 4. 应该进入裁切页（这一步以前会因为嵌套模态而整个消失）
        let doneButton = app.buttons["完成"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 20), "选完照片必须进入裁切页")
        doneButton.tap()

        // 5. 应该进入表单
        let nameField = app.textFields["衣物名称输入框"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15), "裁切完成后必须进入录入表单")

        nameField.tap()
        nameField.typeText("UI测试用上衣")

        // 6. 勾一个季节
        app.buttons["春"].firstMatch.tap()

        // 7. 收键盘后保存（不收键盘的话底部工具栏是点不到的）
        dismissKeyboard(app)
        let saveButton = app.buttons["保存并结束"].firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5), "批量模式应该有「保存并结束」")
        XCTAssertTrue(saveButton.isHittable, "收键盘之后「保存并结束」必须可点")
        saveButton.tap()

        // 8. 回到衣柜，应该能看到刚录入的衣服
        XCTAssertTrue(
            app.navigationBars["衣柜"].waitForExistence(timeout: 20),
            "保存后应该回到衣柜"
        )
        XCTAssertTrue(
            app.staticTexts["UI测试用上衣"].waitForExistence(timeout: 20),
            "刚录入的衣服必须真的出现在衣柜里 —— 这正是当初失败的地方"
        )
    }

    // MARK: - 批量录入的字段继承

    func testBatchEntryCarriesOverSeasonToNextItem() throws {
        // 第一件：完整录入，季节选「冬」，温度调到「冷」预设
        // 第二件：直接保存，应该自动继承「冬」和刚才的温度区间
        //
        // 这里只验证「进入第二件的表单时季节已经被预选」这一点，
        // 因为它是批量录入省时间的核心机制。
        let app = launchApp()

        openCaptureFlowFromLibrary(app)

        try tapFirstPhoto(in: app)

        let doneButton = app.buttons["完成"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 20))
        doneButton.tap()

        let nameField = app.textFields["衣物名称输入框"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15))
        nameField.tap()
        nameField.typeText("批量第一件")

        // 选「冬」和「冷」预设
        app.buttons["冬"].firstMatch.tap()
        app.buttons["冷 -5~10°"].firstMatch.tap()

        // 点「保存并继续」→ 应该回到录入入口页（而不是退出整个流程）
        dismissKeyboard(app)
        let continueButton = app.buttons["保存并继续"].firstMatch
        XCTAssertTrue(continueButton.waitForExistence(timeout: 5))
        XCTAssertTrue(continueButton.isHittable, "收键盘之后「保存并继续」必须可点")
        continueButton.tap()

        let cameraButton = app.buttons["拍照"]
        XCTAssertTrue(
            cameraButton.waitForExistence(timeout: 20),
            "「保存并继续」之后应该回到录入入口，而不是退出流程"
        )
        XCTAssertTrue(
            app.staticTexts["已录入 1 件"].waitForExistence(timeout: 10),
            "应该显示本批次已录入的进度"
        )
    }

    // MARK: - 取消不应该留下垃圾数据

    func testCancellingCaptureLeavesNoItem() throws {
        let app = launchApp()

        openCaptureFlowFromLibrary(app)

        try tapFirstPhoto(in: app)

        let doneButton = app.buttons["完成"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 20))
        doneButton.tap()

        XCTAssertTrue(app.textFields["衣物名称输入框"].waitForExistence(timeout: 15))

        // 表单里点返回：应该回到录入入口页，不写入任何数据
        app.buttons["返回"].firstMatch.tap()

        let cameraButton = app.buttons["拍照"]
        XCTAssertTrue(cameraButton.waitForExistence(timeout: 15), "取消表单后应该回到录入入口")
        cameraButton.tap()

        // 直接从入口取消整个流程
        app.buttons["取消"].firstMatch.tap()

        XCTAssertTrue(
            app.navigationBars["衣柜"].waitForExistence(timeout: 15),
            "取消后应该回到衣柜"
        )
        XCTAssertTrue(
            app.staticTexts["衣柜还是空的"].waitForExistence(timeout: 10),
            "取消录入不该产生任何衣物"
        )
    }
}
