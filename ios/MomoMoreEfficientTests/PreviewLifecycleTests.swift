import XCTest
@testable import MomoMoreEfficient

/// #78: an already-started read-only Preview must survive ordinary short app
/// switching, `.inactive`/`.background` and call interruptions, without weakening
/// any write-authorization invariant.
@MainActor
final class PreviewLifecycleTests: XCTestCase {

    // MARK: - Background no longer discards an in-flight Preview

    func testBackgroundDuringActivePreviewDoesNotCancelIt() async {
        let transport = FakeHTTPTransport(previewRun(["one", "two"]))
        let gate = FirstPauseGateSleeper()
        let assertion = FakeBackgroundExecutionAssertion()
        let model = connectedModel(transport: transport, sleeper: gate, assertion: assertion)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        // The exact scene transition that used to throw the read work away.
        model.enterBackground()
        await gate.resume()
        await preview.value

        // Every entry was read: nothing restarted from item 1.
        XCTAssertEqual(transport.readCount, 3, "one batch resolution + two content reads")
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertEqual(model.preview?.rows.count, 2)
        XCTAssertNil(model.errorMessage)
    }

    func testPreviewCompletesAcrossBackgroundAndForegroundWithoutRestarting() async {
        let transport = FakeHTTPTransport(previewRun(["one", "two"]))
        let gate = FirstPauseGateSleeper()
        let assertion = FakeBackgroundExecutionAssertion()
        let model = connectedModel(transport: transport, sleeper: gate, assertion: assertion)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await model.enterForeground()
        await gate.resume()
        await preview.value

        XCTAssertEqual(transport.readCount, 3, "one batch resolution + two content reads")
        XCTAssertEqual(model.preview?.rows.count, 2)
        // Returning before it finished means no teardown was ever owed.
        XCTAssertTrue(model.isConnected)
        XCTAssertTrue(model.hasExecutablePreview)
        XCTAssertFalse(model.isPreviewStale)
    }

    func testForegroundReturnDoesNotStartADuplicatePreview() async {
        let transport = FakeHTTPTransport(previewRun(["one"]))
        let gate = FirstPauseGateSleeper()
        let assertion = FakeBackgroundExecutionAssertion()
        let model = connectedModel(transport: transport, sleeper: gate, assertion: assertion)
        model.sourceText = "one\nn. 一"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await model.enterForeground()
        // A second call while one is in flight must be refused outright.
        await model.previewCurrentInput()
        XCTAssertEqual(assertion.beginCount, 1)
        await gate.resume()
        await preview.value

        // Exactly one entry's worth of reads, and one assertion taken and released.
        XCTAssertEqual(transport.readCount, 2)
        XCTAssertEqual(assertion.beginCount, 1)
        XCTAssertEqual(assertion.endCount, 1)
    }

    func testRepeatedInactiveActiveChurnDuringPreviewDoesNotCancelIt() async {
        let transport = FakeHTTPTransport(previewRun(["one", "two"]))
        let gate = FirstPauseGateSleeper()
        let model = connectedModel(transport: transport, sleeper: gate)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await model.enterForeground()
        model.enterBackground()
        await model.enterForeground()
        await gate.resume()
        await preview.value

        XCTAssertEqual(transport.readCount, 3, "one batch resolution + two content reads")
        XCTAssertEqual(model.preview?.rows.count, 2)
        XCTAssertNil(model.errorMessage)
    }

    // MARK: - A Preview that finishes while away is revalidated, not re-read

    func testPreviewCompletedWhileAwayIsRestoredWhenSourceAndCredentialStillMatch() async {
        let transport = FakeHTTPTransport(previewRun(["one"]))
        let gate = FirstPauseGateSleeper()
        let store = FakeTokenStore()
        let model = connectedModel(transport: transport, sleeper: gate, tokenStore: store)
        model.sourceText = "one\nn. 一"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await preview.value

        // Finished while away: the read result is held, but is not executable and
        // the transient credential really was dropped.
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertTrue(model.isPreviewStale)
        XCTAssertNil(model.executeConfirmed(.create))

        await model.enterForeground()

        // Same document, same stored token: usable without re-reading anything.
        XCTAssertTrue(model.isConnected)
        XCTAssertTrue(model.hasExecutablePreview)
        XCTAssertFalse(model.isPreviewStale)
        XCTAssertEqual(model.preview?.rows.count, 1)
        XCTAssertEqual(model.executionActions.map(\.title), ["新建 1", "更新 0"])
        // Crucially: no second network Preview was needed.
        XCTAssertEqual(transport.readCount, 2)
    }

