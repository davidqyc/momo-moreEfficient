import Foundation
import XCTest
@testable import MomoMoreEfficient

@MainActor
final class CompanionViewModelTests: XCTestCase {
    func testCandidateMustPassAuthenticatedReadBeforeSaveOrConnected() async {
        let rejectedStore = FakeTokenStore()
        let rejectedTransport = FakeHTTPTransport([
            jsonResponse(["error": "unauthorized"], status: 401),
        ])
        let rejected = CompanionViewModel(
            tokenStore: rejectedStore,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { rejectedTransport },
            sleeperFactory: { RecordingSleeper() }
        )

        let rejectedResult = await rejected.connect(token: fakeToken)
        XCTAssertFalse(rejectedResult)
        XCTAssertFalse(rejected.isConnected)
        XCTAssertFalse(rejectedStore.hasStoredToken)
        XCTAssertEqual(rejectedStore.saveCount, 0)
        XCTAssertEqual(rejectedTransport.readCount, 1)
        XCTAssertEqual(rejectedTransport.postCount, 0)
        XCTAssertNotNil(rejected.tokenErrorMessage)

        let validStore = FakeTokenStore()
        let validTransport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let valid = CompanionViewModel(
            tokenStore: validStore,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { validTransport },
            sleeperFactory: { RecordingSleeper() }
        )

        let validResult = await valid.connect(token: "  \(fakeToken)\n")
        XCTAssertTrue(validResult)
        XCTAssertTrue(valid.isConnected)
        XCTAssertEqual(validStore.saveCount, 1)
        XCTAssertEqual(validStore.storedTokenForTesting, fakeToken)
        XCTAssertEqual(validTransport.requests.map(\.route), [.vocabulary(spelling: "apple")])
        XCTAssertEqual(validTransport.postCount, 0)
    }

    func testValidationInFlightExposesDismissLockAndCannotCommitBeforeResponse() async {
        let store = FakeTokenStore()
        let transport = GatedHTTPTransport(
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple")
        )
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )

        let connection = Task { await model.connect(token: fakeToken) }
        await transport.waitUntilRequested()

        XCTAssertTrue(model.isValidatingCredential)
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertFalse(store.hasStoredToken)

