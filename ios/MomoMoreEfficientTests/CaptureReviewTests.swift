import AppIntents
import XCTest
@testable import MomoMoreEfficient

@MainActor
final class CaptureReviewTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CaptureReviewStore.shared.cancel()
    }

    override func tearDown() {
        CaptureReviewStore.shared.cancel()
        super.tearDown()
    }

    func testIntentHandsOffRequiredTextExactlyWithoutStartingPreview() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("App Intent requires iOS 26") }
        let original = "  Word\r\nline “quoted”\n\n末尾空格  "
        let intent = CaptureTextIntent()
        intent.text = original

        _ = try await intent.perform()

        XCTAssertEqual(CaptureReviewStore.shared.review?.text, original)
        XCTAssertFalse(CaptureReviewStore.shared.review?.replacedExistingReview ?? true)
    }

    func testEditReplaceAndCancelAreExplicitAndDeterministic() {
        let store = CaptureReviewStore()
        store.receive("first")
        store.edit("edited exactly\n")
        XCTAssertEqual(store.review?.text, "edited exactly\n")

        store.receive(" second capture ")
        XCTAssertEqual(store.review?.text, " second capture ")
        XCTAssertTrue(store.review?.replacedExistingReview ?? false)
        XCTAssertEqual(store.review?.replacementCount, 1)

        store.receive("third")
        XCTAssertEqual(store.review?.text, "third")
        XCTAssertEqual(store.review?.replacementCount, 2)

        store.cancel()
        XCTAssertNil(store.review)
        XCTAssertNil(store.takeReviewedText())
    }

    func testRepeatedIntentCaptureUsesLatestWinsSemantics() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("App Intent requires iOS 26") }
        let first = CaptureTextIntent()
        first.text = "first intent"
        _ = try await first.perform()

        let second = CaptureTextIntent()
        second.text = " second intent "
        _ = try await second.perform()

        XCTAssertEqual(CaptureReviewStore.shared.review?.text, " second intent ")
        XCTAssertEqual(CaptureReviewStore.shared.review?.replacementCount, 1)
        XCTAssertTrue(CaptureReviewStore.shared.review?.replacedExistingReview ?? false)
    }

    func testCaptureSurvivesInProcessLifecycleButFreshProcessStateStartsEmpty() {
        let liveProcessStore = CaptureReviewStore()
        liveProcessStore.receive("keep across background")

        // Foreground/background does not serialize, normalize or discard capture.
        XCTAssertEqual(liveProcessStore.review?.text, "keep across background")

        // A new instance models a terminated-process relaunch. #120 intentionally
        // adds no persistence; #124 will provide its own non-secret inbox transport.
        let relaunchedProcessStore = CaptureReviewStore()
        XCTAssertNil(relaunchedProcessStore.review)
    }

    func testExplicitTransferEntersEditorButCannotCreatePreviewAuthorization() async {
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"),
            interpretationsResponse([]),
        ])
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        model.sourceText = "word\nn. old"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        XCTAssertNotNil(model.preview)
        XCTAssertNotNil(model.pendingConfirmation)

        let requestCountBeforeCapture = transport.requests.count
        let store = CaptureReviewStore()
        let captured = " exact captured text \n"
        store.receive(captured)
        model.prepareForCaptureReview()

        XCTAssertNil(model.preview)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.executeConfirmed(.create))
        XCTAssertEqual(transport.requests.count, requestCountBeforeCapture)
        XCTAssertEqual(transport.postCount, 0)

        model.acceptCapturedText(store.takeReviewedText()!, in: .phrase)
        XCTAssertEqual(model.contentMode, .phrase)
        XCTAssertEqual(model.sourceText, captured)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.pendingPhraseConfirmation)
        XCTAssertEqual(transport.requests.count, requestCountBeforeCapture)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testIntentHasNoCredentialOrMaimemoDependency() async throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("App Intent requires iOS 26") }
        let tokenStore = CountingTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([])
        let model = CompanionViewModel(
            tokenStore: tokenStore,
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )
        let intent = CaptureTextIntent()
        intent.text = "network-free"

        _ = try await intent.perform()
        model.prepareForCaptureReview()

        XCTAssertEqual(CaptureReviewStore.shared.review?.text, "network-free")
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertEqual(tokenStore.deleteCount, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.phrasePreview)
        XCTAssertFalse(model.hasExecutablePreview)
    }

    func testDeferredCaptureLaunchCannotRestoreCredentialBeforeReviewHandoff() async {
        let tokenStore = CountingTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([vocabularyResponse("INVALID_VOC", "word")])
        let model = CompanionViewModel(
            tokenStore: tokenStore,
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )
        let store = CaptureReviewStore()

        // A deferred App Intent can construct the app UI while its action still
        // runs in the background. That pre-handoff launch must be a hard no-op.
        await CaptureReviewForegroundGate.activate(
            sceneIsActive: false,
            captureReviewStore: store,
            viewModel: model
        )

        XCTAssertNil(store.review)
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertFalse(model.isConnected)

        // `perform()` installs this exact boundary before deferred foregrounding.
        store.receive("handoff now exists")
        await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: store,
            viewModel: model
        )

        XCTAssertEqual(store.review?.text, "handoff now exists")
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertEqual(tokenStore.deleteCount, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.phrasePreview)
        XCTAssertFalse(model.hasExecutablePreview)
    }

    func testNormalActiveLaunchStillRestoresStoredCredentialWithoutCapture() async {
        let tokenStore = CountingTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = CompanionViewModel(
            tokenStore: tokenStore,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )

        await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: CaptureReviewStore(),
            viewModel: model
        )

        XCTAssertEqual(tokenStore.loadCount, 1)
        XCTAssertEqual(transport.getCount, 1)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertTrue(model.isConnected)
    }

    func testCurrentForegroundModeIsDeferredOnIOS26() throws {
        guard #available(iOS 26.0, *) else { throw XCTSkip("App Intent requires iOS 26") }
        XCTAssertEqual(
            CaptureTextIntent.supportedModes,
            [.foreground(.deferred)]
        )
    }
}

private final class CountingTokenStore: TokenStore {
    private var token: String?
    private(set) var loadCount = 0
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(token: String?) {
        self.token = token
    }

    func loadToken() throws -> String? {
        loadCount += 1
        return token
    }

    func saveToken(_ token: String) throws {
        saveCount += 1
        self.token = token
    }

    func deleteToken() throws {
        deleteCount += 1
        token = nil
    }
}