    func testPreviewCompletedWhileAwayIsDiscardedWhenSourceChanged() async {
        let transport = FakeHTTPTransport(previewRun(["one"]))
        let gate = FirstPauseGateSleeper()
        let model = connectedModel(transport: transport, sleeper: gate)
        model.sourceText = "one\nn. 一"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await preview.value

        model.sourceText = "one\nn. 改过的释义"
        await model.enterForeground()

        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.executeConfirmed(.create))
        XCTAssertEqual(transport.postCount, 0)
    }

    func testPreviewCompletedWhileAwayIsDiscardedWhenCredentialChanged() async {
        let transport = FakeHTTPTransport(previewRun(["one"]))
        let gate = FirstPauseGateSleeper()
        let store = FakeTokenStore()
        let model = connectedModel(transport: transport, sleeper: gate, tokenStore: store)
        model.sourceText = "one\nn. 一"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await preview.value

        // A different token is now the stored one, so the fingerprint cannot match.
        var replacement = "FAKE_REPLACEMENT_TOKEN_NOT_VALID"
        model.installVerifiedCredentialForTesting(token: &replacement)
        await model.enterForeground()

        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertFalse(model.isPreviewStale)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.executeConfirmed(.create))
        XCTAssertTrue(replacement.isEmpty)
    }

    func testRemovingTokenDiscardsAPreviewHeldAcrossAnInterruption() async {
        let transport = FakeHTTPTransport(previewRun(["one"]))
        let gate = FirstPauseGateSleeper()
        let store = FakeTokenStore()
        let model = connectedModel(transport: transport, sleeper: gate, tokenStore: store)
        model.sourceText = "one\nn. 一"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await preview.value

        model.removeToken()
        await model.enterForeground()

        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.preview)
        XCTAssertFalse(store.hasStoredToken)
    }

    // MARK: - Expiry stops cleanly

    func testBackgroundTimeExpiryLeavesNoStuckBusyOrPreviewingState() async {
        let transport = FakeHTTPTransport(previewRun(["one", "two"]))
        let gate = FirstPauseGateSleeper()
        let assertion = FakeBackgroundExecutionAssertion()
        let model = connectedModel(transport: transport, sleeper: gate, assertion: assertion)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        assertion.expire()
        await gate.resume()
        await preview.value

        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isPreviewing)
        XCTAssertNil(model.previewProgress)
        XCTAssertNil(model.previewProgressLabel)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertEqual(model.errorMessage, "预览被系统中断；未写入任何数据，可重新预览。")
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertEqual(assertion.endCount, 1)
    }

    func testInterruptedPreviewDoesNotRestartByItselfAndCanBeRetriedManually() async {
        let firstTransport = FakeHTTPTransport(previewRun(["one"]))
        let secondTransport = FakeHTTPTransport(previewRun(["one"]))
        var remaining: [HTTPTransport] = [firstTransport, secondTransport]
        let gate = FirstPauseGateSleeper()
        // Only the first run is gated; the retry must not block on a spent gate.
        var sleepers: [RequestSleeper] = [gate]
        let assertion = FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { remaining.removeFirst() },
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { sleepers.isEmpty ? RecordingSleeper() : sleepers.removeFirst() },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        model.sourceText = "one\nn. 一"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        assertion.expire()
        await gate.resume()
        await preview.value

        // Returning to the app must not silently re-run it.
        await model.enterForeground()
        XCTAssertNil(model.preview)
        XCTAssertEqual(secondTransport.readCount, 0)

        // Only an explicit Preview does.
        await model.previewCurrentInput()
        XCTAssertEqual(secondTransport.readCount, 2)
        XCTAssertNotNil(model.preview)
        XCTAssertTrue(model.hasExecutablePreview)
    }

    // MARK: - Read progress

    func testPreviewReportsPerEntryReadProgress() async {
        let transport = FakeHTTPTransport(previewRun(["one", "two"]))
        let gate = FirstPauseGateSleeper()
        let model = connectedModel(transport: transport, sleeper: gate)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        let reached = await waitForPreviewProgress(model, PreviewProgress(entry: 1, total: 2))
        XCTAssertTrue(reached, "expected 1/2, got \(String(describing: model.previewProgress))")
        XCTAssertEqual(model.previewProgressLabel, "正在预览 1/2")

        await gate.resume()
        await preview.value

        // Cleared once the read resolves.
        XCTAssertNil(model.previewProgress)
        XCTAssertNil(model.previewProgressLabel)
    }

    func testPreviewProgressCarriesNoCredentialOrIdentifierMaterial() async {
        let transport = FakeHTTPTransport(previewRun(["one", "two"]))
        let gate = FirstPauseGateSleeper()
        let model = connectedModel(transport: transport, sleeper: gate)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        _ = await waitForPreviewProgress(model, PreviewProgress(entry: 1, total: 2))

        let rendered = String(describing: model.previewProgress)
            + (model.previewProgressLabel ?? "")
        XCTAssertFalse(rendered.contains(fakeToken))
        XCTAssertFalse(rendered.contains("INVALID_VOC"))

        await gate.resume()
        await preview.value
    }

    // MARK: - The write gate is untouched

    func testExecutionStillRunsItsOwnFreshPreflightAfterAnInterruptedPreview() async {
        // Preview finishes while away, is revalidated on return, and is executed.
        let previewTransport = FakeHTTPTransport(previewRun(["one"]))
        let executionTransport = FakeHTTPTransport(
            previewRun(["one"]) + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
            ]
        )
        var remaining: [HTTPTransport] = [previewTransport, executionTransport]
        let gate = FirstPauseGateSleeper()
        // Only the Preview is gated; execution must run to completion unblocked.
        var sleepers: [RequestSleeper] = [gate]
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { remaining.removeFirst() },
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { sleepers.isEmpty ? RecordingSleeper() : sleepers.removeFirst() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        model.sourceText = "one\nn. 一"

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await preview.value
        await model.enterForeground()
        XCTAssertTrue(model.hasExecutablePreview)

        model.askToExecute(.create)
        await model.executeConfirmed(.create)?.value

        // The execution-time preflight re-read the entry before its single POST:
        // 2 preflight GETs + 1 POST + 1 readback GET.
        XCTAssertEqual(executionTransport.readCount, 3)
        XCTAssertEqual(executionTransport.postCount, 1)
        XCTAssertEqual(model.history.first?.succeeded, 1)
    }

    func testAPreviewHeldAcrossAnInterruptionCarriesNoArmedApproval() async {
        let transport = FakeHTTPTransport(previewRun(["one"]))
        let gate = FirstPauseGateSleeper()
        let model = connectedModel(transport: transport, sleeper: gate)
        model.sourceText = "one\nn. 一"
        model.askToExecute(.create)

        let preview = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await preview.value
        await model.enterForeground()

        // Restoring read state never revives an approval; one must be armed again.
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertNil(model.executeConfirmed(.create))
        XCTAssertEqual(transport.postCount, 0)
    }

    // MARK: - Rehearsal

    func testRehearsalPreviewSurvivesABackgroundInterruption() async {
        let gate = FirstPauseGateSleeper()
        let model = CompanionViewModel.makeRehearsal(
            perRequestDelaySeconds: 0,
            sleeperFactory: { gate },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        await model.enterForeground()
        model.sourceText = "collapse\nn. 崩塌\nledger\nn. 分类账\nmanning\nn. 人员配置"

        let preview = Task { await model.previewCurrentInput() }
        // Interrupt only once the read is genuinely under way.
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await preview.value
        await model.enterForeground()

        // All three entries read once, classified, and usable on return.
        XCTAssertEqual(model.preview?.rows.count, 3)
        XCTAssertEqual(model.preview?.counts.create, 2)
        XCTAssertEqual(model.preview?.counts.update, 1)
        XCTAssertTrue(model.hasExecutablePreview)
        XCTAssertFalse(model.isPreviewStale)
    }

    // MARK: - Helpers

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

    private func waitForPreviewProgress(
        _ model: CompanionViewModel,
        _ expected: PreviewProgress,
        iterations: Int = 500
    ) async -> Bool {
        for _ in 0..<iterations {
            if model.previewProgress == expected { return true }
            await Task.yield()
        }
        return false
    }

    private func connectedModel(
        transport: HTTPTransport,
        sleeper: RequestSleeper,
        tokenStore: FakeTokenStore = FakeTokenStore(),
        assertion: FakeBackgroundExecutionAssertion? = nil
    ) -> CompanionViewModel {
        let assertion = assertion ?? FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: tokenStore,
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { sleeper },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        XCTAssertTrue(draft.isEmpty)
        return model
    }
}
