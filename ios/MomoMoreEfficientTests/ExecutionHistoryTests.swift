import Foundation
import XCTest
@testable import MomoMoreEfficient

final class ExecutionHistoryTests: XCTestCase {
    func testUnconfirmedWriteGuidanceDoesNotDescribeDispatchedPOSTAsOrdinaryFailure() {
        XCTAssertEqual(
            CompanionError.uncertainWriteOutcome.description,
            "写入已发出，但暂时无法确认结果。不要重复执行；稍后重新预览，已经写入的内容会显示为一致。"
        )
    }

    func testReceiptPreservesConfirmedAndRecoveredOutcomes() {
        let result = ExecutionSummary(
            group: .create,
            succeeded: 2,
            failed: 0,
            cancelled: false,
            stalePreview: false,
            results: [
                ItemExecutionResult(spelling: "one", outcome: .confirmed),
                ItemExecutionResult(spelling: "two", outcome: .recovered),
            ]
        )

        let receipt = ExecutionReceipt(
            operationGroup: .create,
            selectedSpellings: ["one", "two"],
            result: result
        )

        XCTAssertEqual(receipt.items.map(\.spelling), ["one", "two"])
        XCTAssertEqual(receipt.items.map(\.finalOutcome), [.confirmed, .recovered])
        XCTAssertEqual(receipt.succeeded, 2)
        XCTAssertEqual(receipt.failed, 0)
        XCTAssertEqual(receipt.notAttempted, 0)
        XCTAssertFalse(receipt.stopped)
        XCTAssertEqual(receipt.contentKind, .interpretation)
    }

    func testInterpretationTailCancellationKeepsPrePhraseCompletionSemantics() {
        let result = ExecutionSummary(
            group: .create,
            succeeded: 2,
            failed: 0,
            cancelled: true,
            stalePreview: false,
            results: [
                ItemExecutionResult(spelling: "one", outcome: .confirmed),
                ItemExecutionResult(spelling: "two", outcome: .recovered),
            ]
        )

        let receipt = ExecutionReceipt(
            operationGroup: .create,
            selectedSpellings: ["one", "two"],
            result: result
        )

        XCTAssertEqual(receipt.contentKind, .interpretation)
        XCTAssertTrue(receipt.stopped, "the tail cancellation remains visible in History")
        XCTAssertTrue(
            receipt.isFullSuccess,
            "all verified interpretation items retain the pre-#84 completion contract"
        )
    }

    func testPartialReceiptCountsFailureAndFillsMissingTailAsNotAttempted() {
        let result = ExecutionSummary(
            group: .update,
            succeeded: 1,
            failed: 1,
            cancelled: false,
            stalePreview: false,
            results: [
                ItemExecutionResult(spelling: "one", outcome: .confirmed),
                ItemExecutionResult(spelling: "two", outcome: .notVerified),
            ]
        )

        let receipt = ExecutionReceipt(
            operationGroup: .update,
            selectedSpellings: ["one", "two", "three"],
            result: result
        )

        XCTAssertEqual(
            receipt.items.map(\.finalOutcome),
            [.confirmed, .notVerified, .notAttempted]
        )
        XCTAssertEqual(receipt.succeeded, 1)
        XCTAssertEqual(receipt.failed, 1)
        XCTAssertEqual(receipt.notAttempted, 1)
        XCTAssertTrue(receipt.stopped)
    }

    @MainActor
    func testFileStoreRoundTripSurvivesViewModelReconstructionNewestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileHistoryStore(applicationSupportDirectory: root)
        let older = receipt(at: 100, spelling: "older")
        let newer = receipt(at: 200, spelling: "newer")
        try store.saveReceipts([older, newer])

