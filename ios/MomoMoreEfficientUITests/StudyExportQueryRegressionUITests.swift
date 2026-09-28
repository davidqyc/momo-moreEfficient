import XCTest

/// #155/#165/#180 UI regression over the DEBUG rehearsal: the withdrawn
/// StudyRecord presets stay out of the public export surface, the five
/// supported presets produce deterministic non-empty results, the Export →
/// Query handoff never auto-starts a read, Query proves its unresolved-word
/// truth, and the #180 cross-mode guard blocks wrong-mode Preview with the
/// one-tap preserving switch. Synthetic data only: in-process rehearsal
/// transport, no credential, no network, no clipboard.
final class StudyExportQueryRegressionUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - D1: the public preset surface

    func testPublicPresetListContainsExactlyTheFiveSupportedPresets() {
        let app = launchRehearsal()
        app.buttons["单词导出"].tap()

        XCTAssertTrue(app.staticTexts["单词导出"].waitForExistence(timeout: 10))
        for preset in Self.supportedPresets {
            XCTAssertTrue(app.buttons[preset].exists, preset)
        }
        // The StudyRecord-enumeration presets and the enumerability probe are
        // withdrawn from normal UI (#155 Owner directive 2026-09-28); the
        // N-day selector is unreachable with its hidden row.
        for withdrawn in [
            "今天新添加", "顽固词", "熟知词", "N 天内复习", "全部学习词",
            "运行完整性探针", "1 天内复习", "3 天内复习", "7 天内复习", "30 天内复习",
        ] {
            XCTAssertFalse(app.buttons[withdrawn].exists, withdrawn)
        }
        // The existing diagnostics strip remains visible for the remaining
        // public feature until Owner stabilization closes.
        XCTAssertTrue(app.staticTexts["诊断 · 最近一次运行"].exists)
        XCTAssertTrue(app.buttons["复制诊断"].exists)
        XCTAssertTrue(app.buttons["清除诊断"].exists)
    }

    // MARK: - D2: deterministic non-empty results

    func testAllFiveSupportedPresetsProduceDeterministicNonEmptyResults() {
        let app = launchRehearsal()
        app.buttons["单词导出"].tap()
        // The preset rows enable only once the rehearsal credential restored;
        // wait for that instead of racing the launch.
        XCTAssertTrue(waitEnabled(app.buttons["今天已学"], timeout: 20))

        // One rehearsal world (3 finished / 3 unfinished of 6), so each
        // supported preset derives its own exact expected answer.
        let expectations: [(preset: String, count: Int, words: [String])] = [
            ("今天已学", 3, ["alpha", "beta", "gamma"]),
            ("今日待复习", 3, ["delta", "epsilon", "zeta"]),
            ("今天新学", 2, ["alpha", "delta"]),
            ("今天忘记", 1, ["alpha"]),
            ("今天模糊", 1, ["beta"]),
        ]
        for expected in expectations {
            app.buttons[expected.preset].tap()
            let header = app.staticTexts["\(expected.preset) · \(expected.count) 个"]
            XCTAssertTrue(header.waitForExistence(timeout: 30), expected.preset)
            for word in expected.words {
                XCTAssertTrue(app.staticTexts[word].exists, "\(expected.preset) 应含 \(word)")
            }
            XCTAssertTrue(app.buttons["复制 \(expected.count) 个单词"].exists, expected.preset)

            app.buttons["返回列表"].tap()
            XCTAssertTrue(app.buttons[expected.preset].waitForExistence(timeout: 5), expected.preset)
        }
    }

    // MARK: - D3: Export → Query handoff

    func testExportToQueryHandoffInstallsWordsWithoutAutoRead() {
        let app = launchRehearsal()
        app.buttons["单词导出"].tap()
        XCTAssertTrue(waitEnabled(app.buttons["今天已学"], timeout: 20))
        app.buttons["今天已学"].tap()
        XCTAssertTrue(app.staticTexts["今天已学 · 3 个"].waitForExistence(timeout: 30))

        app.buttons["批量查阅 3 个"].tap()
        XCTAssertTrue(app.staticTexts["批量查阅"].waitForExistence(timeout: 10))
        // The visible source note states the handoff without a started read.
        XCTAssertTrue(
            app.staticTexts["来自单词导出 · 3 个词 · 尚未发起查阅"].waitForExistence(timeout: 5)
        )
        // The action count matches the handed-off words.
        let start = app.buttons["查阅 3 项"]
        XCTAssertTrue(start.exists)
        XCTAssertTrue(waitEnabled(start))
        // Still the input/pre-read phase: nothing is running.
        XCTAssertFalse(app.buttons["停止"].exists)
        // The exact words were installed, memory-only.
        let editor = app.textViews["批量查阅输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, "alpha\nbeta\ngamma")
    }

    // MARK: - D4: Query happy path + unresolved truth

    func testQueryHappyPathShowsNumericResultAndUnresolvedTruth() {
        let app = launchRehearsal()
        app.buttons["批量查阅"].tap()
        let editor = app.textViews["批量查阅输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("manning\nghostword")
        let start = app.buttons["查阅 2 项"]
        XCTAssertTrue(waitEnabled(start))
        start.tap()

        // One row could not resolve, so the run still completes truthfully.
        XCTAssertTrue(
            app.staticTexts["2 项 · 读取完成 · 1 项含无法读取"].waitForExistence(timeout: 40)
        )

        // manning: stable numeric result and a real detail affordance.
        let manning = app.buttons["manning"]
        XCTAssertTrue(manning.waitForExistence(timeout: 5))
        manning.tap()
        XCTAssertTrue(app.staticTexts["释义 · 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["n. 演练用旧释义"].exists)
        XCTAssertTrue(app.staticTexts["助记 · 1"].exists)
        XCTAssertTrue(app.staticTexts["演练用助记"].exists)
        app.buttons["返回"].firstMatch.tap()

        // ghostword: the unresolved truth — never a false-green numeric 0.
        let ghost = app.buttons["ghostword"]
        XCTAssertTrue(ghost.waitForExistence(timeout: 5))
        let ghostDescription = (ghost.label) + ((ghost.value as? String) ?? "")
        XCTAssertTrue(
            ghostDescription.contains("当前 Open API 无法解析该词条"),
            ghostDescription
        )
        XCTAssertFalse(ghostDescription.contains("零条"), ghostDescription)
        ghost.tap()
        XCTAssertTrue(
            app.staticTexts["这个词的释义、例句与助记数量都无法安全读取，不显示任何数字。"]
                .waitForExistence(timeout: 5)
        )
    }

    // MARK: - D5: #180 cross-mode guard, real UI

    func testGuardBlocksPhraseDocumentInInterpretationModeAndSwitchPreservesText() {
        let app = launchRehearsal()
        app.buttons["释义录入"].tap()
        let document = "## guard sample\nEN: A guard fixture sentence.\nZH: 守卫样例。\nSOURCE: Offline fixture"
        typeInto(app.textViews["批次释义输入"], document)

        XCTAssertTrue(
            app.staticTexts["检测到例句格式，当前是释义录入。为防止写错，已阻止预览。"]
                .waitForExistence(timeout: 5)
        )
        assertPreviewBlocked(app)

        app.buttons["切换到例句并保留内容"].tap()
        XCTAssertTrue(app.staticTexts["例句录入"].waitForExistence(timeout: 5))
        let phraseEditor = app.textViews["批次例句输入"]
        XCTAssertTrue(phraseEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(phraseEditor.value as? String, document)
        XCTAssertFalse(
            app.staticTexts["检测到例句格式，当前是释义录入。为防止写错，已阻止预览。"].exists
        )
        XCTAssertTrue(waitEnabled(firstPreviewButton(app)))
    }

    func testGuardBlocksInterpretationDocumentInPhraseModeAndSwitchPreservesText() {
        let app = launchRehearsal()
        app.buttons["例句录入"].tap()
        let document = "guardword\nn. 守卫样例释义"
        typeInto(app.textViews["批次例句输入"], document)

        XCTAssertTrue(
            app.staticTexts["检测到释义格式，当前是例句录入。为防止写错，已阻止预览。"]
                .waitForExistence(timeout: 5)
        )
        assertPreviewBlocked(app)

        app.buttons["切换到释义并保留内容"].tap()
        XCTAssertTrue(app.staticTexts["释义录入"].waitForExistence(timeout: 5))
        let interpretationEditor = app.textViews["批次释义输入"]
        XCTAssertTrue(interpretationEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(interpretationEditor.value as? String, document)
        XCTAssertFalse(
            app.staticTexts["检测到释义格式，当前是例句录入。为防止写错，已阻止预览。"].exists
        )
        XCTAssertTrue(waitEnabled(firstPreviewButton(app)))
    }

    // MARK: - D6: interpretation CREATE smoke through the real confirmation

    func testRehearsalInterpretationCreateRunsThroughExplicitConfirmation() {
        let app = launchRehearsal()
        app.buttons["释义录入"].tap()
        typeInto(app.textViews["批次释义输入"], "smokeword\nn. 演练释义")

        let preview = firstPreviewButton(app)
        XCTAssertTrue(waitEnabled(preview, timeout: 15))
        preview.tap()

        let create = app.buttons["新建 1"]
        XCTAssertTrue(create.waitForExistence(timeout: 40))
        create.tap()
        let confirm = app.buttons["确认写入释义"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()

        XCTAssertTrue(
            app.staticTexts["已新建 1 条 · smokeword"].waitForExistence(timeout: 40)
        )
    }

    // MARK: - Physical-device live acceptance

    /// Real provider read-only smoke on the Owner phone. Simulator runs skip it;
    /// the deterministic rehearsal tests above remain the ordinary CI gate.
    func testPhysicalLiveReadOnlyCoreSurfaces() throws {
        try requirePhysicalDevice()
        let app = launchLive()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))

        app.buttons["单词导出"].tap()
        XCTAssertTrue(app.staticTexts["单词导出"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitEnabled(app.buttons["今天已学"], timeout: 20))

        // Exactly the five supported presets: the withdrawn StudyRecord
        // surface (#155 Owner directive) must be absent on the real phone too.
        for preset in Self.supportedPresets {
            XCTAssertTrue(app.buttons[preset].exists, preset)
        }
        for withdrawn in [
            "今天新添加", "顽固词", "熟知词", "N 天内复习", "全部学习词",
            "运行完整性探针", "1 天内复习", "3 天内复习", "7 天内复习", "30 天内复习",
        ] {
            XCTAssertFalse(app.buttons[withdrawn].exists, withdrawn)
        }

        for preset in Self.supportedPresets {
            app.buttons[preset].tap()
            let header = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", preset + " · ")
            ).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 45), preset)
            XCTAssertFalse(app.staticTexts["读取失败"].exists, preset)
            XCTAssertFalse(app.staticTexts["无法证明读取完整"].exists, preset)
            app.buttons["返回列表"].tap()
            XCTAssertTrue(app.buttons[preset].waitForExistence(timeout: 10), preset)
        }

        app.buttons["返回"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 10))
        app.buttons["批量查阅"].tap()
        let editor = app.textViews["批量查阅输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText("apple")
        let start = app.buttons["查阅 1 项"]
        XCTAssertTrue(waitEnabled(start, timeout: 20))
        start.tap()
        let completed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "读取完成")
        ).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 60))
        XCTAssertTrue(app.buttons["apple"].waitForExistence(timeout: 10))
    }

    /// Real Export → Query handoff on a live study day. The first preset whose
    /// result is non-empty shows `批量查阅 N 个`; the handoff must install the
    /// exact words and never auto-start a read. When every real preset is
    /// empty today, this falls back to the simulator rehearsal proof (D3)
    /// instead of manufacturing study state.
    func testPhysicalLiveExportToQueryHandoffWhenWordsExist() throws {
        try requirePhysicalDevice()
        let app = launchLive()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        app.buttons["单词导出"].tap()
        XCTAssertTrue(waitEnabled(app.buttons["今天已学"], timeout: 20))

        for preset in Self.supportedPresets {
            app.buttons[preset].tap()
            let header = app.staticTexts.matching(
                NSPredicate(format: "label BEGINSWITH %@", preset + " · ")
            ).firstMatch
            XCTAssertTrue(header.waitForExistence(timeout: 45), preset)

            let handoff = app.buttons.matching(
                NSPredicate(format: "label BEGINSWITH %@", "批量查阅 ")
            ).firstMatch
            if handoff.waitForExistence(timeout: 3) {
                let countLabel = handoff.label
                app.buttons[countLabel].tap()
                XCTAssertTrue(app.staticTexts["批量查阅"].waitForExistence(timeout: 10))
                let sourceNote = app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", "尚未发起查阅")
                ).firstMatch
                XCTAssertTrue(sourceNote.waitForExistence(timeout: 5), countLabel)
                // The action count matches the handed-off words exactly.
                let start = app.buttons[countLabel.replacingOccurrences(
                    of: "批量查阅", with: "查阅"
                ).replacingOccurrences(of: " 个", with: " 项")]
                XCTAssertTrue(start.waitForExistence(timeout: 5), countLabel)
                XCTAssertTrue(waitEnabled(start))
                // Still the input/pre-read phase: nothing is running and no
                // provider read has started before an explicit action.
                XCTAssertFalse(app.buttons["停止"].exists)
                let editor = app.textViews["批量查阅输入"]
                XCTAssertTrue(editor.waitForExistence(timeout: 5))
                let installed = (editor.value as? String) ?? ""
                XCTAssertFalse(installed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, countLabel)
                // The real end-to-end read on live data is proven by the
                // dedicated physical Batch Query test; the handoff proof here
                // stops at the exact-count/no-auto-start boundary, like D3.
                return
            }

            app.buttons["返回列表"].tap()
            XCTAssertTrue(app.buttons[preset].waitForExistence(timeout: 10), preset)
        }
        throw XCTSkip("所有真实 Study Export 结果今天为空；Export→Query 交接由模拟器 rehearsal D3 证明")
    }

    /// #180 cross-mode guard on the real phone, both directions. Purely local:
    /// no Preview, no network, no write — the guard must block before either.
    func testPhysicalLiveGuardBlocksPhraseDocumentInInterpretationMode() throws {
        try requirePhysicalDevice()
        let app = launchLive()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        app.buttons["释义录入"].tap()
        let document = "## guard sample\nEN: A guard fixture sentence.\nZH: 守卫样例。\nSOURCE: Offline fixture"
        typeInto(app.textViews["批次释义输入"], document)

        XCTAssertTrue(
            app.staticTexts["检测到例句格式，当前是释义录入。为防止写错，已阻止预览。"]
                .waitForExistence(timeout: 5)
        )
        assertPreviewBlocked(app)

        app.buttons["切换到例句并保留内容"].tap()
        XCTAssertTrue(app.staticTexts["例句录入"].waitForExistence(timeout: 5))
        let phraseEditor = app.textViews["批次例句输入"]
        XCTAssertTrue(phraseEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(phraseEditor.value as? String, document)
        XCTAssertTrue(waitEnabled(firstPreviewButton(app), timeout: 5))
    }

    func testPhysicalLiveGuardBlocksInterpretationDocumentInPhraseMode() throws {
        try requirePhysicalDevice()
        let app = launchLive()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        app.buttons["例句录入"].tap()
        let document = "guardword\nn. 守卫样例释义"
        typeInto(app.textViews["批次例句输入"], document)

        XCTAssertTrue(
            app.staticTexts["检测到释义格式，当前是例句录入。为防止写错，已阻止预览。"]
                .waitForExistence(timeout: 5)
        )
        assertPreviewBlocked(app)

        app.buttons["切换到释义并保留内容"].tap()
        XCTAssertTrue(app.staticTexts["释义录入"].waitForExistence(timeout: 5))
        let interpretationEditor = app.textViews["批次释义输入"]
        XCTAssertTrue(interpretationEditor.waitForExistence(timeout: 5))
        XCTAssertEqual(interpretationEditor.value as? String, document)
        XCTAssertTrue(waitEnabled(firstPreviewButton(app), timeout: 5))
    }

    /// Authorized live dogfood: create interpretation -> update the same marker
    /// record -> create phrase -> delete every marker record -> verify the
    /// original active-record baseline is exact again. The independent cleanup
    /// button is exercised before and after the run so an interrupted prior run
    /// never depends on this test process surviving, and the GET-only scan
    /// entry truthfully reports 残留 0 at the end.
    func testPhysicalLiveDogfoodRoundTripRestoresDatabase() throws {
        try requirePhysicalDevice()
        let app = launchLive()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        app.buttons["设置"].tap()
        XCTAssertTrue(app.staticTexts["设置"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 20))

        let cleanup = app.buttons["撤回所有 Dogfood"]
        let scan = app.buttons["扫描验收残留"]
        makeHittable(cleanup, in: app)
        makeHittable(scan, in: app)
        XCTAssertTrue(cleanup.isHittable)
        XCTAssertTrue(scan.isHittable)
        cleanup.tap()
        let status = app.staticTexts["liveDogfoodStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        let precleanClosed = waitForLabel(
            status,
            equals: "Dogfood 已清理 · 剩余 0",
            timeout: 240
        )

        var runClosed = false
        if precleanClosed {
            let run = app.buttons["运行真实 Dogfood"]
            makeHittable(run, in: app)
            XCTAssertTrue(run.isHittable)
            run.tap()
            runClosed = waitForLabel(
                status,
                equals: "Dogfood 验证通过 · 数据已恢复原样 · 剩余 0",
                timeout: 480
            )
        }

        // Always perform an independent final sweep even when the run failed.
        makeHittable(cleanup, in: app)
        XCTAssertTrue(cleanup.isHittable)
        cleanup.tap()
        let finalCleanupClosed = waitForLabel(
            status,
            equals: "Dogfood 已清理 · 剩余 0",
            timeout: 240
        )

        // The independent GET-only scan must confirm the same truthful zero.
        makeHittable(scan, in: app)
        XCTAssertTrue(scan.isHittable)
        scan.tap()
        let scanClosed = waitForLabel(
            status,
            equals: "扫描完成 · 活跃残留 0",
            timeout: 240
        )

        XCTAssertTrue(precleanClosed, "pre-clean must close before dogfood")
        XCTAssertTrue(runClosed, "dogfood create/update/create/delete/baseline closure must pass")
        XCTAssertTrue(finalCleanupClosed, "final cleanup must leave zero active marker records")
        XCTAssertTrue(scanClosed, "independent scan must report 活跃残留 0")
    }

    // MARK: - Helpers

    private static let supportedPresets = ["今天已学", "今日待复习", "今天新学", "今天忘记", "今天模糊"]

    private func launchRehearsal() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += [
            "-MomoRehearsalMode",
            "-MomoUITestResetPreferences",
        ]
        app.launch()
        return app
    }

    private func launchLive() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MomoUITestResetPreferences"]
        app.launch()
        return app
    }

    private func requirePhysicalDevice() throws {
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("physical-device live acceptance")
        }
    }

    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<6 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    private func waitForLabel(
        _ element: XCUIElement,
        equals expected: String,
        timeout: TimeInterval
    ) -> Bool {
        let predicate = NSPredicate { _, _ in
            element.exists && element.label == expected
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    /// The write surface Preview button, titled `预览` before a valid parse
    /// and `预览 N 条` after.
    private func firstPreviewButton(_ app: XCUIApplication) -> XCUIElement {
        let counted = app.buttons["预览 1 条"]
        return counted.exists ? counted : app.buttons["预览"]
    }

    private func assertPreviewBlocked(_ app: XCUIApplication) {
        let preview = firstPreviewButton(app)
        XCTAssertTrue(preview.exists)
        XCTAssertFalse(preview.isEnabled)
    }

    private func typeInto(_ editor: XCUIElement, _ text: String) {
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        editor.typeText(text)
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate { _, _ in element.exists && element.isEnabled }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
