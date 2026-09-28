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

// MARK: - #183 round-2 high-level live state matrix (physical only)

/// Drives the #183 state-matrix scenarios through the NORMAL product path on
/// the Owner's phone: normal editor → Preview → normal action → native
/// destructive confirmation → production executor → real provider mutation →
/// production readback → History / independent Query proof. The DEBUG
/// experiment surface is used only to prepare marker-owned preconditions, arm
/// one-shot crashes, read the mutation audit, and scan/verify/cleanup.
/// Simulator runs skip everything; the ordinary CI gate is the rehearsal
/// suite above.
final class LiveStateMatrixUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: B — interpretation matrix through the normal 释义录入 UI

    /// B1 empty → CREATE, with independent Query +1, Query detail containing
    /// the marker content, a History receipt, and exact baseline restore.
    func testB1EmptyToCreateThroughNormalUI() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "B1")
        let word = prep.words[0]
        let doc = prep.docs[0]

        try assertQueryDetail(&app, word: word, interp: 0)
        let before = try auditCounts(&app)

        try performInterpretationWrite(
            &app, doc: doc, actionLabel: "新建 1",
            confirmLabel: "确认写入释义", feedbackContains: "已新建 1 条 · \(word)"
        )
        XCTAssertEqual(try auditCounts(&app).create - before.create, 1)
        XCTAssertEqual(try auditCounts(&app).update - before.update, 0)
        XCTAssertEqual(try auditCounts(&app).phrase - before.phrase, 0)

        try assertHistoryReceipt(&app, word: word, mode: "释义")
        try assertQueryDetail(&app, word: word, interp: 1, containsMarker: true)
        try cleanupAndVerify(&app)
        try assertQueryDetail(&app, word: word, interp: 0)
    }

    /// B2 one marker-owned existing → UPDATE through the normal UI; the real
    /// UPDATE targets exactly that marker record.
    func testB2OneMarkerExistingToUpdateThroughNormalUI() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "B2")
        let word = prep.words[0]
        let doc = prep.docs[0]

        let before = try auditCounts(&app)
        try performInterpretationWrite(
            &app, doc: doc, actionLabel: "更新 1",
            confirmLabel: "确认写入释义（更新）", feedbackContains: "已更新 1 条 · \(word)"
        )
        XCTAssertEqual(try auditCounts(&app).update - before.update, 1)
        XCTAssertEqual(try auditCounts(&app).create - before.create, 0)

        try assertHistoryReceipt(&app, word: word, mode: "释义")
        try assertQueryDetail(&app, word: word, interp: 1, containsMarker: true)
        try cleanupAndVerify(&app)
        try assertQueryDetail(&app, word: word, interp: 0)
    }

    /// B3 already matching → no actionable write and zero mutation delta.
    func testB3AlreadyMatchingIsNoOpWithZeroMutations() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "B3")
        let doc = prep.docs[0]

        let before = try auditCounts(&app)
        try previewInterpretation(&app, doc: doc)
        XCTAssertTrue(app.staticTexts["全部一致 · 没有需要写入的项"].waitForExistence(timeout: 90))
        XCTAssertFalse(app.buttons["新建 1"].exists)
        XCTAssertFalse(app.buttons["更新 1"].exists)

        let after = try auditCounts(&app)
        XCTAssertEqual(after.create - before.create, 0)
        XCTAssertEqual(after.update - before.update, 0)
        XCTAssertEqual(after.phrase - before.phrase, 0)
        try cleanupAndVerify(&app)
    }

    /// B4 two marker interpretations → ambiguity BLOCK before mutation.
    func testB4TwoMarkersAmbiguityBlockedZeroMutations() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "B4")
        let doc = prep.docs[0]

        let before = try auditCounts(&app)
        try previewInterpretation(&app, doc: doc)
        XCTAssertTrue(app.staticTexts["存在多条自建释义"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["新建 1"].exists)

        let after = try auditCounts(&app)
        XCTAssertEqual(after.create - before.create, 0)
        XCTAssertEqual(after.update - before.update, 0)
        try cleanupAndVerify(&app)
    }

    /// B5 real unresolvable word → Preview fail-closes with zero mutations.
    func testB5UnresolvableWordFailsClosedZeroMutations() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "B5")
        let doc = prep.docs[0]

        let before = try auditCounts(&app)
        try previewInterpretation(&app, doc: doc)
        XCTAssertTrue(
            app.staticTexts["当前 Open API 无法解析该词条；若为自添加词，当前暂不支持"]
                .waitForExistence(timeout: 20)
        )
        XCTAssertFalse(app.buttons["新建 1"].exists)

        let after = try auditCounts(&app)
        XCTAssertEqual(after.create - before.create, 0)
        XCTAssertEqual(after.update - before.update, 0)
        XCTAssertEqual(after.phrase - before.phrase, 0)
    }

    // MARK: C — phrase capacity + duplicate matrix through the normal 例句录入 UI

    func testC1FirstPhraseFromZeroThroughNormalUI() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "C1")
        let word = prep.words[0]
        let doc = prep.docs[0]

        try assertQueryDetail(&app, word: word, phrase: 0)
        let before = try auditCounts(&app)
        try performPhraseWrite(&app, doc: doc, feedbackContains: "已完成 1 条例句 · 新建 1")
        try gotoSettings(&app)
        XCTAssertEqual(try auditCounts(&app).phrase - before.phrase, 1)

        try assertHistoryReceipt(&app, word: word, mode: "例句")
        try assertQueryDetail(&app, word: word, phrase: 1, containsMarker: true)
        try cleanupAndVerify(&app)
        try assertQueryDetail(&app, word: word, phrase: 0)
    }

    func testC2SecondLegalPhraseAtEffectiveCountOne() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "C2")
        let word = prep.words[0]
        let doc = prep.docs[0]

        try assertQueryDetail(&app, word: word, phrase: 1)
        let before = try auditCounts(&app)
        try performPhraseWrite(&app, doc: doc, feedbackContains: "已完成 1 条例句 · 新建 1")
        try gotoSettings(&app)
        XCTAssertEqual(try auditCounts(&app).phrase - before.phrase, 1)
        try assertQueryDetail(&app, word: word, phrase: 2)
        try cleanupAndVerify(&app)
        try assertQueryDetail(&app, word: word, phrase: 0)
    }

    func testC3FifthLegalPhraseAtEffectiveCountFour() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "C3")
        let word = prep.words[0]
        let doc = prep.docs[0]

        try assertQueryDetail(&app, word: word, phrase: 4)
        let before = try auditCounts(&app)
        try performPhraseWrite(&app, doc: doc, feedbackContains: "已完成 1 条例句 · 新建 1")
        try gotoSettings(&app)
        XCTAssertEqual(try auditCounts(&app).phrase - before.phrase, 1)
        try assertQueryDetail(&app, word: word, phrase: 5)
        try cleanupAndVerify(&app)
        try assertQueryDetail(&app, word: word, phrase: 0)
    }

    /// C4 effective count 5 → the sixth phrase must block BEFORE any mutation.
    func testC4SixthPhraseBlockedAtCapacityZeroMutations() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "C4")
        let word = prep.words[0]
        let doc = prep.docs[0]

        try assertQueryDetail(&app, word: word, phrase: 5)
        let before = try auditCounts(&app)

        try goHome(&app)
        let c4Editor = app.textViews["批次例句输入"]
        XCTAssertTrue(tapUntil(app.buttons["例句录入"], in: app, appearing: c4Editor))
        try typeDocument(c4Editor, doc)
        let preview = previewButton(app)
        XCTAssertTrue(waitEnabled(preview, timeout: 20))
        preview.tap()
        XCTAssertTrue(
            app.staticTexts["已达到当前安全上限 5 条，请先在墨墨中编辑或删除一条旧例句后重新预览"]
                .waitForExistence(timeout: 30)
        )
        XCTAssertFalse(app.buttons["新建 1 条例句"].exists)

        try gotoSettings(&app)
        let after = try auditCounts(&app)
        XCTAssertEqual(after.phrase - before.phrase, 0, "sixth phrase must never dispatch a POST")
        try cleanupAndVerify(&app)
        try assertQueryDetail(&app, word: word, phrase: 0)
    }

    /// C5 duplicate/normalization: exact same English, smart-quote equivalent,
    /// and same-English-different-Chinese all stay zero-write.
    func testC5DuplicateAndSmartQuoteNormalizationZeroWrites() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "C5")
        let word = prep.words[0]

        let before = try auditCounts(&app)
        try performPhraseWrite(&app, doc: prep.docs[0], feedbackContains: "已完成 1 条例句 · 新建 1")
        try gotoSettings(&app)
        XCTAssertEqual(try auditCounts(&app).phrase - before.phrase, 1)

        // 1. Exact same English → already matching row, no CREATE action.
        try goHome(&app)
        try previewPhrase(&app, doc: prep.docs[0])
        XCTAssertTrue(app.staticTexts["一致"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["新建 1 条例句"].exists)

        // 2. Smart apostrophe/quote equivalent → still no CREATE.
        app.buttons["编辑"].firstMatch.tap()
        try typeDocument(app.textViews["批次例句输入"], prep.docs[1])
        let preview2 = previewButton(app)
        XCTAssertTrue(waitEnabled(preview2, timeout: 20))
        preview2.tap()
        XCTAssertTrue(app.staticTexts["一致"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["新建 1 条例句"].exists)

        // 3. Same English identity, materially different Chinese → conflict
        //    block, still no CREATE.
        app.buttons["编辑"].firstMatch.tap()
        try typeDocument(app.textViews["批次例句输入"], prep.docs[2])
        let preview3 = previewButton(app)
        XCTAssertTrue(waitEnabled(preview3, timeout: 20))
        preview3.tap()
        XCTAssertTrue(
            app.staticTexts["相同英文已存在，但中文或来源不一致"].waitForExistence(timeout: 15)
        )
        XCTAssertFalse(app.buttons["新建 1 条例句"].exists)

        try gotoSettings(&app)
        let after = try auditCounts(&app)
        XCTAssertEqual(after.phrase - before.phrase, 1, "only the original CREATE dispatched")
        try cleanupAndVerify(&app)
    }

    // MARK: D — mixed real interpretation batch

    func testDMixedBatchClassificationAndWholePlanExecution() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "D")
        let doc = prep.docs[0]

        let before = try auditCounts(&app)
        try goHome(&app)
        let dEditor = app.textViews["批次释义输入"]
        XCTAssertTrue(tapUntil(app.buttons["释义录入"], in: app, appearing: dEditor))
        try typeDocument(dEditor, doc)
        let preview = previewButton(app)
        XCTAssertTrue(waitEnabled(preview, timeout: 20))
        preview.tap()

        // Exact displayed membership: 新建 1 / 更新 1 / 一致 1 / 阻断 1, and
        // the whole-plan action covers exactly the actionable two.
        XCTAssertTrue(app.staticTexts["4 条释义"].waitForExistence(timeout: 40))
        XCTAssertTrue(app.staticTexts["一致"].exists)
        XCTAssertTrue(
            app.staticTexts["当前 Open API 无法解析该词条；若为自添加词，当前暂不支持"].exists
        )
        let action = app.buttons["执行 2 条（新建 1 · 更新 1）"]
        XCTAssertTrue(action.waitForExistence(timeout: 10))
        action.tap()
        let confirm = app.buttons["确认写入释义 2 条（新建 1 · 更新 1）"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()

        let done = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "新建成功 1")
        ).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 120))
        XCTAssertTrue(
            app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "更新成功 1")
            ).firstMatch.exists
        )

        try gotoSettings(&app)
        let after = try auditCounts(&app)
        XCTAssertEqual(after.create - before.create, 1, "only the CREATE candidate mutated")
        XCTAssertEqual(after.update - before.update, 1, "only the UPDATE candidate mutated")
        try cleanupAndVerify(&app)
    }

    // MARK: E — crash / uncertain outcome through one-shot marker-gated faults

    /// E1 interpretation POST success → process death before readback.
    func testE1CrashAfterInterpretationPostBeforeReadback() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "E1")
        let doc = prep.docs[0]

        try armFault(&app, "武装：释义写入后崩溃", "I1")

        // Normal UI write; the app must die after the known 2xx, before the
        // production readback.
        try goHome(&app)
        let e1Editor = app.textViews["批次释义输入"]
        XCTAssertTrue(tapUntil(app.buttons["释义录入"], in: app, appearing: e1Editor))
        try typeDocument(e1Editor, doc)
        let preview = previewButton(app)
        XCTAssertTrue(waitEnabled(preview, timeout: 20))
        preview.tap()
        let action = app.buttons["新建 1"]
        XCTAssertTrue(action.waitForExistence(timeout: 60))
        action.tap()
        let confirm = app.buttons["确认写入释义"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(waitTerminated(app), "fault must terminate the process after the 2xx")

        // Relaunch: GET-only recovery first — no automatic write replay.
        app.launch()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        try gotoSettings(&app)

        // The provider GET must rediscover the stranded marker even though no
        // ledger row was ever written.
        try runDogfoodAction(&app, buttonLabel: "扫描验收残留", expected: "扫描完成 · 活跃残留 1")

        // Re-Preview of the same input MUST NOT classify CREATE again.
        try previewInterpretation(&app, doc: doc)
        XCTAssertTrue(app.staticTexts["全部一致 · 没有需要写入的项"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["新建 1"].exists)

        try gotoSettings(&app)
        // The re-Preview classification above is the no-replay proof; the
        // in-memory counters reset with the process and cannot be compared
        // across the crash.
        try cleanupAndVerify(&app)
    }

    /// E2 phrase CREATE success → process death before readback/journal close.
    func testE2CrashAfterPhrasePostBeforeJournalClose() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "E2")
        let doc = prep.docs[0]

        try armFault(&app, "武装：例句写入后崩溃", "P1")

        try goHome(&app)
        let e2Editor = app.textViews["批次例句输入"]
        XCTAssertTrue(tapUntil(app.buttons["例句录入"], in: app, appearing: e2Editor))
        try typeDocument(e2Editor, doc)
        let preview = previewButton(app)
        XCTAssertTrue(waitEnabled(preview, timeout: 20))
        preview.tap()
        let action = app.buttons["新建 1 条例句"]
        XCTAssertTrue(action.waitForExistence(timeout: 60))
        action.tap()
        let confirm = app.buttons["确认写入例句 1 条"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        XCTAssertTrue(waitTerminated(app), "fault must terminate the process after the 2xx")

        app.launch()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        try gotoSettings(&app)
        try runDogfoodAction(&app, buttonLabel: "扫描验收残留", expected: "扫描完成 · 活跃残留 1")

        // Re-Preview the same phrase: the provider-visible record must prevent
        // a duplicate CREATE even though the journal never closed.
        try previewPhrase(&app, doc: doc)
        XCTAssertTrue(
            app.staticTexts["一致"].waitForExistence(timeout: 30),
            "provider-visible same-English phrase must suppress a duplicate CREATE"
        )
        XCTAssertFalse(app.buttons["新建 1 条例句"].exists)

        try gotoSettings(&app)
        try cleanupAndVerify(&app)
    }

    /// E3 DELETE success → process death before ledger retire; the relaunch
    /// GET-only scan reconciles the stale ledger without any repeat mutation.
    func testE3CrashAfterDeleteBeforeLedgerRetire() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        let prep = try prepareScenario(&app, "E3")
        _ = prep.words[0]

        try armFault(&app, "武装：清理删除后崩溃", "D1")

        let cleanup = app.buttons["撤回所有 Dogfood"]
        makeHittable(cleanup, in: app)
        cleanup.tap()
        XCTAssertTrue(waitTerminated(app), "fault must terminate the process after the DELETE")

        app.launch()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        try gotoSettings(&app)
        // GET-only scan proves the record is gone and reconciles the stale
        // active ledger entry; no blind repeat DELETE ever fires.
        try runDogfoodAction(&app, buttonLabel: "扫描验收残留", expected: "扫描完成 · 活跃残留 0")
        try runExperimentAction(
            &app, buttonLabel: "核对基线", expectedPrefix: "基线核对一致", timeout: 300
        )
    }

    // MARK: F — independent readback / membership / account / lifecycle

    /// F2 study-plan membership read-only classification, then normal CREATE →
    /// cleanup on one in-plan and one out-of-plan word if both classes exist.
    func testF2StudyMembershipReadOnlyAndWriteIndependence() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        try gotoSettings(&app)
        try runExperimentAction(
            &app, buttonLabel: "study 成员只读分类", expectedPrefix: "分类完成 · in=", timeout: 240
        )
        let detail = app.staticTexts["liveExperimentDetail"].label
        var inPlanClean: String?
        var outPlanClean: String?
        for line in detail.components(separatedBy: "\n") where line.hasPrefix("word=") {
            let inToday = line.contains("today=yes")
            let clean = line.contains("interp=0")
            let word = line
                .replacingOccurrences(of: "word=", with: "")
                .components(separatedBy: " ").first ?? ""
            guard !word.isEmpty, clean else { continue }
            if inToday, inPlanClean == nil {
                inPlanClean = word
            } else if !inToday, outPlanClean == nil {
                outPlanClean = word
            }
        }

        if let inWord = inPlanClean {
            try createAndCleanupOnPreparedWord(&app, code: "F2A", expectedWord: inWord)
        }
        guard let outWord = outPlanClean else {
            throw XCTSkip(
                "无可解析且不在 today-items 的干净候选词；in=\(inPlanClean ?? "none") out=none。写语义对成员身份的独立性由 in-plan 档与其他场景共同覆盖。"
            )
        }
        try createAndCleanupOnPreparedWord(&app, code: "F2B", expectedWord: outWord)
    }

    /// F3 invalid Token replacement must fail without breaking the old
    /// connection, proven by an immediate real read.
    func testF3InvalidTokenReplacementPreservesConnection() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        try gotoSettings(&app)

        let replace = app.buttons["更换 Token"]
        makeHittable(replace, in: app)
        replace.tap()
        let field = app.secureTextFields["墨墨账号 Token"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("XHN-SYNTHETIC-INVALID-TOKEN")
        app.buttons["更换"].tap()
        XCTAssertTrue(
            app.staticTexts["新 Token 未生效 · 原连接保持"].waitForExistence(timeout: 30),
            "invalid replacement must fail visibly with the old connection intact"
        )
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 10))

        // Immediate real read with the still-saved credential.
        try runRealRead(&app)
    }

    /// F4 cancelling a replacement changes nothing.
    func testF4CancelTokenReplacementKeepsAuthority() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        try gotoSettings(&app)

        let replace = app.buttons["更换 Token"]
        makeHittable(replace, in: app)
        replace.tap()
        let field = app.secureTextFields["墨墨账号 Token"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("XHN-SYNTHETIC-INVALID-TOKEN")
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 10))
        try runRealRead(&app)
    }

    /// F5 background/foreground during a real read, then an immediate second
    /// provider read proving the lane was released.
    func testF5LifecycleBackgroundForegroundAndLaneRelease() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))

        XCTAssertTrue(
            tapUntil(app.buttons["批量查阅"], in: app, appearing: app.staticTexts["批量查阅"])
        )
        let f5Editor = app.textViews["批量查阅输入"]
        if !f5Editor.waitForExistence(timeout: 3) {
            let modify = app.buttons["修改"].firstMatch
            XCTAssertTrue(modify.waitForExistence(timeout: 5), "results phase must offer 修改")
            modify.tap()
        }
        try typeDocument(f5Editor, "apple\nbanana\nriver")
        let start = app.buttons["查阅 3 项"]
        XCTAssertTrue(waitEnabled(start, timeout: 20))
        start.tap()

        // Background mid-read via the same mechanism the physical capture
        // tests proved, then return.
        XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        let left = XCTNSPredicateExpectation(
            predicate: NSPredicate { application, _ in
                (application as? XCUIApplication)?.state != .runningForeground
            },
            object: app
        )
        XCTAssertEqual(XCTWaiter().wait(for: [left], timeout: 10), .completed)
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)

        // The read follows the documented lifecycle semantics and completes.
        let completed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "读取完成")
        ).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 120))

        // Immediately starting another provider read surface proves the lane
        // was released rather than left occupied.
        try goHome(&app)
        XCTAssertTrue(
            tapUntil(app.buttons["单词导出"], in: app, appearing: app.buttons["今天已学"]),
            "单词导出 must open"
        )
        XCTAssertTrue(waitEnabled(app.buttons["今天已学"], timeout: 30))
        app.buttons["今天已学"].tap()
        let header = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@", "今天已学 · ")
        ).firstMatch
        XCTAssertTrue(header.waitForExistence(timeout: 60), "second provider read must start")
    }

    /// The final gate: independent scan residual 0 + every registered baseline
    /// exactly restored. Named to sort last within this class.
    func testZZFinalResidualZeroAndBaselineExact() throws {
        try requirePhysicalDevice()
        var app = launchLive()
        try gotoSettings(&app)
        try runDogfoodAction(&app, buttonLabel: "扫描验收残留", expected: "扫描完成 · 活跃残留 0")
        try runExperimentAction(
            &app, buttonLabel: "核对基线", expectedPrefix: "基线核对一致", timeout: 300
        )
    }

    // MARK: - Helpers

    private struct ExperimentPrep {
        var words: [String]
        var docs: [String]
    }

    private func requirePhysicalDevice() throws {
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("physical-device live state matrix")
        }
    }

    private func launchLive() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-MomoUITestResetPreferences"]
        app.launch()
        return app
    }

    /// Polls a status text by identifier. Manual polling (instead of
    /// XCTNSPredicateExpectation) survives physical hierarchy-refresh windows
    /// that make snapshot resolution throw mid-transition.
    @discardableResult
    private func pollLabel(
        _ app: XCUIApplication,
        id: String,
        prefix: String? = nil,
        equals: String? = nil,
        anyOf: [String] = [],
        timeout: TimeInterval
    ) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let element = try? app.staticTexts[id], element.exists {
                let label = element.label
                if let equals {
                    if label == equals { return label }
                } else if let prefix {
                    if label.hasPrefix(prefix) { return label }
                } else if !anyOf.isEmpty {
                    if anyOf.contains(where: label.hasPrefix) { return label }
                } else {
                    return label
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return nil
    }

    /// Tap-with-retry on physical hardware. Three failure classes are
    /// absorbed: taps lost during SwiftUI transitions; taps on resolved but
    /// off-screen elements (which hit the wrong screen point); and taps on
    /// tiles still disabled while the provider rate windows delay the
    /// post-relaunch credential restore (up to ~60s). Only taps a hittable,
    /// enabled target; keeps retrying until the marker appears or the overall
    /// deadline runs out.
    private func tapUntil(
        _ target: XCUIElement,
        in app: XCUIApplication,
        appearing: XCUIElement,
        timeout: TimeInterval = 90
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if target.exists {
                if !target.isHittable {
                    app.swipeDown()
                    Thread.sleep(forTimeInterval: 0.4)
                }
                if target.isHittable, target.isEnabled {
                    target.tap()
                }
                if appearing.waitForExistence(timeout: 6) { return true }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        return appearing.exists
    }

    /// Walks back (bounded) until the shell Home title is visible. Physical
    /// detail: the experiment prep scrolls Settings to its bottom, so the
    /// title-bar 返回 can be off-screen — scroll back up before each back tap.
    private func goHome(_ app: inout XCUIApplication) throws {
        for _ in 0..<6 {
            if app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 2) { return }
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.3)
            let back = app.buttons["返回"].firstMatch
            // Only tap a hittable back control: tapping an off-screen resolved
            // element hits whatever currently sits at those coordinates.
            if back.exists, back.isHittable { back.tap() }
        }
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 5), "cannot reach Home")
    }

    /// Walks back (bounded) until the shell Home is reached, then opens
    /// Settings. Safe from the editor, preview, Query or Settings itself.
    private func gotoSettings(_ app: inout XCUIApplication) throws {
        for _ in 0..<6 {
            if app.buttons["设置"].waitForExistence(timeout: 2) { break }
            app.swipeDown()
            Thread.sleep(forTimeInterval: 0.3)
            let back = app.buttons["返回"].firstMatch
            if back.exists, back.isHittable { back.tap() }
        }
        XCTAssertTrue(app.buttons["设置"].waitForExistence(timeout: 5), "cannot reach Home for Settings")
        XCTAssertTrue(
            tapUntil(app.buttons["设置"], in: app, appearing: app.staticTexts["设置"]),
            "Settings must open"
        )
        XCTAssertTrue(app.staticTexts["已连接"].waitForExistence(timeout: 60))
    }

    /// Relaunches with `-MomoExperimentScenario <code>` and waits for EXP
    /// READY (or EXP N/A, surfaced as an XCTSkip with the provider evidence).
    /// Launch-argument automation means no keyboard ever appears — a third-party
    /// keyboard on the Owner's phone otherwise eats scrolls and covers buttons.
    @discardableResult
    private func prepareScenario(_ app: inout XCUIApplication, _ code: String) throws -> ExperimentPrep {
        app.terminate()
        app.launchArguments = ["-MomoUITestResetPreferences", "-MomoExperimentScenario", code]
        app.launch()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        try gotoSettings(&app)

        let status = app.staticTexts["liveExperimentStatus"]
        guard let label = pollLabel(
            app,
            id: "liveExperimentStatus",
            anyOf: [
                "EXP READY \(code) ", "EXP N/A \(code)", "EXP FAILED \(code)",
                "EXP BLOCKED \(code)", "EXP UNKNOWN",
            ],
            timeout: 600
        ) else {
            let element = app.staticTexts["liveExperimentStatus"]
            let current = element.exists ? element.label : "<missing>"
            throw fail("scenario \(code) prep never reported: \(current)")
        }
        app.launchArguments = ["-MomoUITestResetPreferences"]
        if label.hasPrefix("EXP N/A") {
            throw XCTSkip("\(label) — provider contract makes this state unreachable")
        }
        guard label.hasPrefix("EXP READY \(code)") else {
            // Give the detail text a moment to catch up with the status.
            Thread.sleep(forTimeInterval: 2)
            let detail = app.staticTexts["liveExperimentDetail"]
            var detailText = detail.exists ? detail.label : "no detail"
            if detailText.count < 100 {
                Thread.sleep(forTimeInterval: 3)
                if detail.exists { detailText = detail.label }
            }
            throw fail("scenario \(code): \(label) — \(detailText.suffix(1200))")
        }

        let detail = app.staticTexts["liveExperimentDetail"].label
        var words: [String] = []
        for line in label.components(separatedBy: " ") {
            if line.hasPrefix("word=") {
                words.append(line.replacingOccurrences(of: "word=", with: ""))
            }
            for prefix in ["create=", "update=", "match="] where line.hasPrefix(prefix) {
                words.append(line.replacingOccurrences(of: prefix, with: ""))
            }
        }
        var docs: [String] = []
        let lines = detail.components(separatedBy: "\n")
        var index = 0
        while index < lines.count {
            if lines[index].hasSuffix(">>") {
                let name = String(lines[index].dropLast(2))
                var collected: [String] = []
                index += 1
                while index < lines.count, lines[index] != "<<\(name)" {
                    collected.append(lines[index])
                    index += 1
                }
                docs.append(collected.joined(separator: "\n"))
            }
            index += 1
        }
        return ExperimentPrep(words: words, docs: docs)
    }

    private func armFault(_ app: inout XCUIApplication, _ buttonLabel: String, _ code: String) throws {
        app.terminate()
        app.launchArguments = ["-MomoUITestResetPreferences", "-MomoExperimentArm", code]
        app.launch()
        XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
        try gotoSettings(&app)
        guard pollLabel(app, id: "liveExperimentStatus", equals: "EXP ARMED \(code)", timeout: 30) != nil else {
            throw fail("arm \(code) not confirmed: \(app.staticTexts["liveExperimentStatus"].label)")
        }
        // Plain arguments from here: the post-crash relaunch must not re-arm.
        app.launchArguments = ["-MomoUITestResetPreferences"]
    }

    private struct AuditCounts {
        var create: Int
        var update: Int
        var phrase: Int
    }

    private func auditCounts(_ app: inout XCUIApplication) throws -> AuditCounts {
        // The audit lives on the Settings page and refreshes on a 1s DEBUG
        // timer; navigate there, give it a beat, then read the label.
        try gotoSettings(&app)
        Thread.sleep(forTimeInterval: 1.5)
        let label = app.staticTexts["liveMutationAudit"].label
        func value(_ name: String) -> Int {
            for line in label.components(separatedBy: "\n") {
                let parts = line.components(separatedBy: "=")
                if parts.count == 2, parts[0] == name, let value = Int(parts[1]) {
                    return value
                }
            }
            return 0
        }
        return AuditCounts(
            create: value("interpretation_create_post"),
            update: value("interpretation_update_post"),
            phrase: value("phrase_create_post")
        )
    }

    /// XCTFail is Void; this lets a helper `throw` after recording the failure.
    private func fail(_ message: String) -> Error {
        XCTFail(message)
        return NSError(
            domain: "LiveStateMatrixUITests", code: 1,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }

    private func previewButton(_ app: XCUIApplication) -> XCUIElement {
        let counted = app.buttons.matching(
            NSPredicate(format: "label BEGINSWITH %@", "预览 ")
        ).firstMatch
        if counted.exists { return counted }
        return app.buttons["预览"]
    }

    private func typeDocument(_ editor: XCUIElement, _ text: String) throws {
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.tap()
        // Clear any input retained from an earlier step in this same app
        // session before typing the new document.
        if let current = editor.value as? String, !current.isEmpty {
            editor.typeText(String(repeating: "\u{8}", count: current.count + 5))
        }
        editor.typeText(text)
    }

    private func previewInterpretation(_ app: inout XCUIApplication, doc: String) throws {
        try goHome(&app)
        let editor = app.textViews["批次释义输入"]
        XCTAssertTrue(tapUntil(app.buttons["释义录入"], in: app, appearing: editor), "释义录入 must open")
        try typeDocument(editor, doc)
        let preview = previewButton(app)
        XCTAssertTrue(waitEnabled(preview, timeout: 20))
        preview.tap()
    }

    private func previewPhrase(_ app: inout XCUIApplication, doc: String) throws {
        try goHome(&app)
        let editor = app.textViews["批次例句输入"]
        XCTAssertTrue(tapUntil(app.buttons["例句录入"], in: app, appearing: editor), "例句录入 must open")
        try typeDocument(editor, doc)
        let preview = previewButton(app)
        XCTAssertTrue(waitEnabled(preview, timeout: 20))
        preview.tap()
    }

    private func performInterpretationWrite(
        _ app: inout XCUIApplication,
        doc: String,
        actionLabel: String,
        confirmLabel: String,
        feedbackContains: String
    ) throws {
        try previewInterpretation(&app, doc: doc)
        let action = app.buttons[actionLabel]
        XCTAssertTrue(action.waitForExistence(timeout: 90), actionLabel)
        action.tap()
        let confirm = app.buttons[confirmLabel]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10), confirmLabel)
        confirm.tap()

        let feedback = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", feedbackContains)
        ).firstMatch
        if feedback.waitForExistence(timeout: 120) { return }

        // The product's documented uncertain-outcome contract: a write whose
        // readback was not visible in time shows 未确认 and tells the user to
        // re-preview — the re-Preview (GET truth, never a second POST) must
        // then show the landed state as 一致. No mutation retry happens here.
        let unconfirmed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "未确认 1")
        ).firstMatch
        guard unconfirmed.waitForExistence(timeout: 5) else {
            let allText = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "")
            ).firstMatch
            throw fail("write feedback never appeared: \(feedbackContains)")
        }
        try previewInterpretation(&app, doc: doc)
        XCTAssertTrue(
            app.staticTexts["全部一致 · 没有需要写入的项"].waitForExistence(timeout: 30),
            "re-Preview after 未确认 must prove the write landed (一致), never a second action row"
        )
        XCTAssertFalse(app.buttons["新建 1"].exists)
        XCTAssertFalse(app.buttons["更新 1"].exists)
    }

    private func performPhraseWrite(
        _ app: inout XCUIApplication,
        doc: String,
        feedbackContains: String
    ) throws {
        try previewPhrase(&app, doc: doc)
        let action = app.buttons["新建 1 条例句"]
        XCTAssertTrue(action.waitForExistence(timeout: 90))
        action.tap()
        let confirm = app.buttons["确认写入例句 1 条"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 10))
        confirm.tap()
        let feedback = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", feedbackContains)
        ).firstMatch
        XCTAssertTrue(feedback.waitForExistence(timeout: 120), feedbackContains)
    }

    /// Independent Batch Query proof. Each attempt starts from a fresh app
    /// process: the retained input/results state of a same-session re-entry
    /// cannot be cleared reliably on the Owner's third-party keyboard, while a
    /// fresh process always opens the input phase empty. Read-only surface, so
    /// repeating it is safe.
    private func assertQueryDetail(
        _ app: inout XCUIApplication,
        word: String,
        interp: Int? = nil,
        phrase: Int? = nil,
        containsMarker: Bool = false
    ) throws {
        // The provider's authenticated phrase/interpretation lists are
        // eventually consistent after a write; a count proof that runs too
        // early can legitimately miss the new record. Retry the whole
        // read-only proof up to three times with a settle gap — GET-only.
        var firstError: Error?
        for attempt in 0..<3 {
            app.terminate()
            app.launch()
            XCTAssertTrue(app.staticTexts["小黑鸟伴侣"].waitForExistence(timeout: 15))
            do {
                try assertQueryDetailOnce(
                    &app, word: word, interp: interp, phrase: phrase, containsMarker: containsMarker
                )
                return
            } catch {
                firstError = error
                if attempt < 2 {
                    Thread.sleep(forTimeInterval: 30)
                }
            }
        }
        throw firstError!
    }

    private func assertQueryDetailOnce(
        _ app: inout XCUIApplication,
        word: String,
        interp: Int? = nil,
        phrase: Int? = nil,
        containsMarker: Bool = false
    ) throws {
        // Fresh process: Home → Query opens the empty input phase directly.
        let title = app.staticTexts["批量查阅"]
        guard tapUntil(app.buttons["批量查阅"], in: app, appearing: title) else {
            var evidence = "keyboards=\(app.keyboards.count)"
            evidence += " hierarchyTail=" + String(app.debugDescription.suffix(1600))
            throw fail("批量查阅 must open — \(evidence)")
        }
        let editor = app.textViews["批量查阅输入"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "fresh input phase must show the editor")
        try typeDocument(editor, word)
        let start = app.buttons["查阅 1 项"]
        XCTAssertTrue(waitEnabled(start, timeout: 20))
        start.tap()
        let completed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "读取完成")
        ).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 90), word)

        let row = app.buttons[word]
        XCTAssertTrue(row.waitForExistence(timeout: 10), word)
        row.tap()
        if let interp {
            XCTAssertTrue(app.staticTexts["释义 · \(interp)"].waitForExistence(timeout: 10), word)
        }
        if let phrase {
            XCTAssertTrue(app.staticTexts["例句 · \(phrase)"].waitForExistence(timeout: 10), word)
        }
        if containsMarker {
            // Interpretation-family markers are underscore-joined; the phrase
            // family carries a hyphen marker in its rendered origin meta.
            let markerVisible = app.staticTexts.matching(
                NSPredicate(format: "label CONTAINS %@", "XHN_DOGFOOD")
            ).firstMatch.exists
                || app.staticTexts.matching(
                    NSPredicate(format: "label CONTAINS %@", "XHN-DOGFOOD")
                ).firstMatch.exists
            XCTAssertTrue(markerVisible, "\(word) detail must visibly contain marker-owned content")
        }
        app.buttons["返回"].firstMatch.tap()
    }

    private func assertHistoryReceipt(
        _ app: inout XCUIApplication,
        word: String,
        mode: String
    ) throws {
        try goHome(&app)
        let editor = app.textViews["批次\(mode)输入"]
        XCTAssertTrue(tapUntil(app.buttons["\(mode)录入"], in: app, appearing: editor))
        let history = app.buttons["\(mode)历史"]
        XCTAssertTrue(history.waitForExistence(timeout: 10))
        history.tap()
        let receipt = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", word)
        ).firstMatch
        XCTAssertTrue(receipt.waitForExistence(timeout: 15), "\(mode) history must show \(word)")
        app.buttons["返回"].firstMatch.tap()
    }

    /// Runs the dogfood cleanup and the independent baseline verification.
    private func cleanupAndVerify(_ app: inout XCUIApplication) throws {
        try gotoSettings(&app)
        try runDogfoodAction(
            &app, buttonLabel: "撤回所有 Dogfood", expected: "Dogfood 已清理 · 剩余 0", timeout: 300
        )
        try runExperimentAction(
            &app, buttonLabel: "核对基线", expectedPrefix: "基线核对一致", timeout: 300
        )
    }

    @discardableResult
    private func runDogfoodAction(
        _ app: inout XCUIApplication,
        buttonLabel: String,
        expected: String,
        timeout: TimeInterval = 240
    ) throws -> Bool {
        let button = app.buttons[buttonLabel]
        makeHittable(button, in: app)
        XCTAssertTrue(button.isHittable, buttonLabel)
        button.tap()
        guard pollLabel(app, id: "liveDogfoodStatus", equals: expected, timeout: timeout) != nil else {
            let element = app.staticTexts["liveDogfoodStatus"]
            throw fail("\(buttonLabel) → expected '\(expected)', got '\(element.exists ? element.label : "<missing>")'")
        }
        return true
    }

    @discardableResult
    private func runExperimentAction(
        _ app: inout XCUIApplication,
        buttonLabel: String,
        expectedPrefix: String,
        timeout: TimeInterval
    ) throws -> Bool {
        let button = app.buttons[buttonLabel]
        makeHittable(button, in: app)
        XCTAssertTrue(button.isHittable, buttonLabel)
        button.tap()
        guard pollLabel(app, id: "liveExperimentStatus", prefix: expectedPrefix, timeout: timeout) != nil else {
            let element = app.staticTexts["liveExperimentStatus"]
            throw fail("\(buttonLabel) → expected prefix '\(expectedPrefix)', got '\(element.exists ? element.label : "<missing>")'")
        }
        return true
    }

    /// F2 helper: prepare F2A/F2B (which selects by today-membership), run the
    /// normal CREATE, verify, then cleanup.
    private func createAndCleanupOnPreparedWord(
        _ app: inout XCUIApplication,
        code: String,
        expectedWord: String
    ) throws {
        try goHome(&app)
        let prep = try prepareScenario(&app, code)
        XCTAssertTrue(prep.words.contains(expectedWord), "\(code) expected \(expectedWord), got \(prep.words)")
        let word = prep.words[0]
        let doc = prep.docs[0]
        try performInterpretationWrite(
            &app, doc: doc, actionLabel: "新建 1",
            confirmLabel: "确认写入释义", feedbackContains: "已新建 1 条 · \(word)"
        )
        try assertQueryDetail(&app, word: word, interp: 1, containsMarker: true)
        try cleanupAndVerify(&app)
    }

    private func runRealRead(_ app: inout XCUIApplication) throws {
        try goHome(&app)
        let title = app.staticTexts["批量查阅"]
        XCTAssertTrue(tapUntil(app.buttons["批量查阅"], in: app, appearing: title), "批量查阅 must open")
        let editor = app.textViews["批量查阅输入"]
        if !editor.waitForExistence(timeout: 3) {
            let modify = app.buttons["修改"].firstMatch
            XCTAssertTrue(modify.waitForExistence(timeout: 5), "results phase must offer 修改")
            modify.tap()
        }
        try typeDocument(editor, "apple")
        let start = app.buttons["查阅 1 项"]
        XCTAssertTrue(waitEnabled(start, timeout: 20))
        start.tap()
        let completed = app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "读取完成")
        ).firstMatch
        XCTAssertTrue(completed.waitForExistence(timeout: 90), "old credential must still read")
        app.buttons["返回"].firstMatch.tap()
    }

    private func waitTerminated(_ app: XCUIApplication) -> Bool {
        let terminated = XCTNSPredicateExpectation(
            predicate: NSPredicate { application, _ in
                (application as? XCUIApplication)?.state == .notRunning
            },
            object: app
        )
        return XCTWaiter().wait(for: [terminated], timeout: 60) == .completed
    }

    private func makeHittable(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            app.swipeUp()
        }
    }

    private func waitEnabled(_ element: XCUIElement, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate { _, _ in element.exists && element.isEnabled }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}
