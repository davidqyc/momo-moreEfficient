import Foundation
import XCTest
@testable import MomoMoreEfficient

@MainActor
final class PhraseUIIntegrationTests: XCTestCase {
    func testPhraseGlobalFailuresAbortPreviewWithoutFabricatedRows() async {
        let cases: [(StubbedResult, CompanionError, Bool)] = [
            (jsonResponse(["error": "auth"], status: 401), .authenticationRejected, false),
            (.failure(.transport), .transport, true),
            (jsonResponse(["error": "rate"], status: 429), .rateLimited, true),
            (jsonResponse(["error": "server"], status: 503), .serverFailure, true),
            (jsonResponse(["unexpected": []]), .responseRejected, true),
        ]
        for (failure, expectedError, remainsConnected) in cases {
            let transport = FakeHTTPTransport([failure])
            let model = connectedModel(transports: [transport])
            model.selectMode(.phrase)
            model.sourceText = phraseDocument

            await model.previewCurrentInput()

            XCTAssertNil(model.phrasePreview)
            XCTAssertFalse(model.hasExecutablePreview)
            XCTAssertEqual(model.errorMessage, expectedError.description)
            XCTAssertEqual(model.isConnected, remainsConnected)
            XCTAssertEqual(transport.readCount, 1)
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    func testPhraseAuthRejectionDuringFreshWritePreflightDisconnectsBeforePOST() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phraseResponse([])],
            [jsonResponse(["error": "auth"], status: 401)],
        ])
        let model = connectedModel(factory: factory)
        model.selectMode(.phrase)
        model.sourceText = phraseDocument
        await model.previewCurrentInput()
        model.askToExecutePhrase()

        await model.executeConfirmedPhrase()?.value

        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.errorMessage, CompanionError.authenticationRejected.description)
        XCTAssertNil(model.phrasePreview)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(model.sourceText, phraseDocument)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
    }

    func testPhraseAuthRejectionDuringReadbackDisconnectsAndRecordsUnknownWrite() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phraseResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phraseResponse([]),
                jsonResponse([:], status: 201),
                jsonResponse(["error": "auth"], status: 401),
            ],
        ])
        let model = connectedModel(factory: factory)
        model.selectMode(.phrase)
        model.sourceText = phraseDocument
        await model.previewCurrentInput()
        model.askToExecutePhrase()

        await model.executeConfirmedPhrase()?.value

        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(
            model.errorMessage,
            CompanionError.authenticationRejected.description + "\n"
                + CompanionError.uncertainWriteOutcome.description
        )
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.notVerified])
        XCTAssertEqual(model.sourceText, phraseDocument)
    }

    func testDefaultModeSeparateDraftsAndSwitchInvalidatesAuthority() async {
        let model = CompanionViewModel.makeRehearsal(
            perRequestDelaySeconds: 0,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        await model.enterForeground()
        XCTAssertEqual(model.contentMode, .interpretation)

        model.sourceText = "word\nn. 释义草稿"
        await model.previewCurrentInput()
        XCTAssertTrue(model.hasExecutablePreview)
        model.askToExecute(.create)
        XCTAssertEqual(model.pendingConfirmation, .create)

        model.selectMode(.phrase)
        XCTAssertEqual(model.contentMode, .phrase)
        XCTAssertEqual(model.sourceText, "")
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertFalse(model.hasExecutablePreview)

        model.sourceText = phraseDocument
        model.selectMode(.interpretation)
        XCTAssertEqual(model.sourceText, "word\nn. 释义草稿")
        model.selectMode(.phrase)
        XCTAssertEqual(model.sourceText, phraseDocument)
        XCTAssertFalse(model.hasExecutablePreview, "switching back must not revive old authority")
    }

    func testModeSwitchIsDisabledWhilePreviewIsBusy() async {
        let gate = FirstPauseGateSleeper()
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
            phraseResponse([]),
        ])
        let model = connectedModel(
            transports: [transport],
            sleeperFactory: { gate }
        )
        model.selectMode(.phrase)
        model.sourceText = phraseDocument

        let task = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        XCTAssertTrue(model.isBusy)
        XCTAssertFalse(model.canSwitchMode)

        model.selectMode(.interpretation)
        XCTAssertEqual(model.contentMode, .phrase)

        await gate.resume()
        await task.value
    }

    func testPhrasePreviewShowsSafeCreateMatchingAndBlockedRows() async {
        let document = phraseDocument + """


        ## liquidity
        EN: Liquidity matters.
        ZH: 流动性很重要。
        SOURCE: 自编

        ## covenant
        EN: The covenant protects lenders.
        ZH: 该契约保护贷款人。
        SOURCE: 自编
        """
        let unrelated = phraseRecord(
            id: "INVALID_UNRELATED",
            english: "A completely unrelated sentence.",
            chinese: "无关句子。"
        )
        let matching = phraseRecord(
            id: "INVALID_MATCHING",
            english: "Liquidity matters.",
            chinese: "流动性很重要。",
            tags: ["MBA"],
            highlight: nil
        )
        let conflict = phraseRecord(
            id: "INVALID_CONFLICT",
            english: "The covenant protects lenders.",
            chinese: "冲突翻译。"
        )
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "acquisition"), (id: "INVALID_VOC_B", spelling: "liquidity"), (id: "INVALID_VOC_C", spelling: "covenant")]), phraseResponse([unrelated]),
            phraseResponse([matching]),
            phraseResponse([conflict]),
        ])
        let model = connectedModel(transports: [transport])
        model.selectMode(.phrase)
        model.sourceText = document

        await model.previewCurrentInput()

        XCTAssertEqual(model.phrasePreview?.createCount, 1)
        XCTAssertEqual(model.phrasePreview?.alreadyMatchingCount, 1)
        XCTAssertEqual(model.phrasePreview?.blockedCount, 1)
        XCTAssertEqual(
            model.phrasePreview?.rows[2].blockedReason,
            "相同英文已存在，但中文或来源不一致"
        )
        XCTAssertEqual(
            model.phrasePreview?.rows[1].observations,
            [.tagsDiffer, .highlightMissing, .chineseRangeUnavailable]
        )
        XCTAssertFalse(model.canExecutePhrase)

        let rendered = String(describing: model.phrasePreview)
        for forbidden in [fakeToken, "INVALID_VOC", "INVALID_MATCHING", "INVALID_CONFLICT"] {
            XCTAssertFalse(rendered.contains(forbidden), forbidden)
        }
    }

    func testPhraseRehearsalRunsParserApprovalCreateReadbackAndPreservesInterpretationDraft() async {
        let history = RehearsalHistoryStore()
        let model = CompanionViewModel(
            tokenStore: RehearsalTokenStore(),
            historyStore: history,
            transportFactory: { RehearsalTransport(perRequestDelaySeconds: 0) },
            credentialValidationTransportFactory: {
                RehearsalTransport(perRequestDelaySeconds: 0)
            },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        await model.enterForeground()
        model.sourceText = "word\nn. 释义草稿"
        model.selectMode(.phrase)
        model.sourceText = phraseDocument

        await model.previewCurrentInput()
        XCTAssertEqual(model.phrasePreview?.createCount, 1)
        XCTAssertTrue(model.canExecutePhrase)

        model.askToExecutePhrase()
        XCTAssertEqual(model.pendingPhraseConfirmation?.spellings, ["acquisition"])
        XCTAssertEqual(model.pendingPhraseConfirmation?.count, 1)
        await model.executeConfirmedPhrase()?.value

        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.completionAcknowledgement, "已完成 1 条例句 · 新建 1")
        XCTAssertNotNil(model.phraseObservationMessage)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history[0].contentKind, .phrase)
        XCTAssertEqual(model.history[0].operationGroup, .create)
        XCTAssertTrue(model.history[0].isFullSuccess)
        XCTAssertEqual(try history.loadReceipts(), model.history)

        model.selectMode(.interpretation)
        XCTAssertEqual(model.sourceText, "word\nn. 释义草稿")
    }

    func testPhraseFailurePreservesWholeDraftAndRequiresFreshPreview() async {
        let twoEntries = phraseDocument + """


        ## liquidity
        EN: Liquidity matters.
        ZH: 流动性很重要。
        SOURCE: 自编
        """
        let preview: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "acquisition"), (id: "INVALID_VOC_B", spelling: "liquidity")]), phraseResponse([]),
            phraseResponse([]),
        ]
        let badReadback = phraseRecord(
            id: "INVALID_RECORD",
            english: english,
            chinese: chinese,
            source: "错误来源"
        )
        let factory = SequencedTransportFactory([
            preview,
            preview + [jsonResponse([:], status: 201), phraseResponse([badReadback])],
        ])
        let model = connectedModel(factory: factory)
        model.selectMode(.phrase)
        model.sourceText = twoEntries
        await model.previewCurrentInput()
        model.askToExecutePhrase()

        await model.executeConfirmedPhrase()?.value

        XCTAssertEqual(model.sourceText, twoEntries)
        XCTAssertNil(model.phrasePreview)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertEqual(model.history.first?.contentKind, .phrase)
        XCTAssertEqual(model.history.first?.failed, 0)
        XCTAssertEqual(model.history.first?.unconfirmed, 1)
        XCTAssertEqual(model.history.first?.notAttempted, 1)
        XCTAssertEqual(factory.transports.last?.postCount, 1)
    }

    func testUncertainPhrasePOSTUsesReadbackOnlyAndCanRecover() async {
        let exact = phraseRecord(
            id: "INVALID_RECORD",
            english: english,
            chinese: chinese
        )
        let preview: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phraseResponse([]),
        ]
        let factory = SequencedTransportFactory([
            preview,
            preview + [.failure(.transport), phraseResponse([exact])],
        ])
        let model = connectedModel(factory: factory)
        model.selectMode(.phrase)
        model.sourceText = phraseDocument
        await model.previewCurrentInput()
        model.askToExecutePhrase()

        await model.executeConfirmedPhrase()?.value

        XCTAssertEqual(factory.transports.last?.postCount, 1)
        XCTAssertEqual(
            factory.transports.last?.requests.suffix(2).map(\.route.isMutating),
            [true, false]
        )
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.recovered])
        XCTAssertTrue(model.history.first?.isFullSuccess == true)
        XCTAssertEqual(model.sourceText, "")
    }

    func testInterruptionAfterFinalPOSTKeepsDraftEvenWhenReadbackConfirms() async {
        let assertion = FakeBackgroundExecutionAssertion()
        let exact = phraseRecord(
            id: "INVALID_RECORD",
            english: english,
            chinese: chinese
        )
        let preview: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phraseResponse([]),
        ]
        let executionTransport = ExpiringPhrasePOSTTransport(
            results: preview + [jsonResponse([:], status: 201), phraseResponse([exact])]
        ) {
            await MainActor.run { assertion.expire() }
        }
        var transports: [HTTPTransport] = [FakeHTTPTransport(preview), executionTransport]
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transports.removeFirst() },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        model.selectMode(.phrase)
        model.sourceText = phraseDocument
        await model.previewCurrentInput()
        model.askToExecutePhrase()

        await model.executeConfirmedPhrase()?.value

        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertEqual(model.history.first?.contentKind, .phrase)
        XCTAssertTrue(model.history.first?.stopped == true)
        XCTAssertFalse(model.history.first?.isFullSuccess == true)
        XCTAssertEqual(model.sourceText, phraseDocument)
        XCTAssertNil(model.phrasePreview)
        XCTAssertFalse(model.hasExecutablePreview)
    }

    func testMixedPhraseObservationsExposePositiveAndNegativeStatesWithoutAffectingSuccess() async {
        let secondEnglish = "Liquidity matters."
        let secondChinese = "流动性很重要。"
        let twoEntries = phraseDocument + """


        ## liquidity
        EN: \(secondEnglish)
        ZH: \(secondChinese)
        SOURCE: 自编
        """
        let preview: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "acquisition"), (id: "INVALID_VOC_B", spelling: "liquidity")]), phraseResponse([]),
            phraseResponse([]),
        ]
        let positive = phraseRecord(
            id: "INVALID_POSITIVE",
            english: english,
            chinese: chinese,
            highlight: [[4, 15]]
        )
        let negative = phraseRecord(
            id: "INVALID_NEGATIVE",
            english: secondEnglish,
            chinese: secondChinese,
            tags: ["MBA"],
            highlight: nil
        )
        let factory = SequencedTransportFactory([
            preview,
            preview + [
                jsonResponse([:], status: 201), phraseResponse([positive]),
                jsonResponse([:], status: 201), phraseResponse([negative]),
            ],
        ])
        let model = connectedModel(factory: factory)
        model.selectMode(.phrase)
        model.sourceText = twoEntries
        await model.previewCurrentInput()
        model.askToExecutePhrase()

        await model.executeConfirmedPhrase()?.value

        XCTAssertEqual(
            model.phraseObservationMessage,
            "标签与请求不同 · 标签已匹配 · 英文高亮未返回 · 英文高亮准确 · 中文范围在 documented API 中不可用"
        )
        XCTAssertFalse(model.phraseObservationMessage?.contains("4, 15") == true)
        XCTAssertTrue(model.history.first?.isFullSuccess == true)
        XCTAssertEqual(model.sourceText, "")
    }

    func testPhraseProgressComesFromTheExecutorWriteStage() async {
        let exact = phraseRecord(
            id: "INVALID_RECORD",
            english: english,
            chinese: chinese
        )
        let preview: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phraseResponse([]),
        ]
        let executionTransport = PausingPOSTTransport(
            preview + [jsonResponse([:], status: 201), phraseResponse([exact])]
        )
        let model = connectedModel(
            transports: [FakeHTTPTransport(preview), executionTransport]
        )
        model.selectMode(.phrase)
        model.sourceText = phraseDocument
        await model.previewCurrentInput()
        model.askToExecutePhrase()

        let execution = model.executeConfirmedPhrase()
        XCTAssertEqual(model.executionStage, .securing)
        await executionTransport.waitUntilPOSTDispatched()
        let reached = await waitForStage(
            model,
            .writing(group: .create, item: 1, total: 1, spelling: "acquisition")
        )
        XCTAssertTrue(reached)
        XCTAssertEqual(model.executionProgressLabel, "正在新建 1/1 · acquisition")

        await executionTransport.resumePOST()
        await execution?.value
        XCTAssertNil(model.executionProgressLabel)
    }

    func testPhrasePreviewBackgroundRestoreRequiresModeDraftAndCredential() async {
        let gate = FirstPauseGateSleeper()
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phraseResponse([]),
        ])
        let model = connectedModel(
            transports: [transport],
            sleeperFactory: { gate }
        )
        model.selectMode(.phrase)
        model.sourceText = phraseDocument

        let task = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await task.value

        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(model.isPreviewStale)
        XCTAssertFalse(model.hasExecutablePreview)

        await model.enterForeground()
        XCTAssertTrue(model.isConnected)
        XCTAssertFalse(model.isPreviewStale)
        XCTAssertTrue(model.hasExecutablePreview)
        XCTAssertEqual(model.contentMode, .phrase)
    }

    func testArmedPhraseApprovalCannotSurviveDraftEdit() async {
        let model = CompanionViewModel.makeRehearsal(
            perRequestDelaySeconds: 0,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        await model.enterForeground()
        model.selectMode(.phrase)
        model.sourceText = phraseDocument
        await model.previewCurrentInput()
        model.askToExecutePhrase()
        XCTAssertNotNil(model.pendingPhraseConfirmation)

        model.sourceText += " "

        XCTAssertNil(model.pendingPhraseConfirmation)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.executeConfirmedPhrase())
        XCTAssertEqual(model.errorMessage, CompanionError.approvalRequired.description)
    }

    private var english: String {
        "The acquisition strengthened the company's position in the market."
    }

    private var chinese: String { "这次收购加强了公司在市场中的地位。" }

    private var phraseDocument: String {
        """
        ## acquisition
        EN: \(english)
        ZH: \(chinese)
        SOURCE: 自编
        """
    }

    private func phraseRecord(
        id: String,
        english: String,
        chinese: String,
        tags: Any? = [String](),
        source: String = "自编",
        status: String = "PUBLISHED",
        highlight: Any? = []
    ) -> [String: Any] {
        var record: [String: Any] = [
            "id": id,
            "phrase": english,
            "interpretation": chinese,
            "origin": source,
            "status": status,
        ]
        if let tags { record["tags"] = tags }
        if let highlight { record["highlight"] = highlight }
        return record
    }

    private func phraseResponse(_ records: [[String: Any]]) -> StubbedResult {
        jsonResponse(["phrases": records])
    }

    private func connectedModel(
        transports: [HTTPTransport],
        sleeperFactory: @escaping () -> RequestSleeper = { RecordingSleeper() }
    ) -> CompanionViewModel {
        var remaining = transports
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { remaining.removeFirst() },
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: sleeperFactory,
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        return model
    }

    private func connectedModel(factory: SequencedTransportFactory) -> CompanionViewModel {
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: factory.make,
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        return model
    }

    private func waitForStage(
        _ model: CompanionViewModel,
        _ expected: ExecutionStage
    ) async -> Bool {
        for _ in 0..<100 {
            if model.executionStage == expected { return true }
            await Task.yield()
        }
        return model.executionStage == expected
    }
}

private final class ExpiringPhrasePOSTTransport: HTTPTransport, @unchecked Sendable {
    private let base: FakeHTTPTransport
    private let onPhrasePOST: @Sendable () async -> Void

    init(
        results: [StubbedResult],
        onPhrasePOST: @escaping @Sendable () async -> Void
    ) {
        base = FakeHTTPTransport(results)
        self.onPhrasePOST = onPhrasePOST
    }

    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse {
        if request.route == .createPhrase { await onPhrasePOST() }
        return try await base.send(request, credential: credential)
    }
}
