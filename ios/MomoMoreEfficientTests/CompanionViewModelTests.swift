import XCTest
@testable import MomoMoreEfficient

@MainActor
final class CompanionViewModelTests: XCTestCase {
    func testInputEditImmediatelyInvalidatesPreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        XCTAssertNotNil(model.preview)
        model.sourceText += "。"
        XCTAssertNil(model.preview)
    }

    func testCredentialChangeImmediatelyInvalidatesPreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        XCTAssertNotNil(model.preview)
        var replacement = "FAKE_REPLACEMENT_TOKEN_NOT_VALID"
        model.connect(token: &replacement)
        XCTAssertNil(model.preview)
        XCTAssertTrue(replacement.isEmpty)
    }

    func testBackgroundClearsCredentialAndPreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        model.enterBackground()
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testBackgroundCancelsPreviewBeforeItsNextGET() async {
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"),
            interpretationsResponse([]),
        ])
        let gate = GateSleeper()
        let model = CompanionViewModel(
            transportFactory: { transport },
            sleeperFactory: { gate }
        )
        var draft = fakeToken
        model.connect(token: &draft)
        model.sourceText = "word\nn. 新建"

        let previewTask = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await previewTask.value

        XCTAssertEqual(transport.getCount, 1)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
    }

    func testExplicitDisconnectDoesTheSameImmediately() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        model.disconnect()
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testCompletedCreateInvalidatesExecutablePreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
            [
                vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        XCTAssertNotNil(model.preview)
        model.askToExecute(.create)
        let execution = model.executeConfirmed(.create)
        await execution?.value
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.finalSummary.created, 1)
    }

    func testDirectConfirmedExecutionWithoutArmedIntentSendsZeroPOST() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()

        let execution = model.executeConfirmed(.create)

        XCTAssertNil(execution)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertEqual(model.finalSummary.created, 0)
    }

    func testArmedCreateCannotAuthorizeUpdate() async {
        let old = interpretation("INVALID_RECORD", "n. 旧", tags: ["考研"])
        let factory = SequencedTransportFactory([
            [
                vocabularyResponse("INVALID_VOC_A", "create"), interpretationsResponse([]),
                vocabularyResponse("INVALID_VOC_B", "update"), interpretationsResponse([old]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "create\nn. 新建\nupdate\nn. 新"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.update)

        XCTAssertNil(execution)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testCancelledConfirmationCannotAuthorizeExecution() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        model.cancelPendingConfirmation()

        let execution = model.executeConfirmed(.create)

        XCTAssertNil(execution)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertEqual(model.finalSummary.created, 0)
    }

    func testConsumedApprovalCannotBeReplayed() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
            [
                vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        let execution = model.executeConfirmed(.create)
        await execution?.value

        let replay = model.executeConfirmed(.create)

        XCTAssertNil(replay)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.finalSummary.created, 1)
    }

    func testArmedApprovalStillRequiresFreshMatchingPreflight() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
            [
                vocabularyResponse("INVALID_VOC", "word"),
                interpretationsResponse([
                    interpretation("INVALID_RECORD", "n. 现在存在", tags: ["考研"]),
                ]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        await execution?.value

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(factory.transports[1].getCount, 2)
        XCTAssertEqual(factory.transports[1].postCount, 0)
        XCTAssertEqual(model.errorMessage, CompanionError.stalePreview.description)
    }

    func testInputEditInvalidatesArmedApproval() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        model.sourceText += "。"

        let execution = model.executeConfirmed(.create)

        XCTAssertNil(execution)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testCredentialChangeInvalidatesArmedApprovalEvenForSameToken() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        var sameToken = fakeToken
        model.connect(token: &sameToken)

        let execution = model.executeConfirmed(.create)

        XCTAssertNil(execution)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testPartialCreateCancellationPreservesSuccessAndShowsNotAttempted() async {
        let oldPreviewResults: [StubbedResult] = [
            vocabularyResponse("INVALID_VOC_A", "one"), interpretationsResponse([]),
            vocabularyResponse("INVALID_VOC_B", "two"), interpretationsResponse([]),
        ]
        let previewTransport = FakeHTTPTransport(oldPreviewResults)
        let executionTransport = PausingPOSTTransport(oldPreviewResults + [
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
        ])
        let model = connectedModel(transports: [previewTransport, executionTransport])
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertNotNil(execution)
        await executionTransport.waitUntilPOSTDispatched()
        model.enterBackground()
        await executionTransport.resumePOST()
        await execution?.value

        let postCount = await executionTransport.postCount
        let getCount = await executionTransport.getCount
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(getCount, 5)
        XCTAssertEqual(model.finalSummary.created, 1)
        XCTAssertEqual(model.finalSummary.failed, 0)
        XCTAssertEqual(model.finalSummary.notAttempted, 1)
        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(
            model.finalSummary.stoppedMessage,
            "执行已停止：已完成 1 条，其余 1 条未执行。"
        )
    }

    func testBackgroundImmediatelyAfterNativeConfirmShowsAllItemsNotAttempted() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertNotNil(execution)
        model.enterBackground()
        await execution?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertEqual(model.finalSummary.created, 0)
        XCTAssertEqual(model.finalSummary.failed, 0)
        XCTAssertEqual(model.finalSummary.notAttempted, 1)
        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(
            model.finalSummary.stoppedMessage,
            "执行已停止：已完成 0 条，其余 1 条未执行。"
        )
    }

    func testPartialUpdateCancellationUsesSameStoppedPresentation() async {
        let oldA = interpretation("INVALID_RECORD_A", "n. 旧一", tags: ["考研"])
        let oldB = interpretation("INVALID_RECORD_B", "n. 旧二", tags: ["考研"])
        let previewResults: [StubbedResult] = [
            vocabularyResponse("INVALID_VOC_A", "one"), interpretationsResponse([oldA]),
            vocabularyResponse("INVALID_VOC_B", "two"), interpretationsResponse([oldB]),
        ]
        let previewTransport = FakeHTTPTransport(previewResults)
        let executionTransport = PausingPOSTTransport(previewResults + [
            jsonResponse([:]),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 新一")]),
        ])
        let model = connectedModel(transports: [previewTransport, executionTransport])
        model.sourceText = "one\nn. 新一\ntwo\nn. 新二"
        await model.previewCurrentInput()
        model.askToExecute(.update)

        let execution = model.executeConfirmed(.update)
        XCTAssertNotNil(execution)
        await executionTransport.waitUntilPOSTDispatched()
        model.enterBackground()
        await executionTransport.resumePOST()
        await execution?.value

        let postCount = await executionTransport.postCount
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(model.finalSummary.updated, 1)
        XCTAssertEqual(model.finalSummary.failed, 0)
        XCTAssertEqual(model.finalSummary.notAttempted, 1)
        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(
            model.finalSummary.stoppedMessage,
            "执行已停止：已完成 1 条，其余 1 条未执行。"
        )
    }

    func testPublicStateAndErrorsNeverExposeFakeToken() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        let rendered = String(describing: model.preview)
            + String(describing: model.finalSummary)
            + String(describing: model.errorMessage)
        XCTAssertFalse(rendered.contains(fakeToken))
    }

    private func connectedModel(_ factory: SequencedTransportFactory) -> CompanionViewModel {
        let model = CompanionViewModel(
            transportFactory: factory.make,
            sleeperFactory: { RecordingSleeper() }
        )
        var draft = fakeToken
        model.connect(token: &draft)
        XCTAssertTrue(draft.isEmpty)
        return model
    }

    private func connectedModel(transports: [HTTPTransport]) -> CompanionViewModel {
        var remaining = transports
        let model = CompanionViewModel(
            transportFactory: { remaining.removeFirst() },
            sleeperFactory: { RecordingSleeper() }
        )
        var draft = fakeToken
        model.connect(token: &draft)
        XCTAssertTrue(draft.isEmpty)
        return model
    }
}

