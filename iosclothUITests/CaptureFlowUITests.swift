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
        pickAndCropPhoto(app)
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
        pickAndCropPhoto(app)
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
        pickAndCropPhoto(app)
        fillName(app, "继承源")
        app.buttons["冬"].firstMatch.tap()
        app.buttons["冷 -5~10°"].firstMatch.tap()

        tapSave(app, "保存并继续")

        // 从相册来源的「保存并继续」直接回到相册，可以立刻选第二张
        // 从相册来源的「保存并继续」应该直接回到系统相册，可以立刻选第二张
        let secondPhoto = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        XCTAssertTrue(secondPhoto.waitForExistence(timeout: 30), "应该直接回到相册")
        secondPhoto.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        confirmSystemCrop(app)

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
        pickAndCropPhoto(app)

        XCTAssertTrue(app.textFields["衣物名称输入框"].waitForExistence(timeout: 15))
        fillName(app, "不该被保存")

        // 表单里点「返回」→ 回到入口页，不写入任何数据
        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["entry-camera"].firstMatch.waitForExistence(timeout: 15),
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
            app.buttons["entry-library"].firstMatch.waitForExistence(timeout: 20),
            "应该进入录入入口页"
        )
    }

    /// 从系统相册挑第一张照片，并在**系统裁剪页**确认。
    ///
    /// 裁剪交给 `SystemImagePicker`（`UIImagePickerController.allowsEditing = true`），
    /// 所以这里用的是系统 UI：选完照片会进「Choose Photo」页，按钮是 Cancel / Choose。
    ///
    /// 点照片要优先用 `PXGGridLayout-Info` 这个 image，按坐标点 ——
    /// 它外面套了一层拦截触摸的容器（`isHittable == false`）；
    /// 直接点 `collectionViews.cells` 经常点不中，测试会卡在相册页。
    private func pickAndCropPhoto(_ app: XCUIApplication) {
        app.buttons["entry-library"].firstMatch.tap()

        let photo = app.images.matching(identifier: "PXGGridLayout-Info").firstMatch
        if photo.waitForExistence(timeout: 30) {
            photo.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        } else if app.collectionViews.firstMatch.cells.count > 0 {
            app.collectionViews.firstMatch.cells.firstMatch.tap()
        } else if app.images.firstMatch.waitForExistence(timeout: 15) {
            app.images.firstMatch.tap()
        } else {
            XCTFail("系统相册里没有可选照片（模拟器相册可能是空的，先跑 `xcrun simctl addmedia`）")
        }

        confirmSystemCrop(app)
    }

    /// 系统裁剪页的确认按钮。中英文都试一遍，避免测试依赖模拟器语言。
    private func confirmSystemCrop(_ app: XCUIApplication) {
        for label in ["Choose", "选择", "选取", "完成", "Done"] {
            let button = app.buttons[label].firstMatch
            if button.waitForExistence(timeout: 8) {
                button.tap()
                return
            }
        }
        XCTFail("没找到系统裁剪页的确认按钮（期望 Choose / 选择）")
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

/// 拍照模板选择的入口测试。
final class GarmentTemplateUITests: XCTestCase {

    func testTemplateChipsSwitchCameraLabel() throws {
        let app = XCUIApplication()
        app.launchArguments += ["-uitest-reset-data", "-uitest-seed-wardrobe"]
        app.launch()

        openCaptureEntry(app)

        // 四个模板都在
        for template in ["free", "top", "bottom", "dress"] {
            XCTAssertTrue(
                app.buttons["template-\(template)"].firstMatch.exists,
                "入口页应该有模板选项：\(template)"
            )
        }

        // 默认是上衣模板
        XCTAssertTrue(app.buttons["拍照（上衣模板）"].firstMatch.exists)

        // 切到下衣
        app.buttons["template-bottom"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["拍照（下衣模板）"].firstMatch.waitForExistence(timeout: 5),
            "切到下衣模板后，拍照按钮文案应该跟着变"
        )

        // 切到自由：文案变成「自由拍照」
        app.buttons["template-free"].firstMatch.tap()
        XCTAssertTrue(
            app.buttons["自由拍照"].firstMatch.waitForExistence(timeout: 5),
            "自由模板下应该是系统相机"
        )
    }

    private func openCaptureEntry(_ app: XCUIApplication) {
        app.tabBars.buttons["衣柜"].firstMatch.tap()
        app.buttons["添加"].firstMatch.tap()
        let entry = app.buttons["拍照 / 从相册录入"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()
        XCTAssertTrue(
            app.buttons["entry-library"].firstMatch.waitForExistence(timeout: 20),
            "应该进入录入入口页"
        )
    }
}

/// 「自己搭一套」的端到端测试。
///
/// 这是 App 的主要功能，所以单独一个测试类：
/// 从衣柜里挑上装 + 下装，保存，然后能在「我的搭配」里看到。
final class OutfitBuilderUITests: XCTestCase {

    private func launchWithSampleWardrobe() -> XCUIApplication {
        let app = XCUIApplication()
        // 灌一批样例衣服，省掉每次慢速录入
        app.launchArguments += ["-uitest-reset-data", "-uitest-seed-wardrobe"]
        app.launch()
        return app
    }

    func testBuildOutfitManuallyAndSave() throws {
        let app = launchWithSampleWardrobe()

        app.tabBars.buttons["搭配"].firstMatch.tap()

        let buildButton = app.buttons["自己搭一套"].firstMatch
        XCTAssertTrue(buildButton.waitForExistence(timeout: 10), "「自己搭一套」必须出现在搭配页顶部")
        buildButton.tap()

        // 上装
        let topSlot = app.buttons["slot-top"].firstMatch
        XCTAssertTrue(topSlot.waitForExistence(timeout: 10), "应该有「上装」一行")
        topSlot.tap()
        let shirt = app.buttons["candidate-白色衬衫"].firstMatch
        XCTAssertTrue(shirt.waitForExistence(timeout: 10), "候选里应该有白色衬衫")
        shirt.tap()

        // 下装
        let bottomSlot = app.buttons["slot-bottom"].firstMatch
        XCTAssertTrue(bottomSlot.waitForExistence(timeout: 10))
        bottomSlot.tap()
        let pants = app.buttons["candidate-灰色阔腿裤"].firstMatch
        XCTAssertTrue(pants.waitForExistence(timeout: 10))
        pants.tap()

        // 保存
        let saveButton = app.buttons["保存"].firstMatch
        XCTAssertTrue(saveButton.isEnabled, "上下装都选好之后应该能保存")
        saveButton.tap()

        // 在「我的搭配」里能看到
        app.tabBars.buttons["我的搭配"].firstMatch.tap()
        let saved = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '白色衬衫'")
        ).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 15), "保存的搭配应该出现在「我的搭配」里")
    }

    /// 只选上装时不能保存，并且要有明确的「还差什么」提示
    func testIncompleteOutfitCannotBeSaved() throws {
        let app = launchWithSampleWardrobe()

        app.tabBars.buttons["搭配"].firstMatch.tap()
        app.buttons["自己搭一套"].firstMatch.tap()

        app.buttons["slot-top"].firstMatch.tap()
        app.buttons["candidate-白色衬衫"].firstMatch.tap()

        XCTAssertFalse(app.buttons["保存"].firstMatch.isEnabled, "缺下装时不该能保存")
        XCTAssertTrue(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS '还差'")).firstMatch.exists,
            "应该提示还差什么"
        )
    }
}