        let first = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: store
        )
        let reconstructed = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: FileHistoryStore(applicationSupportDirectory: root)
        )

        XCTAssertEqual(first.history.map { $0.items[0].spelling }, ["newer", "older"])
        XCTAssertEqual(reconstructed.history, first.history)
    }

    func testHistoryEncodingContainsNoCredentialBindingRequestOrInterpretationData() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FileHistoryStore(applicationSupportDirectory: root)
        try store.saveReceipts([receipt(at: 100, spelling: "safe-word")])
        let fileURL = root
            .appendingPathComponent("com.davidqyc.momoMoreEfficient", isDirectory: true)
            .appendingPathComponent("history-v1.json")
        let encoded = try String(contentsOf: fileURL, encoding: .utf8)

        for forbidden in [
            fakeToken,
            "credentialFingerprint",
            "credential_fingerprint",
            "vocabularyID",
            "vocabulary_id",
            "recordID",
            "record_id",
            "bindingDigest",
            "binding_digest",
            "batchDigest",
            "batch_digest",
            "requestBody",
            "request_body",
            "interpretationBody",
            "/open/api/",
            "Authorization",
        ] {
            XCTAssertFalse(encoded.contains(forbidden), forbidden)
        }
        XCTAssertTrue(encoded.contains("safe-word"))
        XCTAssertTrue(encoded.contains("\"version\":1"))
    }

    func testLegacyHistoryV1WithoutContentKindDefaultsToInterpretation() throws {
        let json = """
        {
          "version": 1,
          "receipts": [{
            "id": "00000000-0000-0000-0000-000000000001",
            "timestamp": "2026-08-10T00:00:00Z",
            "operationGroup": "create",
            "succeeded": 1,
            "failed": 0,
            "notAttempted": 0,
            "stopped": false,
            "items": [{"spelling":"legacy","finalOutcome":"confirmed"}]
          }]
        }
        """
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "com.davidqyc.momoMoreEfficient",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: directory.appendingPathComponent("history-v1.json"))

        let receipts = try FileHistoryStore(applicationSupportDirectory: root).loadReceipts()

        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].contentKind, .interpretation)
        XCTAssertEqual(receipts[0].items.map(\.spelling), ["legacy"])
        XCTAssertEqual(receipts[0].unconfirmed, 0)
        XCTAssertEqual(receipts[0].diagnosticEnvironment, .legacy)
    }

    func testPhraseAndInterpretationReceiptsPreserveSharedDiagnosticData() throws {
        let interpretationDiagnostic = WriteAttemptDiagnostic(
            ordinal: 2,
            postDispatch: .clean2xx,
            readbackAttempts: [ReadbackAttemptDiagnostic(category: .success)],
            terminalErrorCategory: nil
        )
        let interpretationReceipt = ExecutionReceipt(
            operationGroup: .update,
            selectedSpellings: ["word"],
            result: ExecutionSummary(
                group: .update,
                succeeded: 1,
                failed: 0,
                cancelled: false,
                stalePreview: false,
                results: [ItemExecutionResult(
                    spelling: "word",
                    outcome: .confirmed,
                    diagnostic: interpretationDiagnostic
                )]
            )
        )

        let phraseDiagnostic = WriteAttemptDiagnostic(
            ordinal: 4,
            postDispatch: .uncertain,
            readbackAttempts: [ReadbackAttemptDiagnostic(
                category: .targetNotVisible,
                phraseFacts: PhraseReadbackFacts(
                    activeRecordCount: 2,
                    sameEnglishCount: 0,
                    mismatchKeys: []
                )
            )],
            terminalErrorCategory: .transport
        )
        let phraseReceipt = ExecutionReceipt(
            selectedSpellings: ["phrase-word"],
            result: PhraseExecutionSummary(
                succeeded: 0,
                failed: 1,
                cancelled: false,
                stalePreview: false,
                results: [PhraseItemExecutionResult(
                    spelling: "phrase-word",
                    outcome: .notVerified,
                    observations: [],
                    diagnostic: phraseDiagnostic
                )]
            )
        )

        let data = try JSONEncoder().encode([interpretationReceipt, phraseReceipt])
        let decoded = try JSONDecoder().decode([ExecutionReceipt].self, from: data)

        XCTAssertEqual(decoded[0].items[0].diagnostic, interpretationDiagnostic)
        XCTAssertEqual(decoded[1].items[0].diagnostic, phraseDiagnostic)
        XCTAssertEqual(decoded[1].unconfirmed, 1)
        XCTAssertEqual(decoded[1].failed, 0)
    }

    func testSanitizedDiagnosticExportContainsUsefulMetadataWithoutSecretsOrRawIDs() {
        let environment = DiagnosticEnvironment(
            appVersion: "1.2",
            appBuild: "42",
            systemVersion: "iOS 26.5"
        )
        let diagnostic = WriteAttemptDiagnostic(
            ordinal: 4,
            postDispatch: .clean2xx,
            readbackAttempts: [
                ReadbackAttemptDiagnostic(
                    category: .targetNotVisible,
                    phraseFacts: PhraseReadbackFacts(
                        activeRecordCount: 3,
                        sameEnglishCount: 0,
                        mismatchKeys: []
                    )
                ),
                ReadbackAttemptDiagnostic(
                    category: .intendedStateMismatch,
                    phraseFacts: PhraseReadbackFacts(
                        activeRecordCount: 4,
                        sameEnglishCount: 1,
                        mismatchKeys: [.chinese, .source]
                    )
                ),
            ],
            terminalErrorCategory: .responseRejected
        )
        let receipt = ExecutionReceipt(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            selectedSpellings: ["board directors"],
            result: PhraseExecutionSummary(
                succeeded: 0,
                failed: 1,
                cancelled: false,
                stalePreview: false,
                results: [PhraseItemExecutionResult(
                    spelling: "board directors",
                    outcome: .notVerified,
                    observations: [],
                    diagnostic: diagnostic
                )]
            ),
            diagnosticEnvironment: environment
        )

        let text = receipt.sanitizedDiagnosticText

        for expected in [
            "版本：1.2 (42)", "iOS：iOS 26.5", "第 4 条：board directors",
            "结果：未确认 [notVerified]", "POST：已发出，收到 2xx [clean2xx]",
            "回读次数：2", "targetNotVisible", "intendedStateMismatch",
            "有效记录 4", "相同英文 1", "chinese,source", "responseRejected",
        ] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        for forbidden in [
            fakeToken, "Bearer ", "Authorization:", "Cookie:",
            "INVALID_RECORD", "INVALID_VOC", "PRIVATE_FULL_PAYLOAD_SENTINEL",
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testPhraseReceiptEncodingContainsOnlyAllowedReceiptFields() throws {
        let summary = PhraseExecutionSummary(
            succeeded: 1,
            failed: 0,
            cancelled: false,
            stalePreview: false,
            results: [
                PhraseItemExecutionResult(
                    spelling: "acquisition",
                    outcome: .confirmed,
                    observations: [.tagsDiffer, .highlightMissing, .chineseRangeUnavailable]
                ),
            ]
        )
        let receipt = ExecutionReceipt(
            selectedSpellings: ["acquisition"],
            result: summary
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(receipt)
        let text = String(decoding: encoded, as: UTF8.self)

        XCTAssertEqual(receipt.contentKind, .phrase)
        XCTAssertTrue(text.contains("\"contentKind\":\"phrase\""))
        for forbidden in [
            "The acquisition", "这次收购", "自编", "tags", "highlight",
            "record", "binding", "request", "response", "INVALID_",
        ] {
            XCTAssertFalse(text.localizedCaseInsensitiveContains(forbidden), forbidden)
        }
    }

    func testFileStoreClearDeletesOnlyHistoryArchive() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let unrelated = root.appendingPathComponent("keep.txt")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: unrelated)
        let store = FileHistoryStore(applicationSupportDirectory: root)
        try store.saveReceipts([receipt(at: 100, spelling: "word")])

        try store.clearReceipts()

        XCTAssertTrue(try store.loadReceipts().isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    }

    private func receipt(at timestamp: TimeInterval, spelling: String) -> ExecutionReceipt {
        ExecutionReceipt(
            timestamp: Date(timeIntervalSince1970: timestamp),
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
}
