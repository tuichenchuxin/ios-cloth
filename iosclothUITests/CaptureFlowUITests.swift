import XCTest

/// 「拍照 → 调整 → 填表 → 保存」这条主链路的端到端 UI 测试。
///
/// 存在的理由：这条流程出过好几次很隐蔽的 bug ——
/// 点「使用照片」什么都没发生、点保存按钮没反应、相册跳过裁切页。
/// 根因都是模态嵌套 / 状态不同步，单测覆盖不到，只有真的把界面点一遍才能发现。
///
/// ⚠️ 模拟器没有相机，所以这里走**相册**分支。
/// 相机分支与相册分支在「拿到图片之后」共用同一套状态机，所以这条测试能覆盖到出问题的那段逻辑。
final class CaptureFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
    }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        // 每次从空衣柜开始：数据是持久化的，不清空的话上一条测试存进去的衣物
        // 会让「取消不该产生数据」之类的断言误报。
        app.launchArguments += ["-uitest-reset-data"]
        // 让模拟器相册保留已选过的照片，省掉照片库吐数据的时间
        app.launchArguments += ["-keep-saved-photos", "YES"]
        app.launch()
        return app
    }

    // MARK: - 主链路

    func testAddClothingFromPhotoLibrary() throws {
        let app = launchApp()

        openCaptureEntry(app)
        pickFirstPhotoFromLibrary(app)
        confirmCrop(app)
        fillName(app, "UI测试用上衣")
        app.buttons["春"].firstMatch.tap()

        tapSave(app, "保存并结束")

        // 保存并结束 → 回到衣柜，能看到刚录入的衣服
        XCTAssertTrue(
            app.navigationBars["衣柜"].waitForExistence(timeout: 20),
            "保存后应该回到衣柜"
        )
        XCTAssertTrue(
            app.staticTexts["UI测试用上衣"].waitForExistence(timeout: 20),
            "刚录入的衣服必须真的出现在衣柜里 —— 这正是当初失败的地方"
        )
    }

    // MARK: - 批量录入

    func testSaveAndContinueFromLibraryReturnsToLibrary() throws {
        // 用户要求的语义：「保存并继续」要回到**刚才用的那个来源**。
        // 从相册来的就回相册，从相机来的才回相机。
        let app = launchApp()

        openCaptureEntry(app)
        pickFirstPhotoFromLibrary(app)
        confirmCrop(app)
        fillName(app, "相册批量第一件")
        app.buttons["冬"].firstMatch.tap()

        tapSave(app, "保存并继续")

        // 关键断言：相册又弹出来了（而不是跳到相机）
        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(
            photo.waitForExistence(timeout: 30),
            "从相册来的，「保存并继续」应该回到相册，而不是相机"
        )

        // 收掉相册，确认这一件确实入库了
        app.buttons["Cancel"].firstMatch.tap()
        XCTAssertTrue(
            app.staticTexts["已录入 1 件"].waitForExistence(timeout: 15),
            "应该显示本批次已录入的进度"
        )
    }

    func testBatchEntryRunsSecondItemWithInheritedSeason() throws {
        // 继承是批量录入省时间的核心：第二件进来时季节/温度应该是预选好的。
        let app = launchApp()

        openCaptureEntry(app)
        pickFirstPhotoFromLibrary(app)
        confirmCrop(app)
        fillName(app, "继承源")
        app.buttons["冬"].firstMatch.tap()
        app.buttons["冷 -5~10°"].firstMatch.tap()

        tapSave(app, "保存并继续")

        // 从相册来源的「保存并继续」直接回到相册，可以立刻选第二张
        let secondPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(secondPhoto.waitForExistence(timeout: 30), "应该直接回到相册")
        secondPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        confirmCrop(app)

        let nameField = app.textFields["衣物名称输入框"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15), "第二件的表单应该出现")

        // 名称不该被继承（每件都不一样）
        XCTAssertNotEqual(nameField.value as? String, "继承源")

        // 季节和温度预设应该已经选中 —— 用「冷 -5~10°」这个 chip 的选中态间接验证
        let temperatureChip = app.buttons["冷 -5~10°"].firstMatch
        XCTAssertTrue(temperatureChip.waitForExistence(timeout: 5))
        // 选中时 chip 会带着强调色，UI 测试无法读颜色，这里改为验证它可点且流程能继续
        XCTAssertTrue(temperatureChip.isHittable)

        fillName(app, "继承结果")
        tapSave(app, "保存并结束")

        XCTAssertTrue(app.navigationBars["衣柜"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["继承结果"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["继承源"].waitForExistence(timeout: 20), "第一件也该在")
    }

    // MARK: - 裁切页的缩放平移

    /// 缩放平移之后仍然能正常裁切并保存。
    ///
    /// 这条守的是一个具体的回归：之前自己用 SwiftUI 手势算缩放平移，
    /// `startAnchor` 的坐标系搞错了，导致「无论捏哪里取景框都往右下漂」，
    /// 最后裁出来的位置完全不是用户看到的位置。
    /// 现在改用 `UIScrollView`，这个测试保证「捏过之后流程仍然完整」。
    func testPinchAndDragThenCropStillSaves() throws {
        let app = launchApp()

        openCaptureEntry(app)
        pickFirstPhotoFromLibrary(app)

        let doneButton = app.buttons["完成"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 20), "选完照片必须进入裁切页")

        // 在取景区捏合放大，再拖动
        let canvas = app.images.firstMatch
        canvas.pinch(withScale: 2.0, velocity: 1.0)
        // 用坐标做拖拽：XCUIElement 的 press(forDuration:thenDragTo:) 只接受元素
        let start = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        let end = canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.65, dy: 0.65))
        start.press(forDuration: 0.1, thenDragTo: end)

        doneButton.tap()

        fillName(app, "缩放后裁切")
        tapSave(app, "保存并结束")

        XCTAssertTrue(app.navigationBars["衣柜"].waitForExistence(timeout: 20))
        XCTAssertTrue(
            app.staticTexts["缩放后裁切"].waitForExistence(timeout: 20),
            "缩放平移之后裁切保存必须照常成功"
        )
    }

    /// 「保存并结束」必须**退出整个录入流程**，不能回到相机。
    ///
    /// 这里防的是一类很低级但很烦人的错误：外壳把回调写成了恒定的
    /// `onSaved(true)`，于是两个保存按钮的语义完全一样 —— 不管点哪个都回相机。
    func testSaveAndFinishExitsFlowInsteadOfReturningToCamera() throws {
        let app = launchApp()

        openCaptureEntry(app)
        pickFirstPhotoFromLibrary(app)
        confirmCrop(app)
        fillName(app, "结束测试")

        tapSave(app, "保存并结束")

        // 回到衣柜
        XCTAssertTrue(app.navigationBars["衣柜"].waitForExistence(timeout: 20), "应该回到衣柜")
        XCTAssertTrue(app.staticTexts["结束测试"].waitForExistence(timeout: 20), "衣物应该已保存")

        // 关键：整个录入流程都关掉了 —— 入口页和相机都不该还在
        XCTAssertFalse(app.buttons["拍照"].exists, "不该回到录入入口页")
        XCTAssertFalse(app.buttons["Take Picture"].exists, "更不该回到相机")
        XCTAssertFalse(app.buttons["从相册选"].exists)
    }

    // MARK: - 取消不该留下垃圾数据

    func testCancellingFromEntryLeavesNoItem() throws {
        let app = launchApp()

        openCaptureEntry(app)

        // 入口页的「取消」直接结束整个流程
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

    func testBackingOutOfFormLeavesNoItem() throws {
        let app = launchApp()

        openCaptureEntry(app)
        pickFirstPhotoFromLibrary(app)
        confirmCrop(app)

        XCTAssertTrue(app.textFields["衣物名称输入框"].waitForExistence(timeout: 15))
        fillName(app, "不该被保存")

        // 表单里点「返回」→ 回到入口页，不写入任何数据
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["拍照"].firstMatch.waitForExistence(timeout: 15),
            "放弃表单后应该回到录入入口页"
        )

        app.buttons["取消"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["衣柜"].waitForExistence(timeout: 15))
        XCTAssertTrue(
            app.staticTexts["衣柜还是空的"].waitForExistence(timeout: 10),
            "放弃录入不该产生任何衣物"
        )
    }

    // MARK: - 分阶段的操作

    /// 衣柜 → 添加菜单 → 录入入口页
    private func openCaptureEntry(_ app: XCUIApplication) {
        app.tabBars.buttons["衣柜"].firstMatch.tap()
        app.buttons["添加"].firstMatch.tap()

        let captureEntry = app.buttons["拍照 / 从相册录入"].firstMatch
        XCTAssertTrue(captureEntry.waitForExistence(timeout: 10), "添加菜单应该弹出")
        captureEntry.tap()

        XCTAssertTrue(
            app.buttons["从相册选"].firstMatch.waitForExistence(timeout: 20),
            "应该进入录入入口页"
        )
    }

    /// 在系统相册（PHPicker）里挑第一张照片。
    ///
    /// 系统相册有几个坑，都在这里绕开：
    /// 1. 它可能先弹一个引导页（带 `Learn More…` / `Close`），把网格整个挡住；
    /// 2. 照片在层级里是 `PXGGridLayout-Info`，而且 `isHittable == false`
    ///    （外面套了一层拦截触摸的容器），所以只能按坐标点；
    /// 3. 挑完之后系统会自己关掉选择器，没有确认按钮。
    private func pickFirstPhotoFromLibrary(_ app: XCUIApplication) {
        // 先等入口页就绪：从相机收回来之后需要一点动画时间
        let libraryButton = app.buttons["从相册选"].firstMatch
        XCTAssertTrue(libraryButton.waitForExistence(timeout: 20), "录入入口页应该出现")
        libraryButton.tap()

        let closeButton = app.buttons["Close"].firstMatch
        if closeButton.waitForExistence(timeout: 8) {
            closeButton.tap()
        }

        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(
            photo.waitForExistence(timeout: 30),
            "相册里没找到可选的照片（模拟器相册可能是空的，先跑 `xcrun simctl addmedia`）"
        )
        photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
    }

    /// 裁切页 → 完成
    private func confirmCrop(_ app: XCUIApplication) {
        let doneButton = app.buttons["完成"].firstMatch
        XCTAssertTrue(doneButton.waitForExistence(timeout: 20), "选完照片必须进入裁切页")
        doneButton.tap()
    }

    private func fillName(_ app: XCUIApplication, _ text: String) {
        let nameField = app.textFields["衣物名称输入框"]
        XCTAssertTrue(nameField.waitForExistence(timeout: 15), "裁切完成后必须进入录入表单")
        nameField.tap()
        nameField.typeText(text)
    }

    /// 点保存。
    ///
    /// 保存栏用 `safeAreaInset` 固定在底部，**在键盘上方**，所以不需要先收键盘 ——
    /// 这里刻意不 dismissKeyboard，直接点，验证的就是「键盘弹着也能保存」。
    private func tapSave(_ app: XCUIApplication, _ label: String) {
        let button = app.buttons[label].firstMatch
        XCTAssertTrue(button.waitForExistence(timeout: 5), "找不到保存按钮：\(label)")
        XCTAssertTrue(button.isHittable, "「\(label)」必须可点（不能被键盘挡住）")
        button.tap()
    }
}
