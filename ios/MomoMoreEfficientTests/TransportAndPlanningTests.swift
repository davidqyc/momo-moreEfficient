import Foundation
import XCTest
@testable import MomoMoreEfficient

final class TransportAndPlanningTests: XCTestCase {
    func testProductionConfigurationIsEphemeralAndNonPersistent() {
        let transport = URLSessionHTTPTransport()
        XCTAssertTrue(transport.sessionPolicy.isEphemeral)
        XCTAssertFalse(transport.sessionPolicy.hasURLCache)
        XCTAssertFalse(transport.sessionPolicy.hasCookieStorage)
        XCTAssertFalse(transport.sessionPolicy.hasCredentialStorage)
        XCTAssertFalse(transport.sessionPolicy.allowsCookies)
        XCTAssertFalse(transport.sessionPolicy.usesBackgroundSession)
    }

    func testProductionHostAndPathsAreLocked() throws {
        let routes: [InterpretationRoute] = [
            .vocabulary(spelling: "a word"),
            .interpretations(vocabularyID: "INVALID_VOC"),
            .createInterpretation,
            .updateInterpretation(recordID: "INVALID_RECORD"),
        ]
        for route in routes {
            let url = try route.url()
            XCTAssertEqual(url.scheme, "https")
            XCTAssertEqual(url.host, "open.maimemo.com")
            XCTAssertTrue(url.path.hasPrefix("/open/api/v1/"))
        }
        XCTAssertThrowsError(try InterpretationRoute.updateInterpretation(recordID: "../bad").url())
        XCTAssertThrowsError(try InterpretationRoute.interpretations(vocabularyID: "bad/id").url())
    }

    func testOnlyGETAndPOSTMethodsExistAcrossClosedRoutes() {
        XCTAssertEqual(InterpretationRoute.vocabulary(spelling: "word").method, .get)
        XCTAssertEqual(InterpretationRoute.interpretations(vocabularyID: "ID").method, .get)
        XCTAssertEqual(InterpretationRoute.createInterpretation.method, .post)
        XCTAssertEqual(InterpretationRoute.updateInterpretation(recordID: "ID").method, .post)
        XCTAssertEqual(InterpretationRoute.vocabularyQuery.method, .post)
        XCTAssertEqual(InterpretationRoute.studyRecords.method, .post)
        XCTAssertEqual(
            Set([HTTPMethod.get.rawValue, HTTPMethod.post.rawValue]),
            Set(["GET", "POST"])
        )
        // Every production route stays read-only GET or write-semantic POST;
        // the only DELETE in the app is the DEBUG-only dogfood cleanup pair
        // below (#183), absent from Release builds entirely.
    }

    /// #183 DEBUG dogfood cleanup routes sit on the current first-party
    /// `maimemo/memo-api-cli` coordinates and are the app's only DELETEs.
    func testDogfoodDeleteRoutesAreMutatingDELETEOnDocumentedCoordinates() throws {
        #if DEBUG
        let interpretationDelete = InterpretationRoute.dogfoodDeleteInterpretation(recordID: "REC_A")
        let phraseDelete = InterpretationRoute.dogfoodDeletePhrase(recordID: "REC_B")
        XCTAssertEqual(interpretationDelete.method, .delete)
        XCTAssertEqual(phraseDelete.method, .delete)
        XCTAssertTrue(interpretationDelete.isMutating)
        XCTAssertTrue(phraseDelete.isMutating)
        XCTAssertEqual(interpretationDelete.reviewedPath, "/open/api/v1/interpretations/REC_A")
        XCTAssertEqual(phraseDelete.reviewedPath, "/open/api/v1/phrases/REC_B")
        XCTAssertEqual(try interpretationDelete.url().path, "/open/api/v1/interpretations/REC_A")
        XCTAssertEqual(try phraseDelete.url().path, "/open/api/v1/phrases/REC_B")
        XCTAssertThrowsError(
            try InterpretationRoute.dogfoodDeleteInterpretation(recordID: "../bad").url()
        )
        XCTAssertThrowsError(try InterpretationRoute.dogfoodDeletePhrase(recordID: "bad/id").url())
        // A DELETE carries no body, exactly like a GET.
        XCTAssertNoThrow(try TransportRequest(route: interpretationDelete))
        #else
        throw XCTSkip("DEBUG-only dogfood delete routes")
        #endif
    }

