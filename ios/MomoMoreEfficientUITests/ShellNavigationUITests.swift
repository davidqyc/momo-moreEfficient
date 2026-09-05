import XCTest

/// On-simulator regression for the #161 shell.
///
/// Covers the navigation-class distinctions the Design contract turns on:
/// which gestures are pushes, which are state changes inside one destination,
/// and — the one that matters most — that the single `.write` destination can
/// never be entered twice. Nothing here touches a credential or the provider:
/// every surface it visits is reachable while disconnected.
final class ShellNavigationUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Home

    func testHomeShowsExactlyTheFourFrozenEntries() {
        let app = launch()

        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 10))
        for entry in ["释义录入", "例句录入", "批量查阅"] {
            XCTAssertTrue(app.buttons[entry].exists, entry)
        }
        XCTAssertTrue(app.buttons["设置"].exists)

        // Frozen out of Home: no account row, no History summary, no tabs.
        XCTAssertFalse(app.staticTexts["连接状态"].exists)
        XCTAssertFalse(app.buttons["历史"].exists)
        XCTAssertEqual(app.tabBars.count, 0)
    }

    // MARK: - Settings

    func testSettingsOwnsAccountManagementAndReachesPreferencesAndAbout() {
        let app = launch()
        app.buttons["设置"].tap()

        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["连接状态"].exists)
        // Disconnected: connect is offered, replace/remove are not.
        XCTAssertTrue(app.buttons["连接墨墨账号"].exists)
        XCTAssertFalse(app.buttons["更换 Token"].exists)
        XCTAssertFalse(app.buttons["移除 Token"].exists)

        app.buttons["录入偏好"].tap()
        XCTAssertTrue(app.staticTexts["录入偏好"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["释义发布状态"].exists)
        // The publication segment exists and is never labelled with the
        // forbidden private-sounding word.
        XCTAssertTrue(app.buttons["公开"].exists)
        XCTAssertTrue(app.buttons["未发布"].exists)
        XCTAssertFalse(app.buttons["私密"].exists)
        XCTAssertTrue(app.staticTexts["标签（释义、例句共用）· 可选"].exists)

        // Selecting a tag updates the shared counter …
        app.buttons["考研"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 1 / 3"].waitForExistence(timeout: 3))

        // … and the Settings root summary reflects both preferences.
        back(app)
        XCTAssertTrue(app.staticTexts["公开 · 标签 1/3"].waitForExistence(timeout: 5))

        app.buttons["关于小黑鸟伴侣"].tap()
        XCTAssertTrue(app.staticTexts["关于"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.links["隐私说明"].exists || app.buttons["隐私说明"].exists)

        // Restore the preference so the run leaves no state behind.
        back(app)
        app.buttons["录入偏好"].tap()
        XCTAssertTrue(app.staticTexts["录入偏好"].waitForExistence(timeout: 5))
        app.buttons["考研"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 0 / 3"].waitForExistence(timeout: 3))
    }

    // MARK: - The one write destination

    func testModeSwitchIsStateNotNavigationAndWriteIsEnteredOnce() {
        let app = launch()

        app.buttons["释义录入"].tap()
        XCTAssertTrue(app.staticTexts["释义录入"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["释义历史"].exists)
        XCTAssertTrue(app.staticTexts["连接状态"].exists)
        // Disconnected: Preview is visibly disabled with a truthful why-line.
        XCTAssertTrue(app.staticTexts["连接墨墨账号后可预览"].exists)

        // Switching mode changes state only: the title and history pill follow,
        // and no second destination is pushed.
        app.buttons["例句"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["例句录入"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["例句历史"].exists)
        XCTAssertFalse(app.staticTexts["释义录入"].exists)

        // One back returns to Home, proving the mode switch pushed nothing.
        back(app)
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 5))

        // Entering the other tile also lands on the same single destination.
        app.buttons["例句录入"].tap()
        XCTAssertTrue(app.staticTexts["例句录入"].waitForExistence(timeout: 5))
        back(app)
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 5))
    }

    func testContextualHistoryIsReachedFromTheWriteSurfaceAndReturns() {
        let app = launch()
        app.buttons["释义录入"].tap()
        app.buttons["释义历史"].tap()

        XCTAssertTrue(app.staticTexts["释义历史"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["暂无历史"].exists)
        // Clearing is disabled with nothing to clear.
        XCTAssertFalse(app.buttons["清空历史"].isEnabled)

        back(app)
        XCTAssertTrue(app.staticTexts["释义录入"].waitForExistence(timeout: 5))
    }

    // MARK: - Query

    func testQueryInputStatesAndDisconnectedGate() {
        let app = launch()
        app.buttons["批量查阅"].tap()

        XCTAssertTrue(app.staticTexts["批量查阅"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["只读取，不写入"].exists)
        // Disconnected: the primary action is visibly disabled with a why-line.
        XCTAssertTrue(app.staticTexts["连接墨墨账号后可查阅"].exists)
        XCTAssertFalse(app.buttons["查阅"].isEnabled)

        // Typing updates the parse line and the action count without any request.
        let editor = app.textViews["批量查阅输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        editor.tap()
        editor.typeText("alpha\nbeta,gamma")
        XCTAssertTrue(
            app.staticTexts["已识别 3 项 · alpha → gamma"].waitForExistence(timeout: 5)
        )
        XCTAssertTrue(app.buttons["查阅 3 项"].exists)
        // Still disconnected, so it stays disabled rather than disappearing.
        XCTAssertFalse(app.buttons["查阅 3 项"].isEnabled)

        back(app)
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 5))
    }

    func testQueryInputSurvivesLeavingAndReenteringInTheSameProcess() {
        let app = launch()
        app.buttons["批量查阅"].tap()

        let editor = app.textViews["批量查阅输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("alpha")
        XCTAssertTrue(app.buttons["查阅 1 项"].waitForExistence(timeout: 5))

        back(app)
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 5))
        app.buttons["批量查阅"].tap()

        // The store is app-scoped, so the input is still there with no work done.
        XCTAssertTrue(app.buttons["查阅 1 项"].waitForExistence(timeout: 5))
    }

    // MARK: - Dynamic Type pressure

    /// At accessibility sizes nothing decision-bearing may disappear: rows grow
    /// and the tag grid falls back to a native list, but every entry stays
    /// reachable and every why-line stays readable.
    func testAccessibilitySizesKeepEveryEntryReachableAndTruthful() {
        let app = launch(contentSize: "UICTContentSizeCategoryAccessibilityExtraExtraExtraLarge")

        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 10))
        for entry in ["释义录入", "例句录入", "批量查阅"] {
            XCTAssertTrue(app.buttons[entry].exists, entry)
        }

        // The write surface keeps its disabled-Preview why-line rather than
        // truncating it away.
        app.buttons["释义录入"].tap()
        XCTAssertTrue(app.staticTexts["连接墨墨账号后可预览"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["预览"].isEnabled)
        back(app)

        // The tag selector falls back to a native list; the same 22 tags stay
        // addressable and the 3/3 rule still holds.
        app.buttons["设置"].tap()
        app.buttons["录入偏好"].tap()
        XCTAssertTrue(app.staticTexts["释义发布状态"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["公开"].exists)

        for tag in ["考研", "雅思", "托福"] {
            app.buttons[tag].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["已选 3 / 3"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["已达上限 3 项 · 取消任意一项后可再选"].exists)
        // At 3/3 an unselected tag is not selectable, and the counter proves it.
        app.buttons["专八"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 3 / 3"].exists)

        // Deselecting one immediately re-enables adding another.
        app.buttons["托福"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["已选 2 / 3"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["还可再选 1 项"].exists)

        for tag in ["考研", "雅思"] {
            app.buttons[tag].firstMatch.tap()
        }
        XCTAssertTrue(app.staticTexts["已选 0 / 3"].waitForExistence(timeout: 3))
    }

    // MARK: - Helpers

    private func launch(contentSize: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if let contentSize {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", contentSize]
        }
        app.launch()
        return app
    }

    /// The shell uses a circular back control instead of a system back button.
    private func back(_ app: XCUIApplication) {
        app.buttons["返回"].firstMatch.tap()
    }
}
