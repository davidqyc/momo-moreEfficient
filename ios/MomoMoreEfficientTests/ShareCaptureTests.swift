import UniformTypeIdentifiers
import XCTest
@testable import MomoMoreEfficient

@MainActor
final class ShareCaptureTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }
        temporaryDirectories = []
        super.tearDown()
    }

    func testNSItemProviderDecodesExactTextAndCleanDirectContext() async throws {
        let exact = "  Word\r\nline “quoted”\n\n末尾空格  "
        let sourceURL = URL(string: "https://example.invalid/reading?id=42")!
        let item = NSExtensionItem()
        item.attributedTitle = NSAttributedString(string: "Direct source title")
        item.attachments = [
            NSItemProvider(
                item: exact as NSString,
                typeIdentifier: UTType.plainText.identifier
            ),
            NSItemProvider(
                item: sourceURL as NSURL,
                typeIdentifier: UTType.url.identifier
            ),
        ]

        let payload = try await ShareItemProviderDecoder().decode([item])

        XCTAssertEqual(payload.text, exact)
        XCTAssertEqual(payload.sourceURL, sourceURL)
        XCTAssertEqual(payload.sourceTitle, "Direct source title")
    }

    func testDecoderRejectsMultipleDifferentTextAttachments() async throws {
        let item = NSExtensionItem()
        item.attachments = [
            NSItemProvider(item: "first" as NSString, typeIdentifier: UTType.plainText.identifier),
            NSItemProvider(item: "second" as NSString, typeIdentifier: UTType.plainText.identifier),
        ]

        do {
            _ = try await ShareItemProviderDecoder().decode([item])
            XCTFail("Expected ambiguous text to fail closed")
        } catch let error as ShareItemProviderDecoderError {
            XCTAssertEqual(error, .ambiguousText)
        }
    }

    func testInboxPreservesExactTextAndSourceMetadata() throws {
        let inbox = makeInbox()
        let exact = "\tleading\r\nUnicode 🐦\n\ntrailing  "
        let capturedAt = Date(timeIntervalSince1970: 1_900_000_000.125)
        let capture = PendingCapture(
            text: exact,
            sourceURL: URL(string: "https://example.invalid/article")!,
            sourceTitle: "Exact source title",
            capturedAt: capturedAt
        )

        try inbox.save(capture)

        XCTAssertEqual(try inbox.load(), capture)
        XCTAssertEqual(try inbox.load()?.text, exact)
        XCTAssertEqual(try inbox.load()?.capturedAt, capturedAt)
    }

    func testSizeBoundaryFailsVisiblyWithoutTruncationOrReplacement() throws {
        let inbox = makeInbox()
        let accepted = String(repeating: "a", count: PendingCaptureInbox.maximumTextBytes)
        try inbox.save(PendingCapture(text: accepted))
        XCTAssertEqual(try inbox.load()?.text, accepted)

        let oversized = accepted + "b"
        XCTAssertThrowsError(try inbox.save(PendingCapture(text: oversized))) { error in
            XCTAssertEqual(
                error as? PendingCaptureInboxError,
                .textTooLarge(maximumBytes: PendingCaptureInbox.maximumTextBytes)
            )
        }
        // Failed replacement leaves the previous complete capture untouched.
        XCTAssertEqual(try inbox.load()?.text, accepted)
    }

    func testAtomicSaveLoadConsumeDeletesSuccessfulInbox() throws {
        let inbox = makeInbox()
        let capture = PendingCapture(text: " atomic exact \n")
        try inbox.save(capture)
        XCTAssertEqual(try inbox.load(), capture)

        var installed: PendingCapture?
        let consumed = try inbox.consume { installed = $0 }

        XCTAssertEqual(consumed, capture)
        XCTAssertEqual(installed, capture)
        XCTAssertNil(try inbox.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.pendingFileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: inbox.claimedFileURL.path))
    }

    func testLatestSaveWins() throws {
        let inbox = makeInbox()
        try inbox.save(PendingCapture(text: "first"))
        try inbox.save(PendingCapture(text: " second exact "))

        XCTAssertEqual(try inbox.load()?.text, " second exact ")
    }

    func testCancelDoesNotAccessOrWriteInbox() throws {
        let inbox = makeInbox()
        var inboxAccessCount = 0

        let saved = try ShareCaptureActions.apply(.cancel) {
            inboxAccessCount += 1
            return inbox
        }

        XCTAssertFalse(saved)
        XCTAssertEqual(inboxAccessCount, 0)
        XCTAssertNil(try inbox.load())
    }

    func testCorruptOversizedAndUnsupportedInboxFailClosedAndCanBeRemoved() throws {
        let corruptInbox = makeInbox()
        try Data("{not-json".utf8).write(to: corruptInbox.pendingFileURL, options: [.atomic])
        XCTAssertThrowsError(try corruptInbox.load()) { error in
            XCTAssertEqual(error as? PendingCaptureInboxError, .corruptData)
        }
        XCTAssertThrowsError(try corruptInbox.consume { _ in
            XCTFail("Corrupt content must not be installed")
        })
        XCTAssertTrue(FileManager.default.fileExists(atPath: corruptInbox.pendingFileURL.path))
        try corruptInbox.removePending()
        XCTAssertNil(try corruptInbox.load())

        let oversizedInbox = makeInbox()
        let raw = Data(repeating: 0x41, count: PendingCaptureInbox.maximumFileBytes + 1)
        try raw.write(to: oversizedInbox.pendingFileURL, options: [.atomic])
        XCTAssertThrowsError(try oversizedInbox.load()) { error in
            XCTAssertEqual(
                error as? PendingCaptureInboxError,
                .fileTooLarge(maximumBytes: PendingCaptureInbox.maximumFileBytes)
            )
        }
        try oversizedInbox.removePending()
        XCTAssertNil(try oversizedInbox.load())

        let unsupportedInbox = makeInbox()
        let oldVersion = Data(#"{"version":1,"text":"old unreleased format"}"#.utf8)
        try oldVersion.write(to: unsupportedInbox.pendingFileURL, options: [.atomic])
        XCTAssertThrowsError(try unsupportedInbox.load()) { error in
            XCTAssertEqual(error as? PendingCaptureInboxError, .unsupportedVersion)
        }
        try unsupportedInbox.removePending()
        XCTAssertNil(try unsupportedInbox.load())
    }

    func testOlderDurableShareIsConsumedWithoutReplacingNewerIntentReview() async throws {
        let inbox = makeInbox()
        let shareTime = Date(timeIntervalSince1970: 1_900_000_000)
        let intentTime = shareTime.addingTimeInterval(10)
        try inbox.save(PendingCapture(text: "share A", capturedAt: shareTime))
        let store = CaptureReviewStore()
        store.receive("intent B", capturedAt: intentTime)
        let tokenStore = CountingShareTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = makeModel(tokenStore: tokenStore, transport: transport)

        let result = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: store,
            captureInbox: { inbox },
            viewModel: model
        )

        XCTAssertEqual(result, .reviewReady)
        XCTAssertEqual(store.review?.text, "intent B")
        XCTAssertEqual(store.review?.capturedAt, intentTime)
        XCTAssertEqual(store.review?.replacementCount, 0)
        XCTAssertFalse(store.review?.replacedExistingReview ?? true)
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertEqual(transport.getCount, 0)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.phrasePreview)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertNil(model.pendingPhraseConfirmation)
        XCTAssertNil(try inbox.load())

        // A second foreground cannot replay the consumed stale Share capture.
        let replayCheck = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: store,
            captureInbox: { inbox },
            viewModel: model
        )
        XCTAssertEqual(replayCheck, .reviewReady)
        XCTAssertEqual(store.review?.text, "intent B")
        XCTAssertEqual(store.review?.replacementCount, 0)
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNewerDurableShareReplacesOlderIntentReviewExactlyOnce() async throws {
        let inbox = makeInbox()
        let intentTime = Date(timeIntervalSince1970: 1_900_000_000)
        let shareTime = intentTime.addingTimeInterval(10)
        let store = CaptureReviewStore()
        store.receive("intent A", capturedAt: intentTime)
        try inbox.save(PendingCapture(text: "share B", capturedAt: shareTime))
        let tokenStore = CountingShareTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = makeModel(tokenStore: tokenStore, transport: transport)

        let result = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: store,
            captureInbox: { inbox },
            viewModel: model
        )

        XCTAssertEqual(result, .reviewReady)
        XCTAssertEqual(store.review?.text, "share B")
        XCTAssertEqual(store.review?.capturedAt, shareTime)
        XCTAssertEqual(store.review?.replacementCount, 1)
        XCTAssertTrue(store.review?.replacedExistingReview ?? false)
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertEqual(transport.getCount, 0)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.phrasePreview)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertNil(model.pendingPhraseConfirmation)
        XCTAssertNil(try inbox.load())

        // No pending file remains, so replacement behavior is not repeated.
        let replayCheck = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: store,
            captureInbox: { inbox },
            viewModel: model
        )
        XCTAssertEqual(replayCheck, .reviewReady)
        XCTAssertEqual(store.review?.text, "share B")
        XCTAssertEqual(store.review?.replacementCount, 1)
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAuthorizedBusyOperationDefersInboxUntilSafeIdle() async throws {
        let inbox = makeInbox()
        try inbox.save(PendingCapture(text: "defer me"))
        let previewTransport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"),
            interpretationsResponse([]),
        ])
        let executionTransport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"),
            interpretationsResponse([]),
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD", "n. value")]),
        ])
        var transports: [HTTPTransport] = [previewTransport, executionTransport]
        let executionGate = FirstPauseGateSleeper()
        var sleepers: [RequestSleeper] = [RecordingSleeper(), executionGate]
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transports.removeFirst() },
            sleeperFactory: { sleepers.removeFirst() }
        )
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        model.sourceText = "word\nn. value"
        await model.previewCurrentInput()
        model.askToExecute(.create)
        let execution = model.executeConfirmed(.create)
        XCTAssertNotNil(execution)
        await executionGate.waitUntilEntered()
        XCTAssertTrue(model.isExecuting)

        let deferred = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: CaptureReviewStore(),
            captureInbox: { inbox },
            viewModel: model
        )
        XCTAssertEqual(deferred, .deferredBusy)
        XCTAssertEqual(try inbox.load()?.text, "defer me")

        await executionGate.resume()
        await execution?.value
        XCTAssertFalse(model.isBusy)

        let store = CaptureReviewStore()
        let installed = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: store,
            captureInbox: { inbox },
            viewModel: model
        )
        XCTAssertEqual(installed, .reviewReady)
        XCTAssertEqual(store.review?.text, "defer me")
        XCTAssertNil(try inbox.load())
    }

    func testStoredTokenAndPendingShareInstallReviewBeforeAnyCredentialOrTraffic() async throws {
        let inbox = makeInbox()
        let exact = " pending share before credentials "
        try inbox.save(PendingCapture(text: exact))
        let tokenStore = CountingShareTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = makeModel(tokenStore: tokenStore, transport: transport)
        let store = CaptureReviewStore()

        let result = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: store,
            captureInbox: { inbox },
            viewModel: model
        )

        XCTAssertEqual(result, .reviewReady)
        XCTAssertEqual(store.review?.text, exact)
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertEqual(tokenStore.saveCount, 0)
        XCTAssertEqual(tokenStore.deleteCount, 0)
        XCTAssertEqual(transport.getCount, 0)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
        XCTAssertNil(model.phrasePreview)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.pendingConfirmation)
        XCTAssertNil(model.pendingPhraseConfirmation)
        XCTAssertNil(try inbox.load())
    }

    func testCorruptInboxBlocksCredentialRestorationUntilExplicitRemoval() async throws {
        let inbox = makeInbox()
        try Data("broken".utf8).write(to: inbox.pendingFileURL, options: [.atomic])
        let tokenStore = CountingShareTokenStore(token: fakeToken)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = makeModel(tokenStore: tokenStore, transport: transport)

        let result = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: CaptureReviewStore(),
            captureInbox: { inbox },
            viewModel: model
        )

        XCTAssertEqual(result, .inboxFailure(.corruptData))
        XCTAssertEqual(tokenStore.loadCount, 0)
        XCTAssertTrue(transport.requests.isEmpty)
        try inbox.removePending()
        XCTAssertNil(try inbox.load())

        // ContentView performs this activation immediately after successful
        // explicit removal, without waiting for another scene transition.
        let resumed = await CaptureReviewForegroundGate.activate(
            sceneIsActive: true,
            captureReviewStore: CaptureReviewStore(),
            captureInbox: { inbox },
            viewModel: model
        )
        XCTAssertEqual(resumed, .restoredNormally)
        XCTAssertEqual(tokenStore.loadCount, 1)
        XCTAssertEqual(transport.getCount, 1)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testProjectUsesExactAppGroupAndExtensionCannotCompileTokenOrMaimemoSources() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let iosRoot = testsDirectory.deletingLastPathComponent()
        let project = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "MomoMoreEfficient.xcodeproj/project.pbxproj"
            ),
            encoding: .utf8
        )
        let extensionSources = try XCTUnwrap(
            project.split(separator: "\n").first {
                $0.contains("A80000000000000000000003 /* Sources */ = {")
            }.map(String.init)
        )

        for (buildFileID, required) in [
            ("A10000000000000000000027", "ShareViewController.swift"),
            ("A10000000000000000000028", "PendingCaptureInbox.swift"),
            ("A10000000000000000000029", "ShareItemProviderDecoder.swift"),
            ("A1000000000000000000002A", "ShareCaptureActions.swift"),
        ] {
            XCTAssertTrue(extensionSources.contains(buildFileID), required)
            XCTAssertTrue(
                project.contains("\(buildFileID) /* \(required) in Sources */"),
                required
            )
        }
        for (buildFileID, forbidden) in [
            ("A10000000000000000000012", "TokenStore.swift"),
            ("A10000000000000000000003", "CredentialSession.swift"),
            ("A10000000000000000000006", "MaimemoTransport.swift"),
            ("A10000000000000000000007", "PreflightPlanner.swift"),
            ("A10000000000000000000009", "WriteExecutor.swift"),
            ("A1000000000000000000000A", "CompanionViewModel.swift"),
            ("A1000000000000000000000B", "ContentView.swift"),
            ("A10000000000000000000021", "CaptureReviewStore.swift"),
        ] {
            XCTAssertFalse(extensionSources.contains(buildFileID), forbidden)
        }

        let appEntitlements = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "MomoMoreEfficient/MomoMoreEfficient.entitlements"
            ),
            encoding: .utf8
        )
        let extensionEntitlements = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "ShareExtension/ShareExtension.entitlements"
            ),
            encoding: .utf8
        )
        for entitlements in [appEntitlements, extensionEntitlements] {
            XCTAssertTrue(entitlements.contains(PendingCaptureInbox.appGroupIdentifier))
            XCTAssertFalse(entitlements.contains("keychain-access-groups"))
        }

        let extensionController = try String(
            contentsOf: iosRoot.appendingPathComponent(
                "ShareExtension/ShareViewController.swift"
            ),
            encoding: .utf8
        )
        for forbidden in [
            "openURL", "UIApplication.shared", "Token", "Maimemo", "Preview",
            "Authorization", "Cookie",
        ] {
            XCTAssertFalse(extensionController.contains(forbidden), forbidden)
        }
        XCTAssertTrue(
            extensionController.contains("showError(error.localizedDescription, allowsRetry: true)"),
            "A Save validation error must allow editing and retrying"
        )
    }

    private func makeInbox() -> PendingCaptureInbox {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        temporaryDirectories.append(directory)
        return PendingCaptureInbox(containerURL: directory)
    }

    private func makeModel(
        tokenStore: TokenStore,
        transport: FakeHTTPTransport
    ) -> CompanionViewModel {
        CompanionViewModel(
            tokenStore: tokenStore,
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )
    }
}

private final class CountingShareTokenStore: TokenStore {
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