        await transport.resume()
        let connected = await connection.value
        XCTAssertTrue(connected)
        XCTAssertFalse(model.isValidatingCredential)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(store.saveCount, 1)
        let readCount = await transport.readCount
        let postCount = await transport.postCount
        XCTAssertEqual(readCount, 1)
        XCTAssertEqual(postCount, 0)
    }

    func testRejectedReplacementPreservesOldSessionKeychainAndForegroundFailureState() async {
        let store = FakeTokenStore()
        let rejectedTransport = FakeHTTPTransport([
            jsonResponse(["error": "unauthorized"], status: 401),
        ])
        let restoreTransport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        var validationTransports: [HTTPTransport] = [rejectedTransport, restoreTransport]
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { validationTransports.removeFirst() },
            sleeperFactory: { RecordingSleeper() }
        )
        var old = fakeToken
        model.installVerifiedCredentialForTesting(token: &old)
        let savedBefore = store.storedTokenForTesting

        let replacementResult = await model.connect(token: "FAKE_REJECTED_REPLACEMENT")
        XCTAssertFalse(replacementResult)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(store.storedTokenForTesting, savedBefore)
        XCTAssertEqual(store.saveCount, 1)
        let failureBefore = model.tokenErrorMessage

        model.enterBackground()
        XCTAssertFalse(model.isConnected)
        await model.enterForeground()

        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.tokenErrorMessage, failureBefore)
        XCTAssertEqual(store.storedTokenForTesting, savedBefore)
        XCTAssertEqual(rejectedTransport.postCount, 0)
        XCTAssertEqual(restoreTransport.readCount, 1)
        XCTAssertEqual(restoreTransport.postCount, 0)
    }

    func testValidReplacementIsValidatedBeforeAtomicSaveAndActivation() async {
        let store = FakeTokenStore()
        let validTransport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { validTransport },
            sleeperFactory: { RecordingSleeper() }
        )
        var old = fakeToken
        model.installVerifiedCredentialForTesting(token: &old)
        let replacement = "FAKE_VALID_REPLACEMENT_TOKEN"

        let replacementResult = await model.connect(token: replacement)
        XCTAssertTrue(replacementResult)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(store.storedTokenForTesting, replacement)
        XCTAssertEqual(store.saveCount, 2)
        XCTAssertEqual(validTransport.requests.map(\.route), [.vocabulary(spelling: "apple")])
        XCTAssertEqual(validTransport.postCount, 0)
    }

    func testStoredTokenDoesNotAssertConnectedUntilForegroundValidationSucceeds() async {
        let store = FakeTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )

        XCTAssertFalse(model.isConnected)
        await model.enterForeground()
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(store.saveCount, 0)
        XCTAssertEqual(transport.readCount, 1)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testTokenNormalizationTrimsOnlySurroundingWhitespace() async throws {
        let canonical = try InMemoryCredential(token: fakeToken)
        for value in ["  \(fakeToken)", "\(fakeToken)  ", "\(fakeToken)\n"] {
            let credential = try InMemoryCredential(token: value)
            XCTAssertEqual(credential.fingerprint, canonical.fingerprint)
        }
        let internallyChanged = try InMemoryCredential(token: "FAKE_IOS_TEST_TOKEN_ NOT_VALID")
        XCTAssertNotEqual(internallyChanged.fingerprint, canonical.fingerprint)
    }

    func testInterpretationEditorHintDocumentsCurrentSingleItemShape() {
        XCTAssertEqual(
            ContentMode.interpretation.editorHint,
            "单条格式：单词换行 n. 释义；支持 n. / v. / adj. / adv. / phr. 等词性"
        )
        XCTAssertEqual(ContentMode.phrase.editorHint, "格式：单词 · 英文例句 · 中文翻译 · 来源（可选）")
    }

    func testInterpretationGlobalFailuresAbortPreviewWithoutFabricatedRows() async {
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
            model.sourceText = "one\nn. 一\ntwo\nn. 二\nthree\nn. 三"

            await model.previewCurrentInput()

            XCTAssertNil(model.preview)
            XCTAssertFalse(model.hasExecutablePreview)
            XCTAssertEqual(model.errorMessage, expectedError.description)
            XCTAssertEqual(model.isConnected, remainsConnected)
            XCTAssertEqual(transport.readCount, 1)
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    func testGlobalFailureDuringFreshWritePreflightAbortsBeforePOST() async {
        let cases: [(StubbedResult, CompanionError, Bool)] = [
            (jsonResponse(["error": "auth"], status: 401), .authenticationRejected, false),
            (.failure(.transport), .transport, true),
            (jsonResponse(["unexpected": []]), .responseRejected, true),
        ]
        for (failure, expectedError, remainsConnected) in cases {
            let factory = SequencedTransportFactory([
                [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
                [failure],
            ])
            let model = connectedModel(factory)
            model.sourceText = "word\nn. 新建"
            await model.previewCurrentInput()
            model.askToExecute(.create)

            await model.executeConfirmed(.create)?.value

            XCTAssertEqual(model.errorMessage, expectedError.description)
            XCTAssertEqual(model.isConnected, remainsConnected)
            XCTAssertNil(model.preview)
            XCTAssertTrue(model.history.isEmpty)
            XCTAssertEqual(model.sourceText, "word\nn. 新建")
            XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        }
    }

    func testAuthenticationRejectionDuringReadbackDisconnectsAndRecordsUnknownWrite() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                jsonResponse(["error": "auth"], status: 401),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        await model.executeConfirmed(.create)?.value

        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(
            model.errorMessage,
            CompanionError.authenticationRejected.description + "\n"
                + CompanionError.uncertainWriteOutcome.description
        )
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.notVerified])
        XCTAssertEqual(model.sourceText, "word\nn. 新建")
    }

    func testMalformedAuthenticatedValidationIsNotRelabeledInvalidToken() async {
        let store = FakeTokenStore()
        let transport = FakeHTTPTransport([jsonResponse(["unexpected": []])])
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )

        let connected = await model.connect(token: "  \(fakeToken)\n")

        XCTAssertFalse(connected)
        XCTAssertFalse(model.isConnected)
        XCTAssertFalse(store.hasStoredToken)
        XCTAssertEqual(
            model.tokenErrorMessage,
            "墨墨暂时无法安全验证 Token；候选 Token 未保存。"
        )
        XCTAssertNotEqual(
            model.tokenErrorMessage,
            "这个 Token 未通过墨墨验证；未保存，请检查后重试。"
        )
        XCTAssertEqual(transport.readCount, 1)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testWriteTagPreferenceDefaultsToEmptyPersistsCanonicalZeroToThreeTags() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        let first = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            preferenceDefaults: defaults
        )
        XCTAssertEqual(first.selectedTags, [])
        XCTAssertEqual(first.selectedTagsSummary, "标签：无")

        first.toggleTag("GMAT")
        first.toggleTag("MBA")
        first.toggleTag("BEC")
        XCTAssertEqual(first.selectedTags, ["MBA", "BEC", "GMAT"])
        XCTAssertEqual(first.selectedTagsSummary, "标签：MBA · BEC · GMAT")
        XCTAssertFalse(first.canToggleTag("SAT"))
        first.toggleTag("SAT")
        XCTAssertEqual(first.selectedTags, ["MBA", "BEC", "GMAT"])

        let reconstructed = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            preferenceDefaults: defaults
        )
        XCTAssertEqual(reconstructed.selectedTags, ["MBA", "BEC", "GMAT"])

        reconstructed.toggleTag("BEC")
        XCTAssertEqual(reconstructed.selectedTags, ["MBA", "GMAT"])
    }

    func testInvalidSubmittedOrStoredTagPreferencesFailSafely() throws {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertEqual(
            try WriteTagPreference.save(["GMAT", "MBA", "BEC"], to: defaults),
            ["MBA", "BEC", "GMAT"]
        )
        XCTAssertThrowsError(
            try WriteTagPreference.save(["MBA", "BEC", "GMAT", "SAT"], to: defaults)
        )
        XCTAssertThrowsError(try WriteTagPreference.save(["MBA", "未记录标签"], to: defaults))
        XCTAssertThrowsError(try WriteTagPreference.save(["MBA", "MBA"], to: defaults))
        XCTAssertEqual(WriteTagPreference.load(from: defaults), ["MBA", "BEC", "GMAT"])

        defaults.set(["MBA", "BEC", "GMAT", "SAT"], forKey: WriteTagPreference.userDefaultsKey)
        XCTAssertEqual(WriteTagPreference.load(from: defaults), [])
        defaults.set(["unsupported"], forKey: WriteTagPreference.userDefaultsKey)
        XCTAssertEqual(WriteTagPreference.load(from: defaults), [])
    }

    func testChangingSavedTagsInvalidatesPreviewApprovalAndExecutableAuthority() async {
        let (defaults, suite) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let historyStore = InMemoryHistoryStore()
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([]),
        ])
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: historyStore,
            transportFactory: { transport },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() },
            preferenceDefaults: defaults
        )
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        XCTAssertNotNil(model.preview)
        XCTAssertNotNil(model.pendingConfirmation)
        XCTAssertTrue(model.hasExecutablePreview)

        model.toggleTag("MBA")

        XCTAssertEqual(model.selectedTags, ["MBA"])
        XCTAssertNil(model.preview)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertTrue(model.executionActions.isEmpty)
        XCTAssertEqual(historyStore.saveCount, 0)
    }

    func testTokenStorePersistsAcrossViewModelReconstruction() async {
        let store = FakeTokenStore()
        var draft = fakeToken
        let historyStore = InMemoryHistoryStore()
        let first = CompanionViewModel(tokenStore: store, historyStore: historyStore)
        first.installVerifiedCredentialForTesting(token: &draft)

        let reconstructed = CompanionViewModel(
            tokenStore: store,
            historyStore: historyStore,
            credentialValidationTransportFactory: successfulCredentialValidationTransport
        )

        XCTAssertFalse(reconstructed.isConnected)
        await reconstructed.enterForeground()

        XCTAssertTrue(first.isConnected)
        XCTAssertTrue(reconstructed.isConnected)
        XCTAssertTrue(draft.isEmpty)
        XCTAssertEqual(store.saveCount, 1)
    }

    func testBackgroundKeepsPersistedTokenAndForegroundRestoresConnection() async {
        let store = FakeTokenStore()
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: successfulCredentialValidationTransport
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)

        model.enterBackground()

        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(store.hasStoredToken)
        XCTAssertEqual(store.deleteCount, 0)

        await model.enterForeground()

        XCTAssertTrue(model.isConnected)
        XCTAssertTrue(store.hasStoredToken)
    }

    func testLocalParseAcknowledgementReportsCountAndEndpoints() {
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore()
        )
        model.sourceText = "sphere\nn. 球体\nracket\nn. 球拍"

        XCTAssertEqual(
            model.localParseState,
            .valid(count: 2, first: "sphere", last: "racket")
        )
        XCTAssertEqual(model.localParseState.message, "已识别 2 条 · sphere → racket")

        model.sourceText = "sphere\nnot deterministic"
        XCTAssertEqual(model.localParseState, .invalid)
    }

    func testPreviewLoadingStateIsImmediatelyVisibleAndPreventsDuplicateStart() async {
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]),
            interpretationsResponse([]),
        ])
        let gate = FirstPauseGateSleeper()
        let assertion = FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            sleeperFactory: { gate },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        model.sourceText = "word\nn. 新建"

        let task = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()

        XCTAssertTrue(model.isBusy)
        XCTAssertTrue(model.isPreviewing)
        XCTAssertTrue(model.isShowingEditor)

        await model.previewCurrentInput()
        XCTAssertEqual(transport.readCount, 1)

        model.enterBackground()
        await gate.resume()
        await task.value
        XCTAssertFalse(model.isPreviewing)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testSuccessfulPreviewCollapsesEditorAndBuildsCompactHeader() async {
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "sphere")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = "sphere\nn. 球体"

        await model.previewCurrentInput()

        XCTAssertFalse(model.isShowingEditor)
        XCTAssertEqual(model.previewHeader, "1 条释义 · sphere → sphere")
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(historyStore.saveCount, 0)
        model.editInput()
        XCTAssertTrue(model.isShowingEditor)
    }

    func testCompactRowsHideBodiesUntilExpanded() async throws {
        let old = interpretation("INVALID_RECORD", "n. 旧版", tags: ["考研"])
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([old])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新版"
        await model.previewCurrentInput()
        let row = try XCTUnwrap(model.preview?.rows.first)

        XCTAssertEqual(row.classification.compactLabel, "更新")
        XCTAssertNil(model.details(for: row))

        model.toggleDetails(for: row)

        XCTAssertEqual(
            model.details(for: row),
            PreviewRowDetails(
                current: "n. 旧版",
                proposed: "n. 新版",
                currentTags: ["考研"],
                proposedTags: []
            )
        )
    }

    /// #76: a mixed actionable Preview offers exactly one primary action covering
    /// the whole displayed plan, never two mandatory user runs.
    func testMixedPreviewExposesOneWholePlanActionWithBothCounts() async {
        let old = interpretation("INVALID_RECORD", "n. 旧版", tags: ["考研"])
        let factory = SequencedTransportFactory([
            [
                vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "create"), (id: "INVALID_VOC_B", spelling: "update")]), interpretationsResponse([]),
                interpretationsResponse([old]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "create\nn. 新建\nupdate\nn. 新版"
        await model.previewCurrentInput()

        XCTAssertEqual(model.executionActions.count, 1)
        XCTAssertEqual(model.executionActions.map(\.group), [nil])
        XCTAssertEqual(model.executionActions.map(\.title), ["执行 2 条（新建 1 · 更新 1）"])
        XCTAssertEqual(model.executionActions.first?.count, 2)
    }

    /// Single-group batches keep the original controls and gain no extra step.
    func testSingleGroupPreviewKeepsTheOriginalSeparateActions() async {
        let factory = SequencedTransportFactory([
            [
                vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "one"), (id: "INVALID_VOC_B", spelling: "two")]), interpretationsResponse([]),
                interpretationsResponse([]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()

        XCTAssertEqual(model.executionActions.map(\.group), [.create, .update])
        XCTAssertEqual(model.executionActions.map(\.title), ["新建 2", "更新 0"])
        XCTAssertFalse(model.executionActions.contains { $0.coversWholePlan })
    }

    func testSourceEditClearsStalePreviewPresentation() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.enterBackground()
        XCTAssertTrue(model.isPreviewStale)

        model.sourceText += "。"

        XCTAssertNil(model.preview)
        XCTAssertFalse(model.isPreviewStale)
        XCTAssertFalse(model.hasExecutablePreview)
    }

    func testCredentialReplacementClearsStalePreviewPresentation() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.enterBackground()
        XCTAssertNotNil(model.preview)
        XCTAssertTrue(model.isPreviewStale)

        var replacement = "FAKE_REPLACEMENT_TOKEN_NOT_VALID"
        model.installVerifiedCredentialForTesting(token: &replacement)

        XCTAssertNil(model.preview)
        XCTAssertFalse(model.isPreviewStale)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertTrue(replacement.isEmpty)
    }

    func testBackgroundPreservesExpandedPresentationButClearsExecutionAuthorization() async throws {
        let old = interpretation("INVALID_RECORD", "n. 旧版", tags: ["考研"])
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([old])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新版"
        await model.previewCurrentInput()
        let presentation = model.preview
        let row = try XCTUnwrap(model.preview?.rows.first)
        model.toggleDetails(for: row)
        model.askToExecute(.update)

        model.enterBackground()

        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.preview, presentation)
        XCTAssertEqual(model.expandedRowIDs, Set([row.id]))
        XCTAssertTrue(model.isPreviewStale)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertTrue(model.executionActions.isEmpty)
        XCTAssertNil(model.executeConfirmed(.update))
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
    }

    func testForegroundCredentialRestoreKeepsPreservedPreviewStaleAndReadOnly() async {
        let store = FakeTokenStore()
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory, tokenStore: store)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.enterBackground()

        await model.enterForeground()

        XCTAssertTrue(model.isConnected)
        XCTAssertNotNil(model.preview)
        XCTAssertTrue(model.isPreviewStale)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertTrue(model.executionActions.isEmpty)
    }

    func testSuccessfulRepreviewUsesGETOnlyAndRestoresExecutableActions() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.enterBackground()
        await model.enterForeground()
        XCTAssertTrue(model.executionActions.isEmpty)

        await model.previewCurrentInput()

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(factory.run(1).readCount, 2)
        XCTAssertEqual(factory.run(1).postCount, 0)
        XCTAssertFalse(model.isPreviewStale)
        XCTAssertTrue(model.hasExecutablePreview)
        XCTAssertEqual(model.executionActions.map(\.title), ["新建 1", "更新 0"])
    }

    func testBackgroundTimeExpiryCancelsPreviewBeforeItsNextGET() async {
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]),
            interpretationsResponse([]),
        ])
        let gate = FirstPauseGateSleeper()
        let assertion = FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            sleeperFactory: { gate },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        model.sourceText = "word\nn. 新建"

        let previewTask = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        assertion.expire()
        await gate.resume()
        await previewTask.value

        XCTAssertEqual(transport.readCount, 1)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.isPreviewing)
        XCTAssertFalse(model.isBusy)
    }

    func testExplicitRemoveDeletesCredentialAndPreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let store = FakeTokenStore()
        let model = connectedModel(factory, tokenStore: store)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        model.enterBackground()
        XCTAssertTrue(model.isPreviewStale)
        await model.enterForeground()
        model.removeToken()
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.isPreviewStale)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertFalse(store.hasStoredToken)
        XCTAssertEqual(store.deleteCount, 1)
    }

    func testCompletedCreateInvalidatesExecutablePreview() async {
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        XCTAssertNotNil(model.preview)
        model.askToExecute(.create)
        let execution = model.executeConfirmed(.create)
        await execution?.value
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.localParseState, .empty)
        XCTAssertEqual(model.completionAcknowledgement, "已新建 1 条 · word")
        XCTAssertFalse(model.hasExecutionFeedback)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .create)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.confirmed])
        XCTAssertEqual(historyStore.saveCount, 1)
    }

    func testMixedCreateSuccessPreservesOnlyUpdateUntilFreshPreviewThenFinalSuccessClears() async throws {
        let createBodyA = "n. 新建一  \n\n   缩进保留"
        let updateBody = "v. 更新正文  \n\n   原样缩进\nn. 第二行"
        let createBodyB = "adj. 新建二\n  尾行"
        let source = [
            "## Create-First\n\(createBodyA)",
            "## UpDate.Exact\n\(updateBody)",
            "## create-last\n\(createBodyB)",
        ].joined(separator: "\n\n")
        let expectedRemainder = "## UpDate.Exact\n\(updateBody)"
        let oldUpdate = interpretation("INVALID_RECORD_UPDATE", "v. 旧版", tags: ["考研"])
        let fullPreflight: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_CREATE_A", spelling: "Create-First"), (id: "INVALID_VOC_UPDATE", spelling: "UpDate.Exact"), (id: "INVALID_VOC_CREATE_B", spelling: "create-last")]),
            interpretationsResponse([]),
            interpretationsResponse([oldUpdate]),
            interpretationsResponse([]),
        ]
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            fullPreflight,
            fullPreflight + [
                jsonResponse([:], status: 201),
                interpretationsResponse([
                    interpretation("INVALID_RECORD_CREATE_A", createBodyA),
                ]),
                jsonResponse([:], status: 201),
                interpretationsResponse([
                    interpretation("INVALID_RECORD_CREATE_B", createBodyB),
                ]),
            ],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC_UPDATE", spelling: "UpDate.Exact")]),
                interpretationsResponse([oldUpdate]),
            ],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC_UPDATE", spelling: "UpDate.Exact")]),
                interpretationsResponse([oldUpdate]),
                jsonResponse([:]),
                interpretationsResponse([
                    interpretation("INVALID_RECORD_UPDATE", updateBody),
                ]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = source
        await model.previewCurrentInput()
        model.askToExecute(.create)

        await model.executeConfirmed(.create)?.value

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 2)
        XCTAssertEqual(model.sourceText, expectedRemainder)
        let preserved = try BatchParser.parseDailyInput(model.sourceText).entries
        XCTAssertEqual(preserved.map(\.spelling), ["UpDate.Exact"])
        XCTAssertEqual(preserved.map(\.interpretation), [updateBody])
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(historyStore.saveCount, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .create)
        XCTAssertEqual(
            model.history.first?.items.map(\.spelling),
            ["Create-First", "create-last"]
        )
        XCTAssertEqual(model.completionAcknowledgement, "已新建 2 条")
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertTrue(model.executionActions.isEmpty)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertNil(model.executeConfirmed(.update))
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 2)

        await model.previewCurrentInput()

        XCTAssertEqual(factory.transports.count, 3)
        XCTAssertEqual(factory.run(2).readCount, 2)
        XCTAssertEqual(factory.run(2).postCount, 0)
        XCTAssertEqual(model.preview?.counts, PreviewCounts(
            create: 0,
            update: 1,
            alreadyMatching: 0,
            blocked: 0
        ))
        XCTAssertTrue(model.hasExecutablePreview)
        XCTAssertEqual(model.executionActions.first { $0.group == .update }?.count, 1)
        XCTAssertNil(model.pendingConfirmation)
        model.askToExecute(.update)

        await model.executeConfirmed(.update)?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 3)
        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(historyStore.saveCount, 2)
        XCTAssertEqual(model.history.map(\.operationGroup), [.update, .create])
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.localParseState, .empty)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertEqual(model.completionAcknowledgement, "已更新 1 条 · UpDate.Exact")
    }

    func testMixedUpdateSuccessPreservesCreateEntriesInOriginalOrderAndExactBodies() async throws {
        let createBodyA = "n. 第一条  \n\n   缩进 A"
        let updateBody = "v. 更新目标"
        let createBodyB = "phr. 第二条\n  缩进 B  "
        let source = [
            "## Zeta.Create\n\(createBodyA)",
            "## Middle-UPDATE\n\(updateBody)",
            "## alpha.Create\n\(createBodyB)",
        ].joined(separator: "\n\n")
        let expectedRemainder = [
            "## Zeta.Create\n\(createBodyA)",
            "## alpha.Create\n\(createBodyB)",
        ].joined(separator: "\n\n")
        let oldUpdate = interpretation("INVALID_RECORD_UPDATE", "v. 旧目标", tags: ["考研"])
        let fullPreflight: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_CREATE_A", spelling: "Zeta.Create"), (id: "INVALID_VOC_UPDATE", spelling: "Middle-UPDATE"), (id: "INVALID_VOC_CREATE_B", spelling: "alpha.Create")]),
            interpretationsResponse([]),
            interpretationsResponse([oldUpdate]),
            interpretationsResponse([]),
        ]
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            fullPreflight,
            fullPreflight + [
                jsonResponse([:]),
                interpretationsResponse([
                    interpretation("INVALID_RECORD_UPDATE", updateBody),
                ]),
            ],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC_CREATE_A", spelling: "Zeta.Create"), (id: "INVALID_VOC_CREATE_B", spelling: "alpha.Create")]),
                interpretationsResponse([]),
                interpretationsResponse([]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = source
        await model.previewCurrentInput()
        model.askToExecute(.update)

        await model.executeConfirmed(.update)?.value

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.sourceText, expectedRemainder)
        let preserved = try BatchParser.parseDailyInput(model.sourceText).entries
        XCTAssertEqual(preserved.map(\.spelling), ["Zeta.Create", "alpha.Create"])
        XCTAssertEqual(preserved.map(\.interpretation), [createBodyA, createBodyB])
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(historyStore.saveCount, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .update)
        XCTAssertEqual(model.history.first?.items.map(\.spelling), ["Middle-UPDATE"])
        XCTAssertEqual(model.completionAcknowledgement, "已更新 1 条 · Middle-UPDATE")
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertTrue(model.executionActions.isEmpty)
        XCTAssertNil(model.pendingConfirmation)

        await model.previewCurrentInput()

        XCTAssertEqual(factory.transports.count, 3)
        XCTAssertEqual(factory.run(2).readCount, 3)
        XCTAssertEqual(factory.run(2).postCount, 0)
        XCTAssertEqual(model.preview?.counts, PreviewCounts(
            create: 2,
            update: 0,
            alreadyMatching: 0,
            blocked: 0
        ))
        XCTAssertEqual(model.executionActions.first { $0.group == .create }?.count, 2)
    }

    func testFailedMixedExecutionKeepsOriginalDraftAndInterruptedFeedback() async {
        let source = "create\nn. 新建\nupdate\nn. 更新"
        let oldUpdate = interpretation("INVALID_RECORD_UPDATE", "n. 旧", tags: ["考研"])
        let fullPreflight: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_CREATE", spelling: "create"), (id: "INVALID_VOC_UPDATE", spelling: "update")]),
            interpretationsResponse([]),
            interpretationsResponse([oldUpdate]),
        ]
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            fullPreflight,
            fullPreflight + [
                jsonResponse([:], status: 201),
                interpretationsResponse([]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = source
        await model.previewCurrentInput()
        model.askToExecute(.create)

        await model.executeConfirmed(.create)?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.sourceText, source)
        XCTAssertTrue(model.hasExecutionFeedback)
        XCTAssertEqual(model.finalSummary.failed, 0)
        XCTAssertEqual(model.finalSummary.unconfirmed, 1)
        XCTAssertEqual(model.errorMessage, CompanionError.uncertainWriteOutcome.description)
        XCTAssertNil(model.completionAcknowledgement)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(historyStore.saveCount, 1)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.notVerified])
    }

    func testDirectConfirmedExecutionWithoutArmedIntentSendsZeroPOST() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
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
                vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "create"), (id: "INVALID_VOC_B", spelling: "update")]), interpretationsResponse([]),
                interpretationsResponse([old]),
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
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
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
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([]),
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
        XCTAssertEqual(model.history.count, 1)
    }

    /// #164 R1. Five tests in this class killed the whole test host during the
    /// #164 stub migration: `XCTAssertEqual(transports.count, n)` only records a
    /// failure, so execution fell into `transports[n - 1]` and trapped in the
    /// Swift runtime. Each trap surfaced to the Owner as a macOS
    /// "MomoMoreEfficient quit unexpectedly" alert and discarded every remaining
    /// test in that launch. Reading a run must report instead.
    func testMissingTransportRunIsReportedInsteadOfTrappingTheTestHost() {
        let factory = SequencedTransportFactory([[]])
        _ = factory.make()

        XCTAssertEqual(factory.transports.count, 1)
        XCTExpectFailure("an absent transport run must fail the test, not the process") {
            XCTAssertEqual(factory.run(1).requests.count, 0)
        }
    }

    func testArmedApprovalStillRequiresFreshMatchingPreflight() async {
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]),
                interpretationsResponse([
                    interpretation("INVALID_RECORD", "n. 现在存在", tags: ["考研"]),
                ]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        await execution?.value

        XCTAssertEqual(factory.transports.count, 2)
        XCTAssertEqual(factory.run(1).readCount, 2)
        XCTAssertEqual(factory.run(1).postCount, 0)
        XCTAssertEqual(model.errorMessage, CompanionError.stalePreview.description)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(historyStore.saveCount, 0)
    }

    func testInputEditInvalidatesArmedApproval() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
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
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        var sameToken = fakeToken
        model.installVerifiedCredentialForTesting(token: &sameToken)

        let execution = model.executeConfirmed(.create)

        XCTAssertNil(execution)
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertNil(model.pendingConfirmation)
    }

    func testPartialCreateCancellationPreservesSuccessAndShowsNotAttempted() async {
        let historyStore = InMemoryHistoryStore()
        let assertion = FakeBackgroundExecutionAssertion()
        let oldPreviewResults: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "one"), (id: "INVALID_VOC_B", spelling: "two")]), interpretationsResponse([]),
            interpretationsResponse([]),
        ]
        let previewTransport = FakeHTTPTransport(oldPreviewResults)
        let executionTransport = PausingPOSTTransport(oldPreviewResults + [
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
        ])
        let model = connectedModel(
            transports: [previewTransport, executionTransport],
            historyStore: historyStore,
            assertion: assertion
        )
        model.sourceText = "one\nn. 一\ntwo\nn. 二"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertNotNil(execution)
        await executionTransport.waitUntilPOSTDispatched()
        assertion.expire()
        await executionTransport.resumePOST()
        await execution?.value

        let postCount = await executionTransport.postCount
        let readCount = await executionTransport.readCount
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(readCount, 4)
        XCTAssertEqual(model.finalSummary.created, 1)
        XCTAssertEqual(model.finalSummary.failed, 0)
        XCTAssertEqual(model.finalSummary.notAttempted, 1)
        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(
            model.finalSummary.stoppedMessage,
            "执行已停止：已完成 1 条，其余 1 条未执行。"
        )
        XCTAssertEqual(model.sourceText, "one\nn. 一\ntwo\nn. 二")
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.confirmed, .notAttempted])
        XCTAssertEqual(historyStore.saveCount, 1)
    }

    func testBackgroundTimeExpiryImmediatelyAfterConfirmShowsAllItemsNotAttempted() async {
        let historyStore = InMemoryHistoryStore()
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory, historyStore: historyStore, assertion: assertion)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        let execution = model.executeConfirmed(.create)
        XCTAssertNotNil(execution)
        assertion.expire()
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
        XCTAssertEqual(model.sourceText, "word\nn. 新建")
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.notAttempted])
    }

    func testPartialUpdateCancellationUsesSameStoppedPresentation() async {
        let historyStore = InMemoryHistoryStore()
        let assertion = FakeBackgroundExecutionAssertion()
        let oldA = interpretation("INVALID_RECORD_A", "n. 旧一", tags: ["考研"])
        let oldB = interpretation("INVALID_RECORD_B", "n. 旧二", tags: ["考研"])
        let previewResults: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "one"), (id: "INVALID_VOC_B", spelling: "two")]), interpretationsResponse([oldA]),
            interpretationsResponse([oldB]),
        ]
        let previewTransport = FakeHTTPTransport(previewResults)
        let executionTransport = PausingPOSTTransport(previewResults + [
            jsonResponse([:]),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 新一")]),
        ])
        let model = connectedModel(
            transports: [previewTransport, executionTransport],
            historyStore: historyStore,
            assertion: assertion
        )
        model.sourceText = "one\nn. 新一\ntwo\nn. 新二"
        await model.previewCurrentInput()
        model.askToExecute(.update)

        let execution = model.executeConfirmed(.update)
        XCTAssertNotNil(execution)
        await executionTransport.waitUntilPOSTDispatched()
        assertion.expire()
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
        XCTAssertEqual(model.sourceText, "one\nn. 新一\ntwo\nn. 新二")
        XCTAssertEqual(model.history.first?.operationGroup, .update)
        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertEqual(model.history.first?.notAttempted, 1)
    }

    func testSuccessfulUpdateCreatesExactlyOneReceiptAndReturnsCleanEditor() async {
        let old = interpretation("INVALID_RECORD", "n. 旧", tags: ["考研"])
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "sphere")]), interpretationsResponse([old])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "sphere")]), interpretationsResponse([old]),
                jsonResponse([:]),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 球体")]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = "sphere\nn. 球体"
        await model.previewCurrentInput()
        model.askToExecute(.update)

        await model.executeConfirmed(.update)?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(historyStore.saveCount, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .update)
        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.confirmed])
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.localParseState, .empty)
        XCTAssertTrue(model.isShowingEditor)
        XCTAssertEqual(model.completionAcknowledgement, "已更新 1 条 · sphere")
    }

    func testStartingNewDraftClearsAcknowledgementButPreservesHistory() async {
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        await model.executeConfirmed(.create)?.value
        XCTAssertNotNil(model.completionAcknowledgement)

        model.sourceText = "next\nn. 下一条"

        XCTAssertNil(model.completionAcknowledgement)
        XCTAssertFalse(model.hasExecutionFeedback)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(historyStore.receipts.count, 1)
        XCTAssertEqual(model.sourceText, "next\nn. 下一条")
    }

    func testClearHistoryDoesNotAlterTokenOrCurrentDraft() {
        let receipt = ExecutionReceipt(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            operationGroup: .create,
            selectedSpellings: ["word"],
            result: ExecutionSummary(
                group: .create,
                succeeded: 1,
                failed: 0,
                cancelled: false,
                stalePreview: false,
                results: [ItemExecutionResult(spelling: "word", outcome: .confirmed)]
            )
        )
        let historyStore = InMemoryHistoryStore(receipts: [receipt])
        let tokenStore = FakeTokenStore(token: fakeToken)
        let model = CompanionViewModel(tokenStore: tokenStore, historyStore: historyStore)
        model.sourceText = "draft\nn. 草稿"

        model.clearHistory()

        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(historyStore.clearCount, 1)
        XCTAssertFalse(model.isConnected)
        XCTAssertTrue(tokenStore.hasStoredToken)
        XCTAssertEqual(tokenStore.deleteCount, 0)
        XCTAssertEqual(model.sourceText, "draft\nn. 草稿")
    }

    func testHistorySaveFailureDoesNotChangeSuccessfulWriteOrRetryPOST() async {
        let historyStore = InMemoryHistoryStore()
        historyStore.failSave = true
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
            ],
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.askToExecute(.create)

        await model.executeConfirmed(.create)?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(historyStore.saveCount, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.completionAcknowledgement, "已新建 1 条 · word")
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.historyErrorMessage, "历史记录保存失败")
    }

    func testPublicStateAndErrorsNeverExposeFakeToken() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        let rendered = String(describing: model.preview)
            + String(describing: model.finalSummary)
            + String(describing: model.errorMessage)
            + model.debugDescription
            + FakeTokenStore(token: fakeToken).debugDescription
        XCTAssertFalse(rendered.contains(fakeToken))
    }

    private func connectedModel(
        _ factory: SequencedTransportFactory,
        tokenStore: FakeTokenStore = FakeTokenStore(),
        historyStore: HistoryStore = InMemoryHistoryStore(),
        assertion: FakeBackgroundExecutionAssertion? = nil
    ) -> CompanionViewModel {
        let assertion = assertion ?? FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: tokenStore,
            historyStore: historyStore,
            transportFactory: factory.make,
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        XCTAssertTrue(draft.isEmpty)
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
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        XCTAssertTrue(draft.isEmpty)
        return model
    }

    private func isolatedDefaults() -> (UserDefaults, String) {
        let suite = "MomoMoreEfficientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return (defaults, suite)
    }
}

