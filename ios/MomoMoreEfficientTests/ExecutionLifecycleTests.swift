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
        model.enterForeground()
        model.enterBackground()
        model.enterForeground()
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

        model.enterForeground()

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
        XCTAssertEqual(assertion.beginCount, 0)
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertEqual(assertion.beginCount, 1)
        XCTAssertTrue(assertion.isHeld)
        await execution?.value

        XCTAssertEqual(assertion.endCount, 1)
        XCTAssertFalse(assertion.isHeld)
    }

    func testPreviewDoesNotTakeABackgroundAssertion() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([previewRun(["one"])])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = "one\nn. 一"

        await model.previewCurrentInput()

        XCTAssertEqual(assertion.beginCount, 0)
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
        XCTAssertEqual(
            model.executionStage,
            .preflight(group: .create, completed: 0, total: 2)
        )
        XCTAssertEqual(model.executionProgressLabel, "正在预检 1/2")

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
        XCTAssertEqual(
            ExecutionStage.preflight(group: .update, completed: 2, total: 2).label,
            "正在预检 2/2"
        )
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

    // MARK: - The DEBUG rehearsal harness the Owner runs on the device

    func testRehearsalModeIsOffUnlessExplicitlyLaunchedIntoIt() {
        // Nothing in a normal test/app launch opts in.
        XCTAssertFalse(RehearsalMode.isEnabled)
    }

    func testRehearsalHarnessDrivesTheRealPipelineToFullSuccessOffline() async {
        let transport = RehearsalTransport(perRequestDelaySeconds: 0)
        let assertion = FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: RehearsalTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
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
        let transport = RehearsalTransport(perRequestDelaySeconds: 0)
        let assertion = FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: RehearsalTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
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

    private func previewRun(_ spellings: [String]) -> [StubbedResult] {
        spellings.enumerated().flatMap { index, spelling in
            [
                vocabularyResponse("INVALID_VOC_\(index)", spelling),
                interpretationsResponse([]),
            ]
        }
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
        model.connect(token: &draft)
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
        model.connect(token: &draft)
        return model
    }
}
