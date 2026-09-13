import Foundation
import XCTest
@testable import MomoMoreEfficient

@MainActor
final class PhraseSafetyJournalTests: XCTestCase {
    private let vocID = "JOURNAL_VOC_SENTINEL"
    private let providerID = "JOURNAL_PROVIDER_SENTINEL"
    private var entry: PhraseBatchEntry {
        PhraseBatchEntry(ordinal: 1, spelling: "sample", normalizedSpelling: "sample",
                         english: "A synthetic sample EN_SENTINEL.", chinese: "合成中文ZH_SENTINEL。", source: "SOURCE_SENTINEL")
    }

    func testEnglishScalarDiffSubstitutionAndEndInsertionDeletion() {
        let substitution = PhraseEnglishScalarDiff(expected: "abc", returned: "axc")
        XCTAssertEqual(substitution.expectedScalarCount, 3)
        XCTAssertEqual(substitution.returnedScalarCount, 3)
        XCTAssertEqual(substitution.commonPrefixScalarCount, 1)
        XCTAssertEqual(substitution.commonSuffixScalarCount, 1)
        XCTAssertEqual(substitution.expectedFirstDifferenceScalar, 0x0062)
        XCTAssertEqual(substitution.returnedFirstDifferenceScalar, 0x0078)
        XCTAssertEqual(
            substitution.compactDescription,
            "expectedLen=3 returnedLen=3 prefix=1 suffix=1 expected=U+0062 returned=U+0078"
        )

        let insertion = PhraseEnglishScalarDiff(expected: "ab", returned: "abX")
        XCTAssertEqual(insertion.expectedScalarCount, 2)
        XCTAssertEqual(insertion.returnedScalarCount, 3)
        XCTAssertEqual(insertion.commonPrefixScalarCount, 2)
        XCTAssertEqual(insertion.commonSuffixScalarCount, 0)
        XCTAssertNil(insertion.expectedFirstDifferenceScalar)
        XCTAssertEqual(insertion.returnedFirstDifferenceScalar, 0x0058)
        XCTAssertTrue(insertion.compactDescription.contains("expected=none returned=U+0058"))

        let deletion = PhraseEnglishScalarDiff(expected: "abX", returned: "ab")
        XCTAssertEqual(deletion.expectedScalarCount, 3)
        XCTAssertEqual(deletion.returnedScalarCount, 2)
        XCTAssertEqual(deletion.commonPrefixScalarCount, 2)
        XCTAssertEqual(deletion.commonSuffixScalarCount, 0)
        XCTAssertEqual(deletion.expectedFirstDifferenceScalar, 0x0058)
        XCTAssertNil(deletion.returnedFirstDifferenceScalar)
        XCTAssertTrue(deletion.compactDescription.contains("expected=U+0058 returned=none"))
    }

    func testEnglishScalarDiffMiddleChangesKeepNonoverlappingSuffix() {
        let insertion = PhraseEnglishScalarDiff(expected: "abc", returned: "abXc")
        XCTAssertEqual(insertion.commonPrefixScalarCount, 2)
        XCTAssertEqual(insertion.commonSuffixScalarCount, 1)
        XCTAssertEqual(insertion.expectedFirstDifferenceScalar, 0x0063)
        XCTAssertEqual(insertion.returnedFirstDifferenceScalar, 0x0058)

        let deletion = PhraseEnglishScalarDiff(expected: "abXc", returned: "abc")
        XCTAssertEqual(deletion.commonPrefixScalarCount, 2)
        XCTAssertEqual(deletion.commonSuffixScalarCount, 1)
        XCTAssertEqual(deletion.expectedFirstDifferenceScalar, 0x0058)
        XCTAssertEqual(deletion.returnedFirstDifferenceScalar, 0x0063)
    }

    func testEnglishScalarDiffDoesNotNormalizeApostrophesUnicodeOrWhitespace() {
        let apostrophe = PhraseEnglishScalarDiff(expected: "can't", returned: "can’t")
        XCTAssertEqual(apostrophe.expectedFirstDifferenceScalar, 0x0027)
        XCTAssertEqual(apostrophe.returnedFirstDifferenceScalar, 0x2019)
        XCTAssertTrue(apostrophe.compactDescription.contains("expected=U+0027 returned=U+2019"))

        let canonical = PhraseEnglishScalarDiff(expected: "\u{00E9}", returned: "e\u{0301}")
        XCTAssertEqual(canonical.expectedScalarCount, 1)
        XCTAssertEqual(canonical.returnedScalarCount, 2)
        XCTAssertEqual(canonical.expectedFirstDifferenceScalar, 0x00E9)
        XCTAssertEqual(canonical.returnedFirstDifferenceScalar, 0x0065)

        let leadingSpace = PhraseEnglishScalarDiff(expected: "abc", returned: " abc")
        XCTAssertEqual(leadingSpace.commonPrefixScalarCount, 0)
        XCTAssertEqual(leadingSpace.commonSuffixScalarCount, 3)
        XCTAssertEqual(leadingSpace.returnedFirstDifferenceScalar, 0x0020)

        let trailingSpace = PhraseEnglishScalarDiff(expected: "abc", returned: "abc ")
        XCTAssertEqual(trailingSpace.commonPrefixScalarCount, 3)
        XCTAssertEqual(trailingSpace.commonSuffixScalarCount, 0)
        XCTAssertNil(trailingSpace.expectedFirstDifferenceScalar)
        XCTAssertEqual(trailingSpace.returnedFirstDifferenceScalar, 0x0020)

        let nonBMP = PhraseEnglishScalarDiff(expected: "a", returned: "😀")
        XCTAssertTrue(nonBMP.compactDescription.contains("returned=U+1F600"))
    }