final class SequencedTransportFactory: @unchecked Sendable {
    private var runs: [[StubbedResult]]
    private(set) var transports: [FakeHTTPTransport] = []

    init(_ runs: [[StubbedResult]]) {
        self.runs = runs
    }

    /// The spy for run `index`, or an empty spy plus a recorded failure when the
    /// flow produced fewer runs than the test expected.
    ///
    /// `XCTAssertEqual(transports.count, n)` only *records* a failure; execution
    /// falls straight into the next line. Subscripting there traps in the Swift
    /// runtime and kills the whole test host, so the developer sees a macOS
    /// "MomoMoreEfficient quit unexpectedly" alert and loses every remaining
    /// test in that launch instead of reading one precise failure (#164 R1).
    func run(
        _ index: Int,
        file: StaticString = #filePath,
        line: UInt = #line
    ) -> FakeHTTPTransport {
        guard transports.indices.contains(index) else {
            XCTFail(
                "expected at least \(index + 1) transport runs, got \(transports.count)",
                file: file,
                line: line
            )
            return FakeHTTPTransport([])
        }
        return transports[index]
    }

    func make() -> HTTPTransport {
        guard !runs.isEmpty else { return FakeHTTPTransport([]) }
        let transport = FakeHTTPTransport(runs.removeFirst())
        transports.append(transport)
        return transport
    }
}