private actor PausingPOSTTransport: HTTPTransport {
    private var results: [StubbedResult]
    private var requests: [TransportRequest] = []
    private var postWasDispatched = false
    private var postWaiters: [CheckedContinuation<Void, Never>] = []
    private var postContinuation: CheckedContinuation<Void, Never>?

    init(_ results: [StubbedResult]) {
        self.results = results
    }

    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse {
        requests.append(request)
        if request.route.method == .post {
            postWasDispatched = true
            postWaiters.forEach { $0.resume() }
            postWaiters.removeAll()
            await withCheckedContinuation { postContinuation = $0 }
        }
        guard !results.isEmpty else {
            XCTFail("unexpected pausing transport request")
            throw CompanionError.transport
        }
        switch results.removeFirst() {
        case let .response(response): return response
        case let .failure(error): throw error
        }
    }

    func waitUntilPOSTDispatched() async {
        if postWasDispatched { return }
        await withCheckedContinuation { postWaiters.append($0) }
    }

    func resumePOST() {
        postContinuation?.resume()
        postContinuation = nil
    }

    var postCount: Int { requests.filter { $0.route.method == .post }.count }
    var getCount: Int { requests.filter { $0.route.method == .get }.count }
}

final class SequencedTransportFactory: @unchecked Sendable {
    private var runs: [[StubbedResult]]
    private(set) var transports: [FakeHTTPTransport] = []

    init(_ runs: [[StubbedResult]]) {
        self.runs = runs
    }

    func make() -> HTTPTransport {
        guard !runs.isEmpty else { return FakeHTTPTransport([]) }
        let transport = FakeHTTPTransport(runs.removeFirst())
        transports.append(transport)
        return transport
    }
}
