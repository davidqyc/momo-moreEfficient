import XCTest
@testable import MomoMoreEfficient

/// #75: an already-authorized execution must survive ordinary app switching and
/// call interruptions, and must still fail closed when iOS actually reclaims the
/// app. Backgrounding *before* execution keeps the existing stale-Preview safety.
@MainActor
final class ExecutionLifecycleTests: XCTestCase {

    // MARK: - Background no longer cancels an authorized run

    func testBackgroundingDuringAuthorizedCreateDoesNotCancelIt() async {
        let historyStore = InMemoryHistoryStore()
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            previewRun(["one", "two"]),
            previewRun(["one", "two"]) + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_B", "n. 二")]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore, assertion: assertion)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertNotNil(execution)
        // The exact scene transition that used to kill the batch.
        model.enterBackground()
        await execution?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 2)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.succeeded, 2)
        XCTAssertEqual(model.history.first?.notAttempted, 0)
        XCTAssertEqual(model.history.first?.stopped, false)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.confirmed, .confirmed])
        XCTAssertEqual(model.finalSummary.notAttempted, 0)
    }

    func testRepeatedInactiveAndActiveChurnDoesNotCancelAuthorizedRun() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            previewRun(["one"]),
            previewRun(["one"]) + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
            ],
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = "one\nn. 一"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        // A call arrives, is dismissed, the user switches apps, then returns.
        model.enterBackground()
        await model.enterForeground()
        model.enterBackground()
        await model.enterForeground()
        await execution?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertEqual(model.history.first?.stopped, false)
        XCTAssertTrue(model.isConnected)
    }

    func testBackgroundDuringRunDefersCredentialTeardownUntilItResolves() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            previewRun(["one"]),
            previewRun(["one"]) + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
            ],
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = "one\nn. 一"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        model.enterBackground()
        // Still connected: the run owns the session until it resolves.
        XCTAssertTrue(model.isConnected)
        await execution?.value

        // The postponed teardown lands once the batch is done.
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertEqual(model.history.first?.succeeded, 1)
    }

    // MARK: - Pre-execution stale-Preview safety is unchanged

    func testBackgroundBeforeExecutionStillInvalidatesExecutablePreview() async {
        let factory = SequencedTransportFactory([previewRun(["one"])])
        let model = connectedModel(factory)
        model.sourceText = "one\nn. 一"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        XCTAssertTrue(model.hasExecutablePreview)

        model.enterBackground()

        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertTrue(model.isPreviewStale)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertNil(model.executeConfirmed(.create))
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
    }

    // MARK: - Expiry fails closed

    func testBackgroundTimeExpiryStopsRemainingItemsWithoutRetryOrSecondPOST() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let preview = previewRun(["one", "two"])
        let previewTransport = FakeHTTPTransport(preview)
        let executionTransport = PausingPOSTTransport(preview + [
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
        ])
        let model = connectedModel(
            transports: [previewTransport, executionTransport],
            assertion: assertion
        )
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        await executionTransport.waitUntilPOSTDispatched()
        assertion.expire()
        await executionTransport.resumePOST()
        await execution?.value

        // The in-flight item keeps its readback; nothing after it is dispatched.
        let postCount = await executionTransport.postCount
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(model.finalSummary.created, 1)
        XCTAssertEqual(model.finalSummary.failed, 0)
        XCTAssertEqual(model.finalSummary.notAttempted, 1)
        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.confirmed, .notAttempted])
        // The pending draft is preserved for a fresh Preview, never replayed.
        XCTAssertEqual(model.sourceText, "one\nn. 一\ntwo\nn. 二")
    }

    func testForegroundReturnAfterExpiredRunDoesNotResumeOrArmApproval() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let preview = previewRun(["one", "two"])
        let previewTransport = FakeHTTPTransport(preview)
        let executionTransport = PausingPOSTTransport(preview + [
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
        ])
        let model = connectedModel(
            transports: [previewTransport, executionTransport],
            assertion: assertion
        )
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        let execution = model.executeConfirmed(.create)
        await executionTransport.waitUntilPOSTDispatched()
        assertion.expire()
        await executionTransport.resumePOST()
        await execution?.value
        let postsAfterStop = await executionTransport.postCount

        await model.enterForeground()

        let postsAfterForeground = await executionTransport.postCount
        XCTAssertEqual(postsAfterForeground, postsAfterStop)
        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.executionStage)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.executeConfirmed(.create))
        XCTAssertEqual(model.history.count, 1)
    }

    // MARK: - Assertion lifetime

    func testAssertionIsTakenAtConfirmationAndReleasedWhenBatchResolves() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            previewRun(["one"]),
            previewRun(["one"]) + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
            ],
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = "one\nn. 一"
        await model.previewCurrentInput()
        // The Preview took and released one of its own (#78); execution's is
        // measured as the delta from there.
        let afterPreview = assertion.beginCount
        XCTAssertEqual(assertion.endCount, afterPreview)
        XCTAssertFalse(assertion.isHeld)
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertEqual(assertion.beginCount, afterPreview + 1)
        XCTAssertTrue(assertion.isHeld)
        await execution?.value

        XCTAssertEqual(assertion.endCount, afterPreview + 1)
        XCTAssertFalse(assertion.isHeld)
    }

    /// #78: a Preview is a user-initiated read and takes the same finite assertion
    /// as an authorized write batch, released as soon as the read resolves.
    func testPreviewTakesAndReleasesABackgroundAssertion() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([previewRun(["one"])])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = "one\nn. 一"

        await model.previewCurrentInput()

        XCTAssertEqual(assertion.beginCount, 1)
        XCTAssertEqual(assertion.endCount, 1)
        XCTAssertFalse(assertion.isHeld)
    }

    // MARK: - Progress

    func testProgressIsVisibleImmediatelyAfterConfirmationAndClearsOnCompletion() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            previewRun(["one", "two"]),
            previewRun(["one", "two"]) + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_B", "n. 二")]),
            ],
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        XCTAssertNil(model.executionProgressLabel)
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        // Synchronously, before the first await: no unexplained grey UI.
        XCTAssertTrue(model.isExecuting)
        XCTAssertEqual(model.executionStage, .securing)
        XCTAssertEqual(model.executionProgressLabel, "安全确认中…")

        await execution?.value

        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.executionStage)
        XCTAssertNil(model.executionProgressLabel)
    }

    func testProgressAdvancesFromRealWriteProgressNotATimer() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let preview = previewRun(["one", "two"])
        let previewTransport = FakeHTTPTransport(preview)
        let executionTransport = PausingPOSTTransport(preview + [
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
        ])
        let model = connectedModel(
            transports: [previewTransport, executionTransport],
            assertion: assertion
        )
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        await executionTransport.waitUntilPOSTDispatched()
        let reached = await waitForStage(
            model,
            .writing(group: .create, item: 1, total: 2, spelling: "one")
        )
        XCTAssertTrue(reached, "expected the first item's write stage, got \(String(describing: model.executionStage))")
        XCTAssertEqual(model.executionProgressLabel, "正在新建 1/2 · one")

        assertion.expire()
        await executionTransport.resumePOST()
        await execution?.value
        XCTAssertNil(model.executionProgressLabel)
    }

    func testUpdateProgressUsesUpdateWording() {
        XCTAssertEqual(
            ExecutionStage.writing(group: .update, item: 1, total: 2, spelling: "manning").label,
            "正在更新 1/2 · manning"
        )
        XCTAssertEqual(ExecutionStage.securing.label, "安全确认中…")
        XCTAssertEqual(ExecutionStage.finishing(group: .update).label, "正在收尾…")
    }

    func testProgressNeverCarriesCredentialOrIdentifierMaterial() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let preview = previewRun(["one", "two"])
        let previewTransport = FakeHTTPTransport(preview)
        let executionTransport = PausingPOSTTransport(preview + [
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
        ])
        let model = connectedModel(
            transports: [previewTransport, executionTransport],
            assertion: assertion
        )
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        let execution = model.executeConfirmed(.create)
        await executionTransport.waitUntilPOSTDispatched()
        _ = await waitForStage(
            model,
            .writing(group: .create, item: 1, total: 2, spelling: "one")
        )

        let rendered = String(describing: model.executionStage)
            + (model.executionProgressLabel ?? "")
        XCTAssertFalse(rendered.contains(fakeToken))
        XCTAssertFalse(rendered.contains("INVALID_VOC"))
        XCTAssertFalse(rendered.contains("INVALID_RECORD"))

        assertion.expire()
        await executionTransport.resumePOST()
        await execution?.value
    }

    // MARK: - #76: the execution-time preflight is compact, writes stay numbered

    /// The safety pass still reads every approved item, but the Owner sees one
    /// compact stage instead of a second apparent 1/N sequence.
    func testExecutionTimePreflightReportsOneCompactStageRegardlessOfEntryCount() async throws {
        for (document, spellings) in [
            ("one\nn. 一\ntwo\nn. 二", ["one", "two"]),
            ("one\nn. 一\ntwo\nn. 二\nthree\nn. 三", ["one", "two", "three"]),
        ] {
            let stages = try await recordedStages(document: document, spellings: spellings)
            XCTAssertEqual(stages.filter { $0 == .securing }.count, 1, document)
            XCTAssertEqual(stages.first, .securing, document)
        }
    }

    func testNoExecutionStageEverRendersAPreflightStyleCounter() async throws {
        let stages = try await recordedStages(
            document: "one\nn. 一\ntwo\nn. 二",
            spellings: ["one", "two"]
        )
        for stage in stages {
            guard case .writing = stage else {
                // Only real writes may carry per-item numbers.
                XCTAssertFalse(stage.label.contains("/"), stage.label)
                XCTAssertFalse(stage.label.contains("预检"), stage.label)
                continue
            }
        }
        // The whole-batch preflight still ran over every entry: 2 GET pairs before
        // the first POST, exactly as before.
        XCTAssertEqual(
            stages.compactMap { stage -> String? in
                guard case .writing = stage else { return nil }
                return stage.label
            },
            ["正在新建 1/2 · one", "正在新建 2/2 · two"]
        )
    }

    func testViewModelPreflightLabelIsTheCompactSecuringStage() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            previewRun(["one", "two"]),
            previewRun(["one", "two"]) + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_B", "n. 二")]),
            ],
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertEqual(model.executionStage, .securing)
        XCTAssertEqual(model.executionProgressLabel, "安全确认中…")
        await execution?.value
    }

    // MARK: - The DEBUG rehearsal harness the Owner runs on the device

    func testRehearsalModeIsOffUnlessExplicitlyLaunchedIntoIt() {
        // Nothing in a normal test/app launch opts in.
        XCTAssertFalse(RehearsalMode.isEnabled)
    }

    func testRehearsalHistoryStoreIsInMemoryAndSupportsLoadSaveClear() throws {
        let store = RehearsalHistoryStore()
        XCTAssertTrue(try store.loadReceipts().isEmpty)

        let receipt = ExecutionReceipt(
            operationGroup: .create,
            selectedSpellings: ["collapse"],
            result: ExecutionSummary(
                group: .create,
                succeeded: 1,
                failed: 0,
                cancelled: false,
                stalePreview: false,
                results: [ItemExecutionResult(spelling: "collapse", outcome: .confirmed)]
            )
        )
        try store.saveReceipts([receipt])
        XCTAssertEqual(try store.loadReceipts().count, 1)

        try store.clearReceipts()
        XCTAssertTrue(try store.loadReceipts().isEmpty)

        // Nothing survives into a new store: the rehearsal leaves no trace.
        XCTAssertTrue(try RehearsalHistoryStore().loadReceipts().isEmpty)
    }

    func testRehearsalReceiptsNeverReachPersistentApplicationSupportHistory() async throws {
        // A production-shaped store over a temporary application-support root,
        // seeded so any contamination would be detectable as a change.
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("rehearsal-isolation-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let persistent = FileHistoryStore(applicationSupportDirectory: root)
        try persistent.saveReceipts([])
        let before = try persistent.loadReceipts()

        // The real rehearsal wiring, only made fast.
        let model = CompanionViewModel.makeRehearsal(
            perRequestDelaySeconds: 0,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        await model.enterForeground()
        model.sourceText = "collapse\nn. 崩塌"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        await model.executeConfirmed(.create)?.value

        // The rehearsal receipt is visible in the History UI …
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertNil(model.historyErrorMessage)
        // … and nothing was written to persistent history.
        XCTAssertEqual(try persistent.loadReceipts(), before)
        XCTAssertTrue(try persistent.loadReceipts().isEmpty)
        // A production store built the way the app builds it is also untouched
        // by the rehearsal: no rehearsal spelling can appear in it.
        let productionReceipts = (try? FileHistoryStore().loadReceipts()) ?? []
        XCTAssertFalse(
            productionReceipts.contains { $0.items.contains { $0.spelling == "collapse" } }
        )
    }

    func testRehearsalHarnessDrivesTheRealPipelineToFullSuccessOffline() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel.makeRehearsal(
            perRequestDelaySeconds: 0,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        await model.enterForeground()
        XCTAssertTrue(model.isConnected)
        // `manning` is seeded as already having one interpretation, so a rehearsal
        // batch exercises both classifications the Owner will see.
        model.sourceText = "collapse\nn. 崩塌\nmanning\nn. 人员配置"

        await model.previewCurrentInput()

        XCTAssertEqual(model.preview?.counts.create, 1)
        XCTAssertEqual(model.preview?.counts.update, 1)
        XCTAssertEqual(model.preview?.counts.blocked, 0)

        model.askToExecute(.create)
        let execution = model.executeConfirmed(.create)
        model.enterBackground()
        await execution?.value

        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .create)
        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertEqual(model.history.first?.notAttempted, 0)
        // Only the pending UPDATE survives, and it needs a fresh Preview (#73).
        XCTAssertEqual(model.sourceText, "## manning\nn. 人员配置")
        XCTAssertFalse(model.hasExecutablePreview)
    }

    func testRehearsalHarnessStopsDeterministicallyOnBackgroundTimeExpiry() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel.makeRehearsal(
            perRequestDelaySeconds: 0,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        await model.enterForeground()
        model.sourceText = "collapse\nn. 崩塌\nledger\nn. 分类账"
        await model.previewCurrentInput()
        XCTAssertEqual(model.preview?.counts.create, 2)
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        assertion.expire()
        await execution?.value

        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(model.finalSummary.created, 0)
        XCTAssertEqual(model.finalSummary.notAttempted, 2)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.notAttempted, .notAttempted])
    }

    // MARK: - Helpers

    /// Runs a real `WriteExecutor` and returns every stage it reported, in order.
    private func recordedStages(
        document: String,
        spellings: [String]
    ) async throws -> [ExecutionStage] {
        let results = previewRun(spellings)
        let (shown, _, _) = try await makeSnapshot(document: document, results: results)
        let transport = FakeHTTPTransport(
            results + spellings.enumerated().flatMap { index, _ in
                [
                    jsonResponse([:], status: 201),
                    interpretationsResponse([
                        interpretation("INVALID_RECORD_\(index)", proposedText(document, index)),
                    ]),
                ]
            }
        )
        let lease = try credentialLease()
        defer { lease.clear() }
        let recorder = StageRecorder()
        _ = await WriteExecutor(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).execute(
            group: .create,
            displayedSnapshot: shown,
            approval: try ConfirmationBinding.makeApproval(snapshot: shown, group: .create),
            control: ExecutionControl(),
            progress: ExecutionProgressReporter { recorder.record($0) }
        )
        return recorder.stages
    }

    private func proposedText(_ document: String, _ index: Int) -> String {
        let lines = document.split(separator: "\n").map(String.init)
        return lines[index * 2 + 1]
    }

    /// One batch vocabulary resolution, then one interpretation read per entry.
    private func previewRun(_ spellings: [String]) -> [StubbedResult] {
        [
            vocabularyQueryResponse(
                spellings.enumerated().map {
                    (id: "INVALID_VOC_\($0.offset)", spelling: $0.element)
                }
            ),
        ] + spellings.map { _ in interpretationsResponse([]) }
    }

    private func waitForStage(
        _ model: CompanionViewModel,
        _ expected: ExecutionStage,
        iterations: Int = 500
    ) async -> Bool {
        for _ in 0..<iterations {
            if model.executionStage == expected { return true }
            await Task.yield()
        }
        return false
    }

    private func connectedModel(
        _ factory: SequencedTransportFactory,
        historyStore: HistoryStore = InMemoryHistoryStore(),
        assertion: FakeBackgroundExecutionAssertion? = nil
    ) -> CompanionViewModel {
        let assertion = assertion ?? FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: historyStore,
            transportFactory: factory.make,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        return model
    }

    private func connectedModel(
        transports: [HTTPTransport],
        historyStore: HistoryStore = InMemoryHistoryStore(),
        assertion: FakeBackgroundExecutionAssertion? = nil
    ) -> CompanionViewModel {
        let assertion = assertion ?? FakeBackgroundExecutionAssertion()
        var remaining = transports
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: historyStore,
            transportFactory: { remaining.removeFirst() },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        return model
    }
}