    /// The DEBUG delete dispatch sends the documented DELETE with no body and
    /// reports a clean 2xx; the readback that must follow stays a plain GET.
    func testDogfoodDeleteDispatchSendsDocumentedDELETE() async throws {
        #if DEBUG
        let transport = FakeHTTPTransport([jsonResponse([:])])
        let lease = try credentialLease()
        let api = MaimemoTransport(transport: transport, credential: lease)
        let control = ExecutionControl()

        let dispatch = await api.deleteDogfoodInterpretation(recordID: "REC_A", control: control)
        control.finishPostResolution()

        guard case let .clean2xx(status) = dispatch else {
            return XCTFail("expected clean 2xx, got \(dispatch)")
        }
        XCTAssertEqual(status, 200)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].route.method, .delete)
        XCTAssertNil(transport.requests[0].body)
        XCTAssertTrue(transport.requests[0].route.isMutating)
        #else
        throw XCTSkip("DEBUG-only dogfood delete routes")
        #endif
    }

    /// The dogfood ledger is the cross-relaunch recovery state: entries record,
    /// retire only on verified record IDs, and deleted entries keep nominating
    /// their spelling for the bounded rescan.
    func testDogfoodLedgerRecordsRetiresAndSurvivesRelaunch() {
        let directory = NSTemporaryDirectory()
            .appending("DogfoodLedgerTests-\(UUID().uuidString)")
        let directoryURL = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let ledger = DogfoodLedger(applicationSupportDirectory: directoryURL)
        XCTAssertTrue(ledger.load().isEmpty)
        XCTAssertEqual(ledger.activeCount(), 0)

        ledger.recordActive(runID: "RUN_A", kind: "interpretation", recordID: "REC_A", spelling: "apple")
        ledger.recordActive(runID: "RUN_A", kind: "phrase", recordID: "REC_B", spelling: "apple")
        XCTAssertEqual(ledger.activeCount(), 2)
        XCTAssertEqual(ledger.spellings(), ["apple"])

        // A fresh instance over the same Application Support directory is the
        // cross-relaunch recovery path.
        let relaunched = DogfoodLedger(applicationSupportDirectory: directoryURL)
        XCTAssertEqual(relaunched.load().count, 2)

        // Only a verified record ID retires; unknown IDs never touch entries.
        relaunched.retire(recordIDs: ["REC_UNKNOWN"])
        XCTAssertEqual(relaunched.activeCount(), 2)
        relaunched.retire(recordIDs: ["REC_A"])
        XCTAssertEqual(relaunched.activeCount(), 1)
        XCTAssertEqual(relaunched.load().first { $0.recordID == "REC_A" }?.state, "deleted")
        XCTAssertEqual(relaunched.load().first { $0.recordID == "REC_B" }?.state, "active")
        XCTAssertEqual(
            relaunched.spellings(),
            ["apple"],
            "deleted entries keep nominating their spelling for the bounded rescan"
        )
    }

    /// #183 round-2 mutation audit: only dispatched mutating routes count, by
    /// fixed name; a Preview flow leaves every counter untouched.
    func testLiveMutationAuditCountsOnlyDispatchedMutatingRoutes() async throws {
        #if DEBUG
        LiveMutationAudit.reset()
        XCTAssertEqual(LiveMutationAudit.count(LiveMutationAudit.interpretationCreate), 0)

        let lease = try credentialLease()
        defer { lease.clear() }
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "apple")]),
            interpretationsResponse([]),
        ])
        let api = MaimemoTransport(transport: transport, credential: lease)
        let snapshot = try await PreflightPlanner(api: api).buildSnapshot(
            entries: BatchParser.parseDailyInput("apple\nn. 一").entries,
            tags: [],
            status: CompanionConstants.status,
            credentialFingerprint: lease.fingerprint
        )
        XCTAssertEqual(snapshot.presentation.counts.create, 1)
        XCTAssertEqual(transport.postCount, 0, "Preview never dispatches a mutation")
        XCTAssertEqual(LiveMutationAudit.snapshotText().contains("interpretation_create_post=0"), true)

        // A dispatched interpretation CREATE counts exactly once, by name.
        let writeTransport = FakeHTTPTransport([jsonResponse([:], status: 201)])
        let writeAPI = MaimemoTransport(transport: writeTransport, credential: lease)
        let control = ExecutionControl()
        let body = try ConfirmationBinding.canonicalData([
            "interpretation": [
                "voc_id": "INVALID_VOC_A",
                "interpretation": "n. 二",
                "tags": [String](),
                "status": "PUBLISHED",
            ],
        ])
        let dispatch = await writeAPI.post(route: .createInterpretation, body: body, control: control)
        control.finishPostResolution()
        XCTAssertTrue(dispatch.isClean2xx)
        XCTAssertEqual(LiveMutationAudit.count(LiveMutationAudit.interpretationCreate), 1)
        XCTAssertEqual(LiveMutationAudit.count(LiveMutationAudit.interpretationUpdate), 0)
        XCTAssertEqual(LiveMutationAudit.count(LiveMutationAudit.phraseCreate), 0)
        LiveMutationAudit.reset()
        #else
        throw XCTSkip("DEBUG-only mutation audit")
        #endif
    }

    /// The one-shot fault store is boundary-matched and marker-gated, and a
    /// fired fault never fires twice. Non-marker content can never be killed.
    func testDogfoodFaultStoreIsOneShotBoundaryMatchedAndMarkerGated() {
        #if DEBUG
        let directory = NSTemporaryDirectory()
            .appending("DogfoodFaultTests-\(UUID().uuidString)")
        let directoryURL = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = DogfoodExperimentStore(applicationSupportDirectory: directoryURL)
        XCTAssertEqual(store.armedDescription, "none")

        // Non-marker content never fires even when armed.
        store.arm(.afterInterpretationMutation2xxBeforeReadback)
        XCTAssertFalse(store.consumeFault(
            .afterInterpretationMutation2xxBeforeReadback,
            markerIn: "n. Owner 的真实释义"
        ))
        XCTAssertEqual(store.armedDescription, "I1")

        // Wrong boundary never fires.
        XCTAssertFalse(store.consumeFault(
            .afterPhraseCreate2xxBeforeReadbackOrJournalClose,
            markerIn: "n. __XHN_DOGFOOD_V1__ B1"
        ))

        // Matching boundary + marker content fires exactly once.
        XCTAssertTrue(store.consumeFault(
            .afterInterpretationMutation2xxBeforeReadback,
            markerIn: "n. __XHN_DOGFOOD_V1__ B1"
        ))
        XCTAssertEqual(store.armedDescription, "none")
        XCTAssertFalse(store.consumeFault(
            .afterInterpretationMutation2xxBeforeReadback,
            markerIn: "n. __XHN_DOGFOOD_V1__ B1"
        ), "a fired fault is consumed")

        // The phrase-family marker gates too, and arming survives relaunch.
        store.arm(.afterPhraseCreate2xxBeforeReadbackOrJournalClose)
        let relaunched = DogfoodExperimentStore(applicationSupportDirectory: directoryURL)
        XCTAssertEqual(relaunched.armedDescription, "P1")
        XCTAssertTrue(relaunched.consumeFault(
            .afterPhraseCreate2xxBeforeReadbackOrJournalClose,
            markerIn: "The apple hums.\nXHN-DOGFOOD-ABC"
        ))
        #else
        throw XCTSkip("DEBUG-only fault store")
        #endif
    }

    /// GET-only ledger reconciliation (#183 E3): an active entry whose record
    /// disappeared from the fresh authenticated lists retires; a still-visible
    /// record does not.
    func testDogfoodLedgerRetiresAbsentEntriesOnly() {
        #if DEBUG
        let directory = NSTemporaryDirectory()
            .appending("DogfoodLedgerAbsentTests-\(UUID().uuidString)")
        let directoryURL = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let ledger = DogfoodLedger(applicationSupportDirectory: directoryURL)
        ledger.recordActive(runID: "R1", kind: "interpretation", recordID: "GONE", spelling: "apple")
        ledger.recordActive(runID: "R1", kind: "phrase", recordID: "STAYS", spelling: "apple")

        ledger.retireAbsent(visibleActiveRecordIDs: ["STAYS", "OTHER"])
        let entries = ledger.load()
        XCTAssertEqual(entries.first { $0.recordID == "GONE" }?.state, "deleted")
        XCTAssertEqual(entries.first { $0.recordID == "STAYS" }?.state, "active")
        #else
        throw XCTSkip("DEBUG-only dogfood ledger")
        #endif
    }

    /// Every scenario document this harness can emit must parse with the real
    /// production parsers, including the mixed batch and the smart-quote
    /// variant.
    func testExperimentScenarioDocumentsParseWithProductionParsers() throws {
        #if DEBUG
        let nonce = "ABC123"
        let marker = LiveDogfoodRunner.marker

        let b1 = "banana\nn. \(marker) B1 \(nonce)"
        XCTAssertEqual(try BatchParser.parseDailyInput(b1).entries.count, 1)

        let d = [
            "garden\nn. \(marker) Dcreate \(nonce)",
            "window\nn. \(marker) Dnew \(nonce)",
            "market\nn. \(marker) Dmatch \(nonce)",
            "qzxwvjkq\nn. \(marker) Dblock \(nonce)",
        ].joined(separator: "\n")
        XCTAssertEqual(try BatchParser.parseDailyInput(d).entries.count, 4)

        let c1 = LiveExperimentRunner.phraseDoc(word: "ocean", nonce: nonce, suffix: "C1")
        XCTAssertTrue(c1.contains("## ocean"))
        XCTAssertTrue(c1.contains("The ocean hums"))
        XCTAssertTrue(c1.contains(LiveDogfoodRunner.phraseMarker))
        let c1Parsed = try PhraseBatchParser.parse(c1)
        XCTAssertEqual(c1Parsed.count, 1)

        // The C5 apostrophe/quote document and its smart-quote equivalent.
        let c5 = LiveExperimentRunner.phraseDoc(
            word: "river",
            english: "She said the river's 'rule' was \"fair\".",
            chinese: "矩阵引号例句。",
            origin: "\(LiveDogfoodRunner.phraseMarker)\(nonce)-C5"
        )
        let parsed = try PhraseBatchParser.parse(c5)
        XCTAssertEqual(parsed.first?.english, "She said the river's 'rule' was \"fair\".")

        let smart = "She said the river\u{2019}s \u{2018}rule\u{2019} was \u{201C}fair\u{201D}."
        XCTAssertEqual(
            PhraseEnglishIdentity.canonical(smart),
            PhraseEnglishIdentity.canonical("She said the river's 'rule' was \"fair\"."),
            "smart quotes canonicalize to the same provider-state identity"
        )
        #else
        throw XCTSkip("DEBUG-only experiment harness")
        #endif
    }

    /// Baseline verification proves exact non-marker restore: an unchanged
    /// word verifies, a word whose non-marker set changed does not.
    func testExperimentBaselineVerificationDetectsExactRestore() async throws {
        #if DEBUG
        let directory = NSTemporaryDirectory()
            .appending("DogfoodExperimentTests-\(UUID().uuidString)")
        let directoryURL = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        let store = DogfoodExperimentStore(applicationSupportDirectory: directoryURL)
        let ledger = DogfoodLedger(applicationSupportDirectory: directoryURL)
        let lease = try credentialLease()
        defer { lease.clear() }

        func makeRunner(_ transport: FakeHTTPTransport) -> LiveExperimentRunner {
            LiveExperimentRunner(
                api: MaimemoTransport(transport: transport, credential: lease),
                ledger: ledger,
                experiment: store
            )
        }

        store.register(
            DogfoodScenarioBaseline(
                spelling: "apple",
                nonMarkerInterpretationIDs: ["REC_OWNER_1"],
                nonMarkerPhraseIDs: ["REC_PHRASE_1"]
            )
        )

        // Unchanged non-marker state: exact restore verifies.
        let sameTransport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC_A", "apple"),
            interpretationsResponse([interpretation("REC_OWNER_1", "n. 原释义")]),
            phrasesResponse([
                phraseRecordPayload("REC_PHRASE_1", english: "An apple a day.", chinese: "日一苹果。", origin: "自编"),
            ]),
        ])
        let verified = await makeRunner(sameTransport).verifyBaselines()
        XCTAssertTrue(verified.succeeded, verified.diagnostic)

        // A second non-marker interpretation appeared: verification must fail
        // and name the word.
        let changedTransport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC_A", "apple"),
            interpretationsResponse([
                interpretation("REC_OWNER_1", "n. 原释义"),
                interpretation("REC_OWNER_2", "n. 多出来的"),
            ]),
            phrasesResponse([
                phraseRecordPayload("REC_PHRASE_1", english: "An apple a day.", chinese: "日一苹果。", origin: "自编"),
            ]),
        ])
        let failed = await makeRunner(changedTransport).verifyBaselines()
        XCTAssertFalse(failed.succeeded)
        XCTAssertTrue(failed.message.contains("apple"), failed.message)
        #else
        throw XCTSkip("DEBUG-only experiment harness")
        #endif
    }

    func testGETCannotCarryBodyAndPOSTRequiresBody() {
        XCTAssertThrowsError(
            try TransportRequest(route: .vocabulary(spelling: "word"), body: Data())
        )
        XCTAssertThrowsError(try TransportRequest(route: .createInterpretation))
    }

    func testPreviewUsesExactlyGETAndZeroPOST() async throws {
        let (snapshot, transport, _) = try await makeSnapshot(
            document: "createword\nn. 新建",
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "createword")]),
                interpretationsResponse([]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.counts.create, 1)
        XCTAssertEqual(transport.requests.count, 2, "one batch resolution + one content read")
        XCTAssertEqual(transport.vocabularyQueryCount, 1)
        XCTAssertEqual(transport.getCount, 1)
        XCTAssertEqual(transport.postCount, 0, "Preview never dispatches a mutating request")
    }

    func testMixedPreviewClassifiesCreateUpdateMatchingAndBlocked() async throws {
        let document = "create\nn. 新建\nupdate\nn. 新\nmatching\nn. 同\nblocked\nn. 阻断"
        let (snapshot, _, _) = try await makeSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "create"), (id: "INVALID_VOC_B", spelling: "update"), (id: "INVALID_VOC_C", spelling: "matching"), (id: "INVALID_VOC_D", spelling: "blocked")]), interpretationsResponse([]),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 旧", tags: ["考研"])]),
                interpretationsResponse([interpretation("INVALID_RECORD_B", "n. 同")]),
                interpretationsResponse([
                    interpretation("INVALID_RECORD_C", "n. 一", tags: ["考研"]),
                    interpretation("INVALID_RECORD_D", "n. 二", tags: ["考研"]),
                ]),
            ]
        )
        XCTAssertEqual(
            snapshot.presentation.rows.map(\.classification),
            [.create, .update, .alreadyMatching, .blocked]
        )
        XCTAssertEqual(
            snapshot.presentation.counts,
            PreviewCounts(create: 1, update: 1, alreadyMatching: 1, blocked: 1)
        )
    }

    func testUpdatePresentationContainsCURRENTAndPROPOSED() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: "word\nn. 新版",
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]),
                interpretationsResponse([
                    interpretation("INVALID_RECORD", "n. 旧版", tags: ["考研"]),
                ]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.rows[0].current, "n. 旧版")
        XCTAssertEqual(snapshot.presentation.rows[0].proposed, "n. 新版")
    }

    func testPublicPreviewModelContainsNoRawIDs() async throws {
        let rawVocabularyID = "INVALID_PRIVATE_VOC_SENTINEL"
        let rawRecordID = "INVALID_PRIVATE_RECORD_SENTINEL"
        let (snapshot, _, _) = try await makeSnapshot(
            document: "word\nn. 新版",
            results: [
                vocabularyQueryResponse([(id: rawVocabularyID, spelling: "word")]),
                interpretationsResponse([
                    interpretation(rawRecordID, "n. 旧版", tags: ["考研"]),
                ]),
            ]
        )
        let encoded = try JSONEncoder().encode(snapshot.presentation)
        let rendered = String(decoding: encoded, as: UTF8.self)
        XCTAssertFalse(rendered.contains(rawVocabularyID))
        XCTAssertFalse(rendered.contains(rawRecordID))
        XCTAssertFalse(rendered.contains("voc_id"))
        XCTAssertFalse(rendered.contains("record_id"))
    }

    func testMatchingFinalStateIsZeroWriteClassification() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: "word\nn. 相同",
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]),
                interpretationsResponse([
                    interpretation("INVALID_RECORD", "n. 相同", tags: []),
                ]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.rows[0].classification, .alreadyMatching)
        XCTAssertTrue(snapshot.items(for: .update).isEmpty)
    }

    func testUnreadableRecordFailsClosedAsBlocked() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: "word\nn. 新",
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]),
                interpretationsResponse([
                    interpretation("bad/id", "n. 旧", tags: ["考研"]),
                ]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.rows[0].classification, .blocked)
        XCTAssertEqual(snapshot.presentation.rows[0].reason, "READ_FAILED")
    }

    func testVocabularyNotFoundBlocksOnlyThatInterpretationEntry() async throws {
        let (snapshot, transport, _) = try await makeSnapshot(
            document: "one\nn. 一\nmissingword\nn. 缺失\nthree\nn. 三",
            results: [
                // The batch resolution simply has no record for "missingword".
                vocabularyQueryResponse([
                    (id: "INVALID_VOC_ONE", spelling: "one"),
                    (id: "INVALID_VOC_THREE", spelling: "three"),
                ]),
                interpretationsResponse([]),
                interpretationsResponse([
                    interpretation("INVALID_RECORD_THREE", "n. 三"),
                ]),
            ]
        )

        XCTAssertEqual(
            snapshot.presentation.rows.map(\.classification),
            [.create, .blocked, .alreadyMatching]
        )
        XCTAssertEqual(snapshot.presentation.rows[1].reason, "VOCABULARY_NOT_FOUND")
        XCTAssertEqual(
            snapshot.presentation.rows[1].compactBlockedReason,
            "当前 Open API 无法解析该词条；若为自添加词，当前暂不支持"
        )
        XCTAssertNil(snapshot.items[1].vocabularyID)
        XCTAssertEqual(transport.requests.count, 3, "no unresolved entry costs a content read")
        XCTAssertEqual(transport.postCount, 0)
    }

    func testObservedDataWrappersAreAccepted() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: "word\nn. 新",
            results: [
                jsonResponse([
                    "data": ["voc": [["id": "INVALID_VOC", "spelling": "word"]]],
                    "errors": [],
                    "success": true,
                ]),
                jsonResponse(["data": ["interpretations": []]]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.rows[0].classification, .create)
    }

    func testPacingIsSequentialAndInjectable() async throws {
        let (_, transport, sleeper) = try await makeSnapshot(
            document: "one\nn. 一\ntwo\nn. 二",
            results: [
                vocabularyQueryResponse([
                    (id: "INVALID_VOC_A", spelling: "one"),
                    (id: "INVALID_VOC_B", spelling: "two"),
                ]),
                interpretationsResponse([]),
                interpretationsResponse([]),
            ]
        )
        XCTAssertEqual(transport.requests.count, 3)
        // #168: no fixed per-request floor. Pacing goes through the shared
        // window scheduler now (the opening request is still free); the 2
        // paced requests stay far under the aggregate windows, so each
        // waits 0 seconds instead of the old fixed floor.
        XCTAssertEqual(sleeper.seconds, [0, 0])
    }

    func testCredentialValidationReusesVocabularyRouteDecoderIncludingDataEnvelope() async throws {
        let lease = try credentialLease()
        defer { lease.clear() }

        for success in [
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
            jsonResponse([
                "data": ["voc": ["id": "INVALID_VALIDATION_VOC", "spelling": "apple"]],
            ]),
        ] {
            let valid = FakeHTTPTransport([success])
            try await MaimemoTransport(
                transport: valid,
                credential: lease,
                sleeper: RecordingSleeper()
            ).validateCredential()
            XCTAssertEqual(valid.requests.map(\.route), [.vocabulary(spelling: "apple")])
            XCTAssertEqual(valid.getCount, 1)
            XCTAssertEqual(valid.postCount, 0)
        }

        for failure in [
            jsonResponse(["unexpected": []]),
            jsonResponse(["voc": ["id": "INVALID_VALIDATION_VOC", "spelling": "pear"]]),
            jsonResponse([:]),
        ] {
            let transport = FakeHTTPTransport([failure])
            do {
                try await MaimemoTransport(
                    transport: transport,
                    credential: lease,
                    sleeper: RecordingSleeper()
                ).validateCredential()
                XCTFail("malformed authenticated 2xx must fail closed")
            } catch {
                XCTAssertEqual(error as? CompanionError, .responseRejected)
            }
        }
    }

    /// #168: a real aggregate-window wait can run up to the longest
    /// configured window. `pace()` must chunk that wait and re-check
    /// cancellation between chunks, or a background/cancel signal could go
    /// unnoticed for the whole wait instead of a single ~1s chunk.
    func testPaceIsCancellableMidWaitInsteadOfBlockingTheFullWindow() async throws {
        let lease = try credentialLease()
        defer { lease.clear() }
        let control = ExecutionControl()
        // Only one request fits in this window, so the second must wait out
        // its whole 5-second duration unless cancelled first.
        let scheduler = RequestWindowScheduler(windows: [.init(limit: 1, duration: 5)])
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "apple"),
            vocabularyResponse("INVALID_VOC", "apple"),
        ])
        let sleeper = CancelAfterNSleeper(control: control, cancelAfter: 2)
        let api = MaimemoTransport(
            transport: transport,
            credential: lease,
            sleeper: sleeper,
            scheduler: scheduler
        )

        _ = try await api.vocabulary(spelling: "apple", control: control)

        do {
            _ = try await api.vocabulary(spelling: "apple", control: control)
            XCTFail("cancellation raised mid-wait must abort the read")
        } catch {
            XCTAssertEqual(error as? CompanionError, .cancelled)
        }

        // Chunked at <=1s, the forced 5s wait would need 5 sleep calls to
        // fully elapse; cancellation after the 2nd must stop well short.
        XCTAssertLessThan(sleeper.seconds.count, 5)
        XCTAssertEqual(transport.requests.count, 1, "the cancelled read must never dispatch")
    }

    /// #168 repair: a cancelled wait must not leave a phantom dispatch
    /// timestamp behind. The scheduler here uses a frozen `TestClock` (the
    /// sleeper never really delays, so nothing ever advances it), which makes
    /// the two possible outcomes unambiguous: if the cancelled call's
    /// reservation survived, this limit-1 window would treat its own
    /// (later, never-reached) predicted slot as the most recent dispatch and
    /// force a full extra wait on top of it, doubling what a later caller
    /// actually has to wait.
    func testCancelledPacedRequestLeavesNoPhantomReservationForALaterRequest() async throws {
        let lease = try credentialLease()
        defer { lease.clear() }
        let clock = TestClock()
        // Only one request fits in this window, so the second must wait out
        // its whole 5-second duration unless cancelled first.
        let scheduler = RequestWindowScheduler(windows: [.init(limit: 1, duration: 5)], now: clock.now)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "apple"),
            vocabularyResponse("INVALID_VOC", "apple"),
        ])
        let cancelledControl = ExecutionControl()
        let sleeper = CancelAfterNSleeper(control: cancelledControl, cancelAfter: 2)
        let api = MaimemoTransport(
            transport: transport,
            credential: lease,
            sleeper: sleeper,
            scheduler: scheduler
        )

        // Call 1: free (opening request, window has room). Occupies the
        // window's only slot.
        _ = try await api.vocabulary(spelling: "apple", control: cancelledControl)

        // Call 2: window is full, so it must wait out the 5s duration;
        // cancelled mid-wait, so it never actually dispatches.
        do {
            _ = try await api.vocabulary(spelling: "apple", control: cancelledControl)
            XCTFail("cancellation raised mid-wait must abort the read")
        } catch {
            XCTAssertEqual(error as? CompanionError, .cancelled)
        }
        XCTAssertEqual(transport.requests.count, 1, "the cancelled read must never dispatch")

        // Call 3, with a fresh (non-cancelled) control: with the phantom
        // correctly removed, only call 1's real dispatch remains, so this
        // call waits out exactly one 5s window (5 one-second chunks) —
        // not a stacked ~10s from a surviving phantom reservation.
        let freshControl = ExecutionControl()
        let sleepCountBeforeThirdCall = sleeper.seconds.count
        _ = try await api.vocabulary(spelling: "apple", control: freshControl)
        let thirdCallSleepCount = sleeper.seconds.count - sleepCountBeforeThirdCall
        XCTAssertEqual(
            thirdCallSleepCount, 5,
            "a phantom reservation from the cancelled call would double this to ~10"
        )
        XCTAssertEqual(transport.requests.count, 2, "the fresh call must still dispatch once its wait clears")
    }

    /// Physical-device fallback for the live dogfood closure when
    /// XCUIAutomation cannot acquire device automation mode. This still runs
    /// inside the signed app test host on the Owner phone, using the real saved
    /// Token and real provider, and proves cleanup before + after the full
    /// create/update/create/delete round trip. Simulator/CI skips it.
    func testPhysicalLiveDogfoodRunnerRestoresDatabase() async throws {
#if DEBUG
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil {
            throw XCTSkip("physical-device live dogfood")
        }
        guard let token = try KeychainTokenStore().loadToken(), !token.isEmpty else {
            throw XCTSkip("physical app Keychain has no Maimemo token")
        }

        let session = CredentialSession()
        try session.connect(token: token)
        let lease = try session.makeOperationLease()
        defer {
            lease.clear()
            session.disconnect()
        }

        let api = MaimemoTransport(
            transport: URLSessionHTTPTransport(),
            credential: lease,
            phraseSafetyJournal: .shared,
            sleeper: ProductionRequestSleeper(),
            scheduler: RequestWindowScheduler()
        )
        let runner = LiveDogfoodRunner(api: api)

        let pre = await runner.cleanup()
        XCTAssertTrue(pre.succeeded, pre.diagnostic)
        XCTAssertEqual(pre.remainingActiveRecords, 0, pre.diagnostic)

        let run = await runner.run()

        // Always run one independent final sweep before asserting the run, so
        // even a failed write/readback sequence cannot strand marker records.
        let post = await runner.cleanup()
        XCTAssertTrue(post.succeeded, post.diagnostic)
        XCTAssertEqual(post.remainingActiveRecords, 0, post.diagnostic)
        XCTAssertTrue(run.succeeded, run.diagnostic)
        XCTAssertEqual(run.remainingActiveRecords, 0, run.diagnostic)
#else
        throw XCTSkip("DEBUG-only live dogfood")
#endif
    }

    func testGlobalReadFailuresAbortInterpretationPlanWithoutFabricatedRows() async throws {
        let entries = try BatchParser.parseDailyInput(
            "one\nn. 一\ntwo\nn. 二\nthree\nn. 三"
        ).entries
        for failure in [
            jsonResponse(["error": "auth"], status: 401),
            StubbedResult.failure(.transport),
            jsonResponse(["error": "rate"], status: 429),
            jsonResponse(["error": "server"], status: 503),
        ] {
            let transport = FakeHTTPTransport([failure])
            let lease = try credentialLease()
            defer { lease.clear() }
            do {
                _ = try await PreflightPlanner(
                    api: MaimemoTransport(
                        transport: transport,
                        credential: lease,
                        sleeper: RecordingSleeper()
                    )
                ).buildSnapshot(
                    entries: entries,
                    tags: [],
                    credentialFingerprint: lease.fingerprint
                )
                XCTFail("global failure must abort Preview")
            } catch let error as CompanionError {
                XCTAssertTrue(error.abortsReadPlan)
            }
            XCTAssertEqual(transport.requests.count, 1)
            XCTAssertEqual(transport.postCount, 0)
        }
    }
}