    func testResponseProofPersistsBeforeReadbackAndSurvivesFreshStoreAndPreview() async throws {
        let directory = temporaryDirectory()
        let store = FilePhraseSafetyJournalStore(applicationSupportDirectory: directory)
        let journal = PhraseSafetyJournal(store: store)
        let shown = try await snapshot(journal: journal)
        let transport = ObservingPhraseTransport(replies: executionReplies(post: createResponse(), reads: [[], [], []])) {
            XCTAssertEqual(try store.load().count, 1, "proof must reach disk BEFORE authenticated readback")
        }
        let result = try await execute(shown, journal: journal, transport: transport)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(result.isFullSuccess)
        XCTAssertEqual(result.results[0].outcome, .confirmed)
        XCTAssertEqual(result.results[0].diagnostic?.phraseCreateResponse, .proven)
        XCTAssertEqual(result.results[0].diagnostic?.readbackAttempts.map(\.category), [.targetNotVisible, .targetNotVisible, .targetNotVisible])
        XCTAssertTrue(result.results[0].observations.contains(.listVisibilityPending))
        XCTAssertNil(result.feedbackMessage)
        XCTAssertEqual(transport.base.postCount, 1)
        let restarted = PhraseSafetyJournal(store: FilePhraseSafetyJournalStore(applicationSupportDirectory: directory))
        let next = try await snapshot(journal: restarted)
        XCTAssertEqual(next.items[0].classification, .alreadyMatching)
        XCTAssertTrue(next.presentation.rows[0].observations.contains(.listVisibilityPending))
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: next))
        let noCalls = FakeHTTPTransport([vocabulary(), empty()])
        let again = try await execute(shown, journal: restarted, transport: noCalls)
        XCTAssertTrue(again.stalePreview || again.terminalError != nil)
        XCTAssertEqual(noCalls.postCount, 0)
    }

    func testJournalBytesContainOnlyDigestsAndClosedMetadata() throws {
        let directory = temporaryDirectory()
        let store = FilePhraseSafetyJournalStore(applicationSupportDirectory: directory)
        let journal = PhraseSafetyJournal(store: store)
        let fingerprint = try fingerprint()
        try journal.recordCreated(record(), accountFingerprint: fingerprint, vocabularyID: vocID)
        let bytes = try Data(contentsOf: journalURL(directory))
        let text = String(decoding: bytes, as: UTF8.self)
        for value in [fakeToken, fingerprint, vocID, providerID, entry.spelling, entry.english, entry.chinese, entry.source!] {
            XCTAssertFalse(text.contains(value), "private input must not be persisted")
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "entries"])
        let encodedEntry = try XCTUnwrap((object["entries"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(encodedEntry.keys), ["accountScopeDigest", "vocabularyDigest", "phraseIdentityDigest",
            "sourceIndependentPhraseDigest", "englishDigest", "providerPhraseIDDigest", "createdAt"])
        XCTAssertTrue(try store.load()[0].isValid)
    }

    func testRestartedViewModelHistoryClearAndAccountReplacementKeepProtectionScoped() async throws {
        let directory = temporaryDirectory()
        let journal = PhraseSafetyJournal(store: FilePhraseSafetyJournalStore(applicationSupportDirectory: directory))
        try journal.recordCreated(record(), accountFingerprint: fingerprint(), vocabularyID: vocID)
        let history = FileHistoryStore(applicationSupportDirectory: directory)
        try history.saveReceipts([])
        // New ViewModel and new store object simulate reloading process-local state.
        let restarted = PhraseSafetyJournal(store: FilePhraseSafetyJournalStore(applicationSupportDirectory: directory))
        let model = model(journal: restarted, history: history)
        model.clearHistory()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("com.davidqyc.momoMoreEfficient/history-v1.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL(directory).path))
        await model.previewCurrentInput()
        XCTAssertEqual(model.phrasePreview?.alreadyMatchingCount, 1)
        XCTAssertFalse(model.canExecutePhrase)
        model.askToExecutePhrase()
        XCTAssertNil(model.pendingPhraseConfirmation)
        var other = "FAKE_OTHER_JOURNAL_ACCOUNT_NOT_VALID"
        model.installVerifiedCredentialForTesting(token: &other)
        await model.previewCurrentInput()
        XCTAssertEqual(model.phrasePreview?.createCount, 1)
        model.removeToken()
        var original = fakeToken
        model.installVerifiedCredentialForTesting(token: &original)
        await model.previewCurrentInput()
        XCTAssertEqual(model.phrasePreview?.alreadyMatchingCount, 1)
        XCTAssertEqual(try FilePhraseSafetyJournalStore(applicationSupportDirectory: directory).load().count, 1)
    }

    func testVisibleProviderIDRetiresPendingAndDeletedIDDoesNotConsumeCapacity() async throws {
        for deleted in [false, true] {
            let store = TestPhraseJournalStore()
            let journal = PhraseSafetyJournal(store: store)
            try journal.recordCreated(record(), accountFingerprint: fingerprint(), vocabularyID: vocID)
            var visible = rawRecord()
            if deleted { visible["status"] = "DELETED" }
            let preview = try await snapshot(journal: journal, visible: [visible])
            XCTAssertEqual(preview.items[0].classification, deleted ? .create : .alreadyMatching)
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertFalse(preview.presentation.rows[0].observations.contains(.listVisibilityPending))
        }
    }

    func testRetirementFailureDoesNotDoubleCountVisibleResourceAndRemainsConservativeOnMiss() async throws {
        let store = TestPhraseJournalStore()
        let journal = PhraseSafetyJournal(store: store)
        try journal.recordCreated(record(), accountFingerprint: fingerprint(), vocabularyID: vocID)
        store.failSave = true
        let visible = [rawRecord()] + otherRecords(3)
        let preview = try await snapshot(entries: [otherEntry(ordinal: 2)], journal: journal, visible: visible)
        XCTAssertEqual(preview.createCount, 1, "four visible resources, not four plus the visible pending ID")
        XCTAssertEqual(store.entries.count, 1, "failed retirement left durable evidence")
        let hiddenAgain = try await snapshot(entries: [otherEntry(ordinal: 2)], journal: journal, visible: otherRecords(4))
        XCTAssertEqual(hiddenAgain.items[0].reason, "ACTIVE_CAPACITY_REACHED")
    }

    func testHiddenPendingCapacityAndCumulativePlanReservations() async throws {
        let store = TestPhraseJournalStore()
        let journal = PhraseSafetyJournal(store: store)
        try journal.recordCreated(record(), accountFingerprint: fingerprint(), vocabularyID: vocID)
        for (visibleCount, reason) in [(4, "ACTIVE_CAPACITY_REACHED"), (5, "ACTIVE_CAPACITY_EXCEEDED")] {
            let preview = try await snapshot(entries: [otherEntry(ordinal: 2)], journal: journal, visible: otherRecords(visibleCount))
            XCTAssertEqual(preview.createCount, 0)
            XCTAssertEqual(preview.items[0].reason, reason)
            XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: preview))
        }
        let two = try await snapshot(entries: [otherEntry(ordinal: 2), otherEntry(ordinal: 3)], journal: journal, visible: otherRecords(3))
        XCTAssertEqual(two.items.map(\.classification), [.create, .blocked])
        XCTAssertEqual(two.items[1].reason, "ACTIVE_CAPACITY_REACHED")
        let duplicate = try await snapshot(entries: [otherEntry(ordinal: 2), otherEntry(ordinal: 2)], journal: journal)
        XCTAssertEqual(duplicate.items.map(\.classification), [.create, .blocked])
        XCTAssertEqual(duplicate.items[1].reason, "DUPLICATE_PLANNED_ENGLISH")
    }

    func testPendingMatchesRespectOptionalSourceAndSameEnglishConflicts() async throws {
        let journal = makeTestPhraseJournal()
        try journal.recordCreated(record(), accountFingerprint: fingerprint(), vocabularyID: vocID)
        let noSource = PhraseBatchEntry(ordinal: 1, spelling: entry.spelling, normalizedSpelling: entry.normalizedSpelling,
            english: entry.english, chinese: entry.chinese, source: nil)
        let withoutSource = try await snapshot(entries: [noSource], journal: journal)
        XCTAssertEqual(withoutSource.alreadyMatchingCount, 1)
        let conflict = PhraseBatchEntry(ordinal: 1, spelling: entry.spelling, normalizedSpelling: entry.normalizedSpelling,
            english: entry.english, chinese: "不同翻译。", source: entry.source)
        let conflicting = try await snapshot(entries: [conflict], journal: journal)
        XCTAssertEqual(conflicting.items[0].reason, "CONFLICTING_SAME_ENGLISH")
        var visibleSameEnglish = rawRecord()
        visibleSameEnglish["id"] = "ANOTHER_PROVIDER_ID"
        let ambiguous = try await snapshot(journal: journal, visible: [visibleSameEnglish])
        XCTAssertEqual(ambiguous.items[0].reason, "AMBIGUOUS_SAME_ENGLISH")
    }

    func testCorruptUnsupportedOrMalformedDigestJournalBlocksBeforePOST() async throws {
        let shown = try await snapshot(journal: makeTestPhraseJournal())
        for invalid in [Data("not json".utf8), Data(#"{"schemaVersion":99,"entries":[]}"#.utf8),
                        Data(#"{"schemaVersion":1,"entries":[{}]}"#.utf8)] {
            let directory = temporaryDirectory()
            try FileManager.default.createDirectory(at: journalURL(directory).deletingLastPathComponent(), withIntermediateDirectories: true)
            try invalid.write(to: journalURL(directory))
            let journal = PhraseSafetyJournal(store: FilePhraseSafetyJournalStore(applicationSupportDirectory: directory))
            let preview = try await snapshot(journal: journal)
            XCTAssertEqual(preview.items[0].reason, "JOURNAL_UNAVAILABLE")
            let transport = FakeHTTPTransport([])
            let result = try await execute(shown, journal: journal, transport: transport)
            XCTAssertEqual(result.terminalError, .phraseJournalUnavailable)
            XCTAssertTrue(result.feedbackMessage?.contains("本机例句安全记录") == true)
            XCTAssertEqual(transport.postCount, 0)
            XCTAssertEqual(try Data(contentsOf: journalURL(directory)), invalid, "must not overwrite invalid safety authority")
        }
    }

    func testKnownUnwritableJournalPreventsApprovalAndDispatch() async throws {
        let store = TestPhraseJournalStore()
        let journal = PhraseSafetyJournal(store: store)
        let shown = try await snapshot(journal: journal)
        store.failSave = true
        let transport = FakeHTTPTransport([])
        let result = try await execute(shown, journal: journal, transport: transport)
        XCTAssertEqual(result.terminalError, .phraseJournalUnavailable)
        XCTAssertEqual(transport.postCount, 0)
        let model = model(journal: journal)
        await model.previewCurrentInput()
        model.askToExecutePhrase()
        XCTAssertNil(model.pendingPhraseConfirmation)
        XCTAssertTrue(model.errorMessage?.contains("本机例句安全记录") == true)
        // Real file-path write failure too: the designated support directory is a file.
        let invalidSupport = temporaryDirectory().appendingPathComponent("file-not-directory")
        try Data().write(to: invalidSupport)
        XCTAssertThrowsError(try PhraseSafetyJournal(store: FilePhraseSafetyJournalStore(applicationSupportDirectory: invalidSupport)).prepareForCreate())
    }

    func testPersistenceFailureAfterResponsePreservesCreatedTruthAndLatchesOffMoreCreates() async throws {
        let store = TestPhraseJournalStore()
        let journal = PhraseSafetyJournal(store: store)
        let shown = try await snapshot(journal: journal)
        store.failSaveNumber = 3 // batch writability, per-item writability, proven-create persistence
        let transport = FakeHTTPTransport(executionReplies(post: createResponse(), reads: [[], [], []]))
        let result = try await execute(shown, journal: journal, transport: transport)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.results[0].outcome, .confirmed)
        XCTAssertEqual(result.terminalError, .phraseJournalProtectionFailed)
        XCTAssertTrue(result.feedbackMessage?.contains("已创建") == true)
        XCTAssertTrue(result.feedbackMessage?.contains("保护未能保存") == true)
        XCTAssertEqual(result.results[0].diagnostic?.readbackAttempts.count, 3)
        XCTAssertEqual(transport.postCount, 1)
        let stopped = FakeHTTPTransport([])
        let next = try await execute(shown, journal: journal, transport: stopped)
        XCTAssertEqual(next.terminalError, .phraseJournalProtectionFailed)
        XCTAssertEqual(stopped.postCount, 0)
    }

    func testMalformedMismatchingAndUnsafeCreateResponsesRequireGETProof() async throws {
        var mismatch = rawRecord(); mismatch["interpretation"] = "不同翻译。"
        var unsafe = rawRecord(); unsafe["id"] = "unsafe/id"
        let cases: [StubbedResult] = [jsonResponse([:], status: 201),
            jsonResponse(["phrase": mismatch], status: 201), jsonResponse(["phrase": unsafe], status: 201),
            jsonResponse(["success": false, "data": ["phrase": rawRecord()]], status: 201),
            jsonResponse(["success": 1, "data": ["phrase": rawRecord()]], status: 201),
            jsonResponse(["phrase": rawRecord(), "data": ["phrase": rawRecord()]], status: 201)]
        for post in cases {
            for visible in [true, false] {
                let journal = makeTestPhraseJournal()
                let shown = try await snapshot(journal: journal)
                let transport = FakeHTTPTransport(executionReplies(post: post, reads: visible ? [[rawRecord()]] : [[], [], []]))
                let result = try await execute(shown, journal: journal, transport: transport)
                XCTAssertEqual(result.succeeded, visible ? 1 : 0)
                XCTAssertEqual(result.results[0].outcome, visible ? .confirmed : .notVerified)
                XCTAssertEqual(transport.postCount, 1)
                if !visible { XCTAssertTrue(result.feedbackMessage?.contains("请勿重复提交") == true) }
            }
        }
    }

    func testHTTPAuthRateServerTransportAndReadSchemaFeedbackStaySpecific() async throws {
        let cases: [(StubbedResult, [StubbedResult], CompanionError, String)] = [
            (jsonResponse([:], status: 400), [empty(), empty(), empty()], .globalHTTPFailure, "拒绝了本次例句"),
            (jsonResponse([:], status: 401), [empty(), empty(), empty()], .authenticationRejected, "Token"),
            (jsonResponse([:], status: 429), [empty(), empty(), empty()], .rateLimited, "过于频繁"),
            (jsonResponse([:], status: 503), [empty(), empty(), empty()], .serverFailure, "服务暂时不可用"),
            (.failure(.transport), [empty(), empty(), empty()], .transport, "网络请求失败"),
            (jsonResponse([:], status: 201), [jsonResponse(["unexpected": []])], .responseRejected, "返回内容无法安全读取"),
        ]
        for (post, reads, expected, copy) in cases {
            let journal = makeTestPhraseJournal()
            let shown = try await snapshot(journal: journal)
            let transport = FakeHTTPTransport([vocabulary(), empty(), post] + reads)
            let result = try await execute(shown, journal: journal, transport: transport)
            XCTAssertEqual(result.terminalError, expected)
            XCTAssertEqual(result.succeeded, 0)
            XCTAssertTrue(result.feedbackMessage?.contains(copy) == true)
            XCTAssertTrue(result.feedbackMessage?.contains("请勿重复提交") == true)
            XCTAssertEqual(transport.postCount, 1)
        }
    }

    func testProvenResponseWithOverCapacityReadbackStopsNextItemWithoutLosingSuccess() async throws {
        let journal = makeTestPhraseJournal()
        let shown = try await snapshot(entries: [entry, otherEntry(ordinal: 2)], journal: journal)
        let five = jsonResponse(["phrases": otherRecords(5)])
        let transport = FakeHTTPTransport([vocabulary(), empty(), empty(), createResponse(), five, five, five])
        let result = try await execute(shown, journal: journal, transport: transport)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.terminalError, .blocked)
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertTrue(result.feedbackMessage?.contains("超过安全上限 5 条") == true)
    }

    func testViewModelLagIsSuccessAndJournalFailureDoesNotBreakInterpretationOrQueryReads() async throws {
        let journal = makeTestPhraseJournal()
        let transport = FakeHTTPTransport([vocabulary(), empty()] + executionReplies(post: createResponse(), reads: [[], [], []]))
        let model = model(journal: journal, transport: transport)
        await model.previewCurrentInput()
        model.askToExecutePhrase()
        await model.executeConfirmedPhrase()?.value
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.completionAcknowledgement?.contains("已完成 1 条例句") == true)
        XCTAssertTrue(model.phraseObservationMessage?.contains("墨墨列表暂未同步") == true)
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(model.history.first?.items.first?.diagnostic?.phraseCreateResponse, .proven)
        let corrupt = TestPhraseJournalStore(); corrupt.failLoad = true
        let corruptJournal = PhraseSafetyJournal(store: corrupt)
        let lease = try credentialLease(); defer { lease.clear() }
        let reads = FakeHTTPTransport([jsonResponse(["phrases": [rawRecord()]]), jsonResponse(["interpretations": []])])
        let api = MaimemoTransport(transport: reads, credential: lease, phraseSafetyJournal: corruptJournal, sleeper: RecordingSleeper())
        let phrases = try await api.phrases(vocabularyID: vocID)
        let interpretations = try await api.interpretations(vocabularyID: vocID)
        XCTAssertEqual(phrases.count, 1)
        XCTAssertTrue(interpretations.isEmpty)
        XCTAssertEqual(reads.postCount, 0)
    }

    func testBothCreateEnvelopesConfirmVisibleIDAndRetireWithoutDoubleCounting() async throws {
        for wrapped in [false, true] {
            let store = TestPhraseJournalStore()
            let journal = PhraseSafetyJournal(store: store)
            let shown = try await snapshot(journal: journal)
            let body: [String: Any] = wrapped
                ? ["success": true, "errors": [], "data": ["phrase": rawRecord()]]
                : ["phrase": rawRecord()]
            let transport = FakeHTTPTransport(executionReplies(post: jsonResponse(body, status: 201), reads: [[rawRecord()]]))
            let result = try await execute(shown, journal: journal, transport: transport)
            XCTAssertTrue(result.isFullSuccess)
            XCTAssertEqual(result.results[0].diagnostic?.phraseCreateResponse, .proven)
            XCTAssertFalse(result.results[0].observations.contains(.listVisibilityPending))
            XCTAssertTrue(store.entries.isEmpty)
            XCTAssertEqual(transport.postCount, 1)
        }
    }

    func testProvenCreateWithAuthReadFailureStillRecordsCreatedTruthWithoutClaimingListLag() async throws {
        let journal = makeTestPhraseJournal()
        let shown = try await snapshot(journal: journal)
        let transport = FakeHTTPTransport([vocabulary(), empty(), createResponse(), jsonResponse([:], status: 401)])
        let result = try await execute(shown, journal: journal, transport: transport)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.terminalError, .authenticationRejected)
        XCTAssertFalse(result.results[0].observations.contains(.listVisibilityPending))
        XCTAssertEqual(transport.postCount, 1)
    }

    func testViewModelPostSaveFailureKeepsSuccessfulReceiptAndStopsSubsequentPreview() async throws {
        let store = TestPhraseJournalStore()
        store.failSaveNumber = 4 // native approval probe + executor's two probes + evidence save
        let journal = PhraseSafetyJournal(store: store)
        let transport = FakeHTTPTransport([vocabulary(), empty()] + executionReplies(post: createResponse(), reads: [[], [], []]) + [vocabulary(), empty()])
        let model = model(journal: journal, transport: transport)
        await model.previewCurrentInput()
        model.askToExecutePhrase()
        await model.executeConfirmedPhrase()?.value
        XCTAssertTrue(model.errorMessage?.contains("例句已创建") == true)
        XCTAssertEqual(model.history.first?.succeeded, 1)
        XCTAssertEqual(model.history.first?.failed, 0)
        XCTAssertEqual(model.history.first?.stopped, true)
        await model.previewCurrentInput()
        XCTAssertEqual(model.phrasePreview?.blockedCount, 1)
        XCTAssertFalse(model.canExecutePhrase)
        XCTAssertEqual(transport.postCount, 1)
    }

    func testFreshReviewSixthActiveCreateAfterLocallyVisibleFive() async throws {
        let journal = makeTestPhraseJournal()
        let first = otherEntry(ordinal: 2)
        let second = otherEntry(ordinal: 3)
        func raw(_ e: PhraseBatchEntry, id: String) -> [String: Any] {
            ["id": id, "phrase": e.english, "interpretation": e.chinese,
             "tags": [String](), "origin": "", "status": "PUBLISHED"]
        }

        // Preflight sees three active phrases, so the planner reserves two CREATEs
        // (3 + 2 == 5, which is exactly the ceiling and therefore admissible).
        let baseline = otherRecords(3)
        let shown = try await snapshot(entries: [first, second], journal: journal, visible: baseline)
        XCTAssertEqual(shown.items.map(\.classification), [.create, .create])

        let createdFirst = raw(first, id: "CREATED_FIRST")
        // One unit of drift between the fresh preflight read and the first readback.
        // Sources: the Owner adding a phrase on another device, or an earlier create
        // whose response was not verifiable (D-020's declared uncovered window) finally
        // becoming visible. Either way the app now *correctly* reads five active phrases.
        let lateExternal: [String: Any] = ["id": "LATE_EXTERNAL", "phrase": "Late external sample.",
            "interpretation": "合成旧句。", "tags": [String](), "origin": "", "status": "PUBLISHED"]
        let fiveVisible = baseline + [createdFirst, lateExternal]
        let createdSecond = raw(second, id: "CREATED_SECOND")

        let transport = FakeHTTPTransport([
            vocabulary(),
            jsonResponse(["phrases": baseline]),          // fresh preflight, row 1
            jsonResponse(["phrases": baseline]),          // fresh preflight, row 2
            jsonResponse(["phrase": createdFirst], status: 201),   // row 1 POST, response-proven
            jsonResponse(["phrases": fiveVisible]),       // row 1 readback: FIVE active, row 1 visible
            jsonResponse(["phrase": createdSecond], status: 201),  // row 2 POST  <-- the sixth
            jsonResponse(["phrases": fiveVisible + [createdSecond]]),
        ])
        let result = try await execute(shown, journal: journal, transport: transport)

        XCTAssertEqual(transport.postCount, 1,
            "a sixth active CREATE must not be dispatched once local evidence already shows five active phrases")
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(result.results.map(\.outcome), [.confirmed])
        XCTAssertEqual(result.terminalError, .blocked)
        XCTAssertTrue(result.feedbackMessage?.contains("已达到或超过安全上限 5 条") == true)
        let receipt = ExecutionReceipt(selectedSpellings: [first.spelling, second.spelling], result: result)
        XCTAssertEqual(receipt.succeeded, 1)
        XCTAssertEqual(receipt.notAttempted, 1)
        XCTAssertTrue(receipt.stopped)
    }

    func testFifthPhraseWithoutRemainingCreateStaysSuccessful() async throws {
        let journal = makeTestPhraseJournal()
        let baseline = otherRecords(4)
        let shown = try await snapshot(journal: journal, visible: baseline)
        XCTAssertEqual(shown.items.map(\.classification), [.create])
        let transport = FakeHTTPTransport([
            vocabulary(), jsonResponse(["phrases": baseline]),
            createResponse(), jsonResponse(["phrases": baseline + [rawRecord()]])
        ])
        let result = try await execute(shown, journal: journal, transport: transport)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 0)
        XCTAssertNil(result.terminalError)
        XCTAssertNil(result.feedbackMessage)
        XCTAssertTrue(result.isFullSuccess)
        XCTAssertEqual(transport.postCount, 1)
    }

    func testFifthPhraseDoesNotBlockRemainingDifferentVocabularyCreate() async throws {
        let journal = makeTestPhraseJournal()
        let second = PhraseBatchEntry(ordinal: 2, spelling: "another", normalizedSpelling: "another",
            english: "Another synthetic example.", chinese: "另一合成例句。", source: nil)
        let secondID = "ANOTHER_VOCABULARY"
        let resolver = vocabularyQueryResponse([(id: vocID, spelling: entry.spelling), (id: secondID, spelling: second.spelling)])
        let baseline = otherRecords(4)
        let lease = try credentialLease(); defer { lease.clear() }
        let previewTransport = FakeHTTPTransport([resolver, jsonResponse(["phrases": baseline]), empty()])
        let shown = try await PhrasePreflightPlanner(journal: journal,
            api: MaimemoTransport(transport: previewTransport, credential: lease, sleeper: RecordingSleeper()))
            .buildSnapshot(entries: [entry, second], tags: [], credentialFingerprint: lease.fingerprint)
        XCTAssertEqual(shown.items.map(\.classification), [.create, .create])
        XCTAssertEqual(shown.items.map(\.vocabularyID), [vocID, secondID])
        let createdSecond: [String: Any] = ["id": "ANOTHER_CREATED", "phrase": second.english,
            "interpretation": second.chinese, "origin": "", "tags": [String](), "status": "PUBLISHED"]
        let transport = FakeHTTPTransport([
            resolver, jsonResponse(["phrases": baseline]), empty(),
            createResponse(), jsonResponse(["phrases": baseline + [rawRecord()]]),
            jsonResponse(["phrase": createdSecond], status: 201), jsonResponse(["phrases": [createdSecond]])
        ])
        let result = try await execute(shown, journal: journal, transport: transport)
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertNil(result.terminalError)
        XCTAssertNil(result.feedbackMessage)
        XCTAssertTrue(result.isFullSuccess)
        XCTAssertEqual(transport.postCount, 2)
    }

    func testCreateMismatchKeysAreClosedStablePrivateAndStopAfterOnePOST() async throws {
        let changes: [([String: String], [PhraseMismatchKey])] = [
            (["phrase": "RESPONSE_EN_SENTINEL"], [.english]),
            (["interpretation": "RESPONSE_ZH_SENTINEL"], [.chinese]),
            (["origin": "RESPONSE_SOURCE_SENTINEL"], [.source]),
            (["status": "DELETED"], [.status]),
            (["phrase": "RESPONSE_EN_SENTINEL", "interpretation": "RESPONSE_ZH_SENTINEL",
              "origin": "RESPONSE_SOURCE_SENTINEL", "status": "DELETED"], [.english, .chinese, .source, .status])
        ]
        for (fields, keys) in changes {
            let journal = makeTestPhraseJournal()
            let shown = try await snapshot(entries: [entry, otherEntry(ordinal: 2)], journal: journal)
            var response = rawRecord()
            for (field, value) in fields { response[field] = value }
            let transport = FakeHTTPTransport([vocabulary(), empty(), empty(),
                jsonResponse(["phrase": response], status: 201), empty(), empty(), empty()])
            let result = try await execute(shown, journal: journal, transport: transport)
            XCTAssertEqual(result.results.first?.diagnostic?.phraseCreateResponse, .mismatching)
            XCTAssertEqual(result.results.first?.diagnostic?.phraseCreateMismatchKeys, keys)
            let scalarDiff = result.results.first?.diagnostic?.phraseEnglishScalarDiff
            let expectedScalarDiff = keys.contains(.english)
                ? PhraseEnglishScalarDiff(expected: entry.english, returned: "RESPONSE_EN_SENTINEL")
                : nil
            XCTAssertEqual(scalarDiff, expectedScalarDiff)
            XCTAssertEqual(result.results.map(\.outcome), [.notVerified])
            XCTAssertEqual(result.succeeded, 0)
            XCTAssertEqual(result.failed, 1)
            XCTAssertEqual(transport.postCount, 1)
            XCTAssertEqual(result.results.first?.diagnostic?.readbackAttempts.count, 3)
            let fieldList = keys.map(\.rawValue).joined(separator: ",")
            XCTAssertTrue(result.feedbackMessage?.contains("字段：" + fieldList) == true)
            XCTAssertTrue(result.feedbackMessage?.contains("已停止后续新建") == true)
            XCTAssertTrue(result.feedbackMessage?.contains("请勿重复提交") == true)
            let receipt = ExecutionReceipt(selectedSpellings: shown.items.map { $0.entry.spelling }, result: result)
            XCTAssertEqual(receipt.notAttempted, 1)
            let data = try JSONEncoder().encode(receipt)
            let decoded = try JSONDecoder().decode(ExecutionReceipt.self, from: data)
            XCTAssertEqual(decoded.items[0].diagnostic?.phraseCreateMismatchKeys, keys)
            XCTAssertEqual(decoded.items[0].diagnostic?.phraseEnglishScalarDiff, scalarDiff)
            let text = decoded.sanitizedDiagnosticText
            XCTAssertTrue(text.contains("创建响应不一致字段：" + fieldList))
            XCTAssertEqual(text.contains("english差异："), keys.contains(.english))
            for forbidden in [fakeToken, providerID, vocID, try fingerprint(), entry.english, entry.chinese,
                              entry.source!, "RESPONSE_EN_SENTINEL", "RESPONSE_ZH_SENTINEL", "RESPONSE_SOURCE_SENTINEL",
                              "DELETED", "Authorization", "\"phrase\":"] {
                XCTAssertFalse(text.contains(forbidden), forbidden)
                XCTAssertFalse(String(decoding: data, as: UTF8.self).contains(forbidden), forbidden)
                XCTAssertFalse(result.feedbackMessage?.contains(forbidden) == true, forbidden)
            }
            let pending = try journal.pending(accountFingerprint: fingerprint(), vocabularyID: vocID, visible: [])
            XCTAssertTrue(pending.isEmpty)
        }
    }

    func testProvenMalformedAndLegacyCreateDiagnosticsDoNotInventMismatchKeys() async throws {
        for (response, category) in [(createResponse(), PhraseCreateResponseCategory.proven),
                                     (jsonResponse([:], status: 201), .malformed)] {
            let journal = makeTestPhraseJournal()
            let shown = try await snapshot(journal: journal)
            let transport = FakeHTTPTransport(executionReplies(post: response, reads: [[], [], []]))
            let result = try await execute(shown, journal: journal, transport: transport)
            XCTAssertEqual(result.results[0].diagnostic?.phraseCreateResponse, category)
            XCTAssertNil(result.results[0].diagnostic?.phraseCreateMismatchKeys)
            XCTAssertNil(result.results[0].diagnostic?.phraseEnglishScalarDiff)
            let receipt = ExecutionReceipt(selectedSpellings: [entry.spelling], result: result)
            XCTAssertFalse(receipt.sanitizedDiagnosticText.contains("创建响应不一致字段"))
            XCTAssertEqual(result.succeeded, category == .proven ? 1 : 0)
            XCTAssertEqual(transport.postCount, 1)
        }
        // Exact pre-change diagnostic shape: no newly introduced optional key.
        let legacy = Data(#"{"ordinal":1,"postDispatch":{"clean2xx":{"status":201}},"readbackAttempts":[],"phraseCreateResponse":"mismatching"}"#.utf8)
        let diagnostic = try JSONDecoder().decode(WriteAttemptDiagnostic.self, from: legacy)
        XCTAssertNil(diagnostic.phraseCreateMismatchKeys)
        XCTAssertNil(diagnostic.phraseEnglishScalarDiff)
        let summary = PhraseExecutionSummary(succeeded: 0, failed: 1, cancelled: false, stalePreview: false,
            results: [PhraseItemExecutionResult(spelling: "sample", outcome: .notVerified, observations: [], diagnostic: diagnostic)])
        XCTAssertTrue(summary.feedbackMessage?.contains("创建响应与输入不一致") == true)
        XCTAssertTrue(summary.feedbackMessage?.contains("请勿重复提交") == true)
        XCTAssertFalse(summary.feedbackMessage?.contains("字段：") == true)
        let receipt = ExecutionReceipt(selectedSpellings: ["sample"], result: summary)
        XCTAssertFalse(receipt.sanitizedDiagnosticText.contains("创建响应不一致字段"))
        XCTAssertFalse(receipt.sanitizedDiagnosticText.contains("english差异"))
    }

    func testViewModelMismatchFeedbackAndHistoryPreserveClosedFields() async throws {
        var response = rawRecord(); response["phrase"] = "RESPONSE_EN_SENTINEL"; response["origin"] = "RESPONSE_SOURCE_SENTINEL"
        let journal = makeTestPhraseJournal()
        let transport = FakeHTTPTransport([vocabulary(), empty()] + executionReplies(
            post: jsonResponse(["phrase": response], status: 201), reads: [[], [], []]))
        let model = model(journal: journal, transport: transport)
        await model.previewCurrentInput()
        model.askToExecutePhrase()
        await model.executeConfirmedPhrase()?.value
        XCTAssertTrue(model.errorMessage?.contains("字段：english,source") == true)
        XCTAssertTrue(model.errorMessage?.contains("请勿重复提交") == true)
        XCTAssertNil(model.completionAcknowledgement)
        XCTAssertEqual(model.history.first?.items.first?.diagnostic?.phraseCreateMismatchKeys, [.english, .source])
        XCTAssertNotNil(model.history.first?.items.first?.diagnostic?.phraseEnglishScalarDiff)
        XCTAssertEqual(model.history.first?.unconfirmed, 1)
        XCTAssertEqual(model.history.first?.stopped, true)
        XCTAssertEqual(transport.postCount, 1)
    }

    // MARK: - Narrow provider apostrophe identity (#161)

    func testApostropheHardIdentityIsSymmetricAndDoesNotFoldOtherScalarsOrFields() {
        for (expected, returned) in [("A sample isn’t empty.", "A sample isn't empty."),
                                     ("A sample isn't empty.", "A sample isn’t empty.")] {
            let intended = apostropheEntry(expected)
            let provider = apostropheRecord(returned)
            XCTAssertTrue(provider.hardMatches(intended))
            XCTAssertEqual(provider.hardMismatchKeys(intended), [])
        }
        let straight = "A sample isn't empty."
        for different in ["A sample isn‘t empty.", "A sample isnʼt empty.",
                          "A sample  isn't empty.", "a sample isn't empty.",
                          "A sample-isn't empty.", "A sample isn't empty…", "Ａ sample isn't empty."] {
            XCTAssertFalse(apostropheRecord(different).hardMatches(apostropheEntry(straight)))
            XCTAssertEqual(apostropheRecord(different).hardMismatchKeys(apostropheEntry(straight)), [.english])
        }
        XCTAssertFalse(PhraseEnglishIdentity.equivalent("é", "e\u{0301}"), "no implicit NFC equality")
        let intended = apostropheEntry("A sample isn’t empty.", chinese: "ZH’", source: "SOURCE’")
        let provider = PhraseRecord(id: providerID, phrase: straight, interpretation: "ZH'",
            tags: [], origin: "SOURCE'", status: "DELETED", highlight: .missing)
        XCTAssertEqual(provider.hardMismatchKeys(intended), [.chinese, .source, .status])
    }

    func testApostropheResponseProofPersistsAcrossRestartHistoryClearAndLaterVisibility() async throws {
        // Both directions, including mixed apostrophes, must remain protected
        // after a provider response is accepted but the list omits the record.
        for (expected, returned) in [("A sample isn’t empty.", "A sample isn't empty."),
                                     ("A sample isn't empty.", "A sample isn’t empty."),
                                     ("A sample isn't empty; it’s fine.", "A sample isn’t empty; it's fine.")] {
            let intended = apostropheEntry(expected)
            let directory = temporaryDirectory()
            let store = FilePhraseSafetyJournalStore(applicationSupportDirectory: directory)
            let journal = PhraseSafetyJournal(store: store)
            let shown = try await snapshot(entries: [intended], journal: journal)
            let transport = ObservingPhraseTransport(replies: executionReplies(
                post: jsonResponse(["phrase": apostropheRawRecord(returned)], status: 201), reads: [[], [], []])) {
                XCTAssertEqual(try store.load().count, 1, "persist BEFORE the first authenticated GET")
            }
            let result = try await execute(shown, journal: journal, transport: transport)
            XCTAssertEqual(result.succeeded, 1)
            XCTAssertEqual(result.failed, 0)
            XCTAssertEqual(result.results.map(\.outcome), [.confirmed])
            XCTAssertTrue(result.isFullSuccess)
            XCTAssertNil(result.feedbackMessage)
            XCTAssertEqual(result.results[0].diagnostic?.phraseCreateResponse, .proven)
            XCTAssertNil(result.results[0].diagnostic?.phraseCreateMismatchKeys)
            XCTAssertNil(result.results[0].diagnostic?.phraseEnglishScalarDiff)
            XCTAssertEqual(result.results[0].diagnostic?.readbackAttempts.map(\.category),
                           [.targetNotVisible, .targetNotVisible, .targetNotVisible])
            XCTAssertTrue(result.results[0].observations.contains(.listVisibilityPending))
            XCTAssertEqual(transport.base.postCount, 1)
            XCTAssertTrue(transport.base.requests.suffix(3).allSatisfy { !$0.route.isMutating })
            let sent = try XCTUnwrap(transport.base.requests.first { $0.route.isMutating }?.body)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent) as? [String: Any])
            let sentPhrase = try XCTUnwrap((body["phrase"] as? [String: Any])?["phrase"] as? String)
            XCTAssertEqual(Array(sentPhrase.unicodeScalars), Array(expected.unicodeScalars), "exact approved payload")

            let history = FileHistoryStore(applicationSupportDirectory: directory)
            try history.saveReceipts([ExecutionReceipt(selectedSpellings: [entry.spelling], result: result)])
            let restarted = PhraseSafetyJournal(store: FilePhraseSafetyJournalStore(applicationSupportDirectory: directory))
            let model = model(journal: restarted, history: history)
            model.sourceText = "sample\n\(expected)\n\(entry.chinese)\n\(entry.source!)"
            model.clearHistory()
            XCTAssertTrue(try history.loadReceipts().isEmpty)
            await model.previewCurrentInput()
            XCTAssertEqual(model.phrasePreview?.alreadyMatchingCount, 1)
            XCTAssertFalse(model.canExecutePhrase)
            XCTAssertEqual(try store.load().count, 1)
            let hidden = try await snapshot(entries: [intended], journal: restarted)
            XCTAssertEqual(hidden.items[0].classification, .alreadyMatching)
            XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: hidden))
            let retryTransport = FakeHTTPTransport([vocabulary(), empty()])
            let stale = try await execute(shown, journal: restarted, transport: retryTransport)
            XCTAssertTrue(stale.stalePreview || stale.terminalError != nil)
            XCTAssertEqual(retryTransport.postCount, 0)

            // Four others plus the now-visible pending record are five, not six.
            let visible = [apostropheRawRecord(returned)] + otherRecords(4)
            let later = try await snapshot(entries: [intended, otherEntry(ordinal: 2)], journal: restarted, visible: visible)
            XCTAssertEqual(later.items.map(\.classification), [.alreadyMatching, .blocked])
            XCTAssertEqual(later.items[1].reason, "ACTIVE_CAPACITY_REACHED")
            XCTAssertTrue(try store.load().isEmpty, "retire the pending resource by ID")
        }
    }

    func testApostropheVisiblePreviewConflictsAmbiguityAndBatchReservations() async throws {
        let curly = apostropheEntry("A sample isn’t empty.")
        let straight = apostropheEntry("A sample isn't empty.", ordinal: 2)
        for (intended, returned) in [(curly, straight.english), (straight, curly.english)] {
            let shown = try await snapshot(entries: [intended], journal: makeTestPhraseJournal(),
                                           visible: [apostropheRawRecord(returned)])
            XCTAssertEqual(shown.items[0].classification, .alreadyMatching)
        }
        for changedField in ["interpretation", "origin"] {
            var raw = apostropheRawRecord(straight.english)
            raw[changedField] = "DIFFERENT_SYNTHETIC_VALUE"
            let shown = try await snapshot(entries: [curly], journal: makeTestPhraseJournal(), visible: [raw])
            XCTAssertEqual(shown.items[0].reason, "CONFLICTING_SAME_ENGLISH")
        }
        var secondRecord = apostropheRawRecord(curly.english); secondRecord["id"] = "SECOND_SYNTHETIC_ID"
        let ambiguous = try await snapshot(entries: [curly], journal: makeTestPhraseJournal(),
            visible: [apostropheRawRecord(straight.english), secondRecord])
        XCTAssertEqual(ambiguous.items[0].reason, "AMBIGUOUS_SAME_ENGLISH")
        for entries in [[curly, straight], [straight, curly]] {
            let shown = try await snapshot(entries: entries, journal: makeTestPhraseJournal())
            XCTAssertEqual(shown.items.map(\.classification), [.create, .blocked])
            XCTAssertEqual(shown.items[1].reason, "DUPLICATE_PLANNED_ENGLISH")
        }
        XCTAssertNotEqual(try PhraseCreateBinding.sourceIdentity([curly]), try PhraseCreateBinding.sourceIdentity([
            apostropheEntry(straight.english)]), "approval must still bind raw English")
    }

    func testApostropheReadbackUsesSameIdentityForActiveAndDeletedRecords() async throws {
        let intended = apostropheEntry("A sample isn’t empty.")
        for status in ["PUBLISHED", "DELETED"] {
            let journal = makeTestPhraseJournal()
            let shown = try await snapshot(entries: [intended], journal: journal)
            var raw = apostropheRawRecord("A sample isn't empty."); raw["status"] = status
            // An uncertain POST must still depend entirely on authenticated GET.
            let reads = status == "PUBLISHED" ? [[raw]] : [[raw], [raw], [raw]]
            let transport = FakeHTTPTransport(executionReplies(post: .failure(.transport), reads: reads))
            let result = try await execute(shown, journal: journal, transport: transport)
            XCTAssertEqual(transport.postCount, 1)
            XCTAssertEqual(result.results[0].outcome, status == "PUBLISHED" ? .recovered : .notVerified)
            XCTAssertEqual(result.results[0].diagnostic?.readbackAttempts.last?.category,
                           status == "PUBLISHED" ? .success : .targetNotVisible)
            XCTAssertEqual(result.results[0].diagnostic?.readbackAttempts.last?.phraseFacts?.mismatchKeys,
                           status == "PUBLISHED" ? [] : [.status])
        }
    }

    func testLegacyRawJournalCandidatesKeepExactAndCanonicalMatchesWithoutMigration() async throws {
        for (storedEnglish, expectedEnglish) in [("A sample isn’t empty.", "A sample isn’t empty."),
                                                ("A sample isn't empty.", "A sample isn’t empty.")] {
            let directory = temporaryDirectory()
            let store = FilePhraseSafetyJournalStore(applicationSupportDirectory: directory)
            // Construct the OLD raw v1 shape explicitly, independent of today's initializer.
            let old: [String: Any] = [
                "accountScopeDigest": try PhraseSafetyEntry.digest("account", [fingerprint()]),
                "vocabularyDigest": try PhraseSafetyEntry.digest("vocabulary", [vocID]),
                "phraseIdentityDigest": try PhraseSafetyEntry.digest("phrase", [storedEnglish, entry.chinese, entry.source!]),
                "sourceIndependentPhraseDigest": try PhraseSafetyEntry.digest("phrase-no-source", [storedEnglish, entry.chinese]),
                "englishDigest": try PhraseSafetyEntry.digest("english", [storedEnglish]),
                "providerPhraseIDDigest": try PhraseSafetyEntry.digest("provider-id", [providerID]),
                "createdAt": 0
            ]
            let legacy = try JSONDecoder().decode(PhraseSafetyEntry.self, from: JSONSerialization.data(withJSONObject: old))
            try store.save([legacy])
            let before = try Data(contentsOf: journalURL(directory))
            let journal = PhraseSafetyJournal(store: store)
            for source in [entry.source, nil] {
                let expected = apostropheEntry(expectedEnglish, source: source)
                let shown = try await snapshot(entries: [expected], journal: journal)
                XCTAssertEqual(shown.items[0].classification, .alreadyMatching)
                XCTAssertTrue(try legacy.matches(expected))
            }
            XCTAssertFalse(try legacy.matches(apostropheEntry(expectedEnglish, chinese: "CHANGED_ZH")))
            XCTAssertFalse(try legacy.matches(apostropheEntry(expectedEnglish, source: "CHANGED_SOURCE")))
            let conflict = try await snapshot(entries: [apostropheEntry(expectedEnglish, chinese: "CHANGED_ZH")], journal: journal)
            XCTAssertEqual(conflict.items[0].reason, "CONFLICTING_SAME_ENGLISH")
            XCTAssertEqual(try Data(contentsOf: journalURL(directory)), before, "lookup must not rewrite v1 files")
            try journal.recordCreated(apostropheRecord(storedEnglish), accountFingerprint: fingerprint(), vocabularyID: vocID)
            XCTAssertEqual(try Data(contentsOf: journalURL(directory)), before, "reobserving a legacy ID keeps its raw evidence")
        }
    }

    func testNewApostropheJournalDigestsAreCanonicalButContainNoPhrasePayload() throws {
        let raw = apostropheRecord("A sample isn’t empty; it’s synthetic.")
        let safety = try PhraseSafetyEntry(record: raw, accountFingerprint: fingerprint(), vocabularyID: vocID, createdAt: Date())
        let canonical = "A sample isn't empty; it's synthetic."
        XCTAssertEqual(safety.englishDigest, try PhraseSafetyEntry.digest("english", [canonical]))
        XCTAssertTrue(try safety.matches(apostropheEntry(canonical)))
        XCTAssertTrue(try safety.matches(apostropheEntry(canonical, source: nil)))
        let encoded = String(decoding: try JSONEncoder().encode(safety), as: UTF8.self)
        for value in [raw.phrase, canonical, raw.interpretation, raw.origin, fakeToken, providerID, vocID, try fingerprint()] {
            XCTAssertFalse(encoded.contains(value))
        }
    }

    private func apostropheEntry(_ english: String, chinese: String = "合成中文ZH_SENTINEL。",
                                 source: String? = "SOURCE_SENTINEL", ordinal: Int = 1) -> PhraseBatchEntry {
        PhraseBatchEntry(ordinal: ordinal, spelling: entry.spelling, normalizedSpelling: entry.normalizedSpelling,
                         english: english, chinese: chinese, source: source)
    }

    private func apostropheRecord(_ english: String) -> PhraseRecord {
        PhraseRecord(id: providerID, phrase: english, interpretation: entry.chinese, tags: [],
                     origin: entry.source!, status: "PUBLISHED", highlight: .missing)
    }

    private func apostropheRawRecord(_ english: String) -> [String: Any] {
        var raw = rawRecord(); raw["phrase"] = english; return raw
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func journalURL(_ directory: URL) -> URL {
        directory.appendingPathComponent("com.davidqyc.momoMoreEfficient/phrase-safety-v1.json")
    }
    private func fingerprint() throws -> String {
        let lease = try credentialLease(); defer { lease.clear() }; return lease.fingerprint
    }
    private func record() -> PhraseRecord {
        PhraseRecord(id: providerID, phrase: entry.english, interpretation: entry.chinese, tags: [], origin: entry.source!, status: "PUBLISHED", highlight: .missing)
    }
    private func rawRecord() -> [String: Any] {
        ["id": providerID, "phrase": entry.english, "interpretation": entry.chinese, "tags": [String](), "origin": entry.source!, "status": "PUBLISHED"]
    }
    private func otherRecords(_ count: Int) -> [[String: Any]] {
        (0..<count).map { ["id": "EXISTING_\($0)", "phrase": "Other sample \($0).", "interpretation": "合成旧句。", "tags": [String](), "origin": "", "status": "PUBLISHED"] }
    }
    private func otherEntry(ordinal: Int) -> PhraseBatchEntry {
        PhraseBatchEntry(ordinal: ordinal, spelling: entry.spelling, normalizedSpelling: entry.normalizedSpelling,
                         english: "Different synthetic sample \(ordinal).", chinese: "合成新句。", source: nil)
    }
    private func vocabulary() -> StubbedResult { vocabularyQueryResponse([(id: vocID, spelling: entry.spelling)]) }
    private func empty() -> StubbedResult { jsonResponse(["phrases": []]) }
    private func createResponse() -> StubbedResult { jsonResponse(["data": ["phrase": rawRecord()]], status: 201) }
    private func executionReplies(post: StubbedResult, reads: [[[String: Any]]]) -> [StubbedResult] {
        [vocabulary(), empty(), post] + reads.map { jsonResponse(["phrases": $0]) }
    }
    private func snapshot(entries: [PhraseBatchEntry]? = nil, journal: PhraseSafetyJournal, visible: [[String: Any]] = []) async throws -> PhrasePreviewSnapshot {
        let entries = entries ?? [entry]
        let lease = try credentialLease(); defer { lease.clear() }
        let transport = FakeHTTPTransport([vocabulary()] + entries.map { _ in jsonResponse(["phrases": visible]) })
        return try await PhrasePreflightPlanner(journal: journal, api: MaimemoTransport(transport: transport, credential: lease, sleeper: RecordingSleeper()))
            .buildSnapshot(entries: entries, tags: [], credentialFingerprint: lease.fingerprint)
    }
    private func execute(_ shown: PhrasePreviewSnapshot, journal: PhraseSafetyJournal, transport: HTTPTransport) async throws -> PhraseExecutionSummary {
        let lease = try credentialLease(); defer { lease.clear() }
        return await PhraseWriteExecutor(journal: journal, api: MaimemoTransport(transport: transport, credential: lease, sleeper: RecordingSleeper()))
            .execute(displayedSnapshot: shown, approval: try PhraseCreateBinding.makeApproval(snapshot: shown), control: ExecutionControl())
    }
    private func model(journal: PhraseSafetyJournal, history: HistoryStore = InMemoryHistoryStore(), transport: HTTPTransport? = nil) -> CompanionViewModel {
        let model = CompanionViewModel(phraseSafetyJournal: journal, tokenStore: FakeTokenStore(), historyStore: history,
            transportFactory: { transport ?? FakeHTTPTransport([self.vocabulary(), self.empty()]) },
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { RecordingSleeper() }, backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() },
            preferenceDefaults: isolatedPreferenceDefaults())
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        model.selectMode(.phrase)
        model.sourceText = "\(entry.spelling)\n\(entry.english)\n\(entry.chinese)\n\(entry.source!)"
        return model
    }
}

private final class ObservingPhraseTransport: HTTPTransport {
    let base: FakeHTTPTransport
    private let onReadback: () throws -> Void
    init(replies: [StubbedResult], onReadback: @escaping () throws -> Void) {
        base = FakeHTTPTransport(replies)
        self.onReadback = onReadback
    }
    func send(_ request: TransportRequest, credential: OperationCredentialLease) async throws -> TransportResponse {
        if base.postCount > 0 && !request.route.isMutating { try onReadback() }
        return try await base.send(request, credential: credential)
    }
}
