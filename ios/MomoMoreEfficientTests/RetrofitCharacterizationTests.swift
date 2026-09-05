import Foundation
import XCTest
@testable import MomoMoreEfficient

/// Checkpoint 0 of the #161 retrofit: pin the existing behavior that the
/// renovation is most likely to disturb, *before* anything moves.
///
/// These are deliberately narrow characterization tests, not a snapshot suite.
/// Each one exists because a specific #161 change could silently break it:
/// the publication-status thread through the interpretation chain (phrase must
/// stay PUBLISHED), the new optional receipt field (old archives must still
/// decode whole), the contextual History presentation (clearing stays global),
/// the Settings/Token move (a failed candidate must keep the old connection),
/// and the Capture redesign (three XCUITest hooks must survive verbatim).
@MainActor
final class RetrofitCharacterizationTests: XCTestCase {

    // MARK: - Token replacement: a failed candidate never disturbs the old connection

    /// S-11 → S-12/S-13. Replacement validates the candidate independently and
    /// only replaces the active session after the authenticated GET *and* the
    /// Keychain save both succeed.
    func testFailedCandidateTokenReplacementKeepsOldActiveConnection() async {
        let store = FakeTokenStore()
        // One successful validation for the original connect, then a rejection
        // for the replacement candidate.
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
            jsonResponse(["error": "unauthorized"], status: 401),
        ])
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )

        let firstConnect = await model.connect(token: fakeToken)
        XCTAssertTrue(firstConnect)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.storedTokenForTesting, fakeToken)

        let replaced = await model.connect(token: "CANDIDATE_TOKEN_NOT_VALID")
        XCTAssertFalse(replaced)
        // The old connection is still the active one, and the Keychain still
        // holds the original value: the candidate was never saved.
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(store.saveCount, 1)
        XCTAssertEqual(store.storedTokenForTesting, fakeToken)
        XCTAssertNotNil(model.tokenErrorMessage)
        XCTAssertEqual(transport.postCount, 0)
    }

    /// A Keychain save failure is the other half of the same rule: validation
    /// passing is not enough to replace the active credential.
    func testCandidateRejectedByKeychainSaveKeepsOldActiveConnection() async {
        let store = FakeTokenStore()
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )

        let firstConnect = await model.connect(token: fakeToken)
        XCTAssertTrue(firstConnect)
        store.failSave = true

        let replaced = await model.connect(token: "CANDIDATE_TOKEN_NOT_VALID")
        XCTAssertFalse(replaced)
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(store.storedTokenForTesting, fakeToken)
        XCTAssertNotNil(model.tokenErrorMessage)
    }

    // MARK: - Phrase writes stay PUBLISHED

    /// The legacy shared constant is the phrase path's status authority and must
    /// not become a dynamic preference (adjudication finding 9).
    func testPhraseBindingContextExpectedStatusIsTheLegacyPublishedConstant() throws {
        XCTAssertEqual(CompanionConstants.status, "PUBLISHED")

        let entry = PhraseBatchEntry(
            ordinal: 1,
            spelling: "merchandise",
            normalizedSpelling: "merchandise",
            english: "The merchandise arrived late.",
            chinese: "货物到得晚。",
            source: nil
        )
        let item = PhrasePreflightItem(
            entry: entry,
            classification: .create,
            vocabularyID: "VOC_MERCHANDISE",
            sameEnglishBaseline: [],
            reason: nil
        )
        let context = try PhraseCreateBinding.makePreviewBindingContext(
            items: [item],
            tags: []
        )
        XCTAssertEqual(context.expectedStatus, "PUBLISHED")
    }

    // MARK: - Contextual History presentation does not narrow the destructive scope

    /// HI-07. `清空历史` is global to the one receipt store even when it is
    /// invoked from a per-mode filtered screen.
    func testClearHistoryRemovesBothInterpretationAndPhraseReceipts() throws {
        let store = InMemoryHistoryStore()
        try store.saveReceipts([
            makeReceipt(kind: .interpretation, spelling: "merchandise"),
            makeReceipt(kind: .phrase, spelling: "take into account"),
        ])
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: store,
            credentialValidationTransportFactory: { successfulCredentialValidationTransport() },
            sleeperFactory: { RecordingSleeper() }
        )
        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(Set(model.history.map(\.contentKind)), [.interpretation, .phrase])

        model.clearHistory()

        XCTAssertTrue(model.history.isEmpty)
        XCTAssertTrue(try store.loadReceipts().isEmpty)
    }

    // MARK: - Golden pre-change History archive

    /// The committed archive is the exact on-disk shape #161 inherits, including
    /// a pre-`contentKind` receipt. Adding an optional interpretation-status
    /// field must never stop the whole archive from loading, and must never
    /// rewrite or migrate what is already there.
    func testGoldenPreChangeHistoryArchiveDecodesInFull() throws {
        let directory = try makeTemporaryApplicationSupportDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try installGoldenArchive(in: directory)

        let receipts = try FileHistoryStore(applicationSupportDirectory: directory)
            .loadReceipts()

        XCTAssertEqual(receipts.count, 3)
        // Newest first, exactly as the store already promises.
        XCTAssertEqual(
            receipts.map(\.items.first?.spelling),
            ["take into account", "merchandise", "legacy"]
        )

        // 1. The pre-`contentKind` receipt still defaults to interpretation and
        //    tolerates the missing `unconfirmed` / `diagnosticEnvironment` keys.
        let legacy = try XCTUnwrap(receipts.first { $0.items.first?.spelling == "legacy" })
        XCTAssertEqual(legacy.contentKind, .interpretation)
        XCTAssertEqual(legacy.operationGroup, .create)
        XCTAssertEqual(legacy.unconfirmed, 0)
        XCTAssertEqual(legacy.diagnosticEnvironment, .legacy)
        XCTAssertEqual(legacy.items.first?.ordinal, 0)
        XCTAssertNil(legacy.items.first?.diagnostic)
        XCTAssertTrue(legacy.isFullSuccess)

        // 2. A full interpretation receipt keeps every closed diagnostic layer.
        let interpretation = try XCTUnwrap(
            receipts.first { $0.items.first?.spelling == "merchandise" }
        )
        XCTAssertEqual(interpretation.contentKind, .interpretation)
        XCTAssertEqual(interpretation.operationGroup, .update)
        XCTAssertEqual(interpretation.items.count, 3)
        XCTAssertEqual(
            interpretation.items.map(\.finalOutcome),
            [.confirmed, .notVerified, .notAttempted]
        )
        XCTAssertEqual(
            interpretation.items[0].diagnostic?.postDispatch,
            .clean2xx(status: 200)
        )
        XCTAssertEqual(
            interpretation.items[1].diagnostic?.terminalErrorCategory,
            .uncertainWriteOutcome
        )
        XCTAssertEqual(interpretation.diagnosticEnvironment.appBuild, "3")

        // 3. A phrase receipt keeps its phrase-specific readback facts.
        let phrase = try XCTUnwrap(receipts.first { $0.contentKind == .phrase })
        XCTAssertEqual(phrase.operationGroup, .create)
        XCTAssertEqual(phrase.items.map(\.finalOutcome), [.confirmed, .recovered])
        let recoveredFacts = try XCTUnwrap(
            phrase.items[1].diagnostic?.readbackAttempts.last?.phraseFacts
        )
        XCTAssertEqual(recoveredFacts.activeRecordCount, 1)
        XCTAssertEqual(recoveredFacts.mismatchKeys, [.source])
        XCTAssertEqual(
            phrase.items[1].diagnostic?.postDispatch,
            .transportFailure(errorCategory: .transport)
        )

        // The whole archive round-trips through the sanitized export without
        // throwing, which is the only place receipts leave the device.
        for receipt in receipts {
            XCTAssertFalse(receipt.sanitizedDiagnosticText.isEmpty)
        }
    }

    /// The store is only allowed to fail closed on an archive version it does
    /// not know; #161 must not bump the version to add an optional field.
    func testGoldenArchiveVersionIsUnchangedByTheRetrofit() throws {
        let data = try Data(contentsOf: try goldenArchiveURL())
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(root["version"] as? Int, 1)
    }

    // MARK: - Capture accessibility hooks

    /// Physical- and simulator-device regression tests address the Capture
    /// review by these exact strings. The redesign re-homes the surface; the
    /// hooks must survive verbatim.
    func testCaptureAccessibilityIdentifiersAreStable() {
        XCTAssertEqual(CaptureAccessibilityIdentifier.status, "captureReviewStatus")
        XCTAssertEqual(CaptureAccessibilityIdentifier.textEditor, "captureReviewTextEditor")
        XCTAssertEqual(CaptureAccessibilityIdentifier.cancelButton, "cancelCaptureButton")
    }

    // MARK: - Helpers

    private func makeReceipt(
        kind: ReceiptContentKind,
        spelling: String
    ) -> ExecutionReceipt {
        ExecutionReceipt(
            timestamp: Date(timeIntervalSince1970: kind == .phrase ? 2_000 : 1_000),
            contentKind: kind,
            operationGroup: .create,
            selectedSpellings: [spelling],
            result: ExecutionSummary(
                group: .create,
                succeeded: 1,
                failed: 0,
                cancelled: false,
                stalePreview: false,
                results: [ItemExecutionResult(spelling: spelling, outcome: .confirmed)]
            )
        )
    }

    private func goldenArchiveURL() throws -> URL {
        try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "history-archive-pre-161",
                withExtension: "json"
            ),
            "committed golden pre-change History archive is missing"
        )
    }

    private func makeTemporaryApplicationSupportDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory
    }

    private func installGoldenArchive(in applicationSupport: URL) throws {
        let storeDirectory = applicationSupport
            .appendingPathComponent("com.davidqyc.momoMoreEfficient", isDirectory: true)
        try FileManager.default.createDirectory(
            at: storeDirectory,
            withIntermediateDirectories: true
        )
        try Data(contentsOf: try goldenArchiveURL()).write(
            to: storeDirectory.appendingPathComponent("history-v1.json", isDirectory: false)
        )
    }
}
