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
        XCTAssertEqual(
            Set([HTTPMethod.get.rawValue, HTTPMethod.post.rawValue]),
            Set(["GET", "POST"])
        )
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
                // #164: the miss gets one Study repair, which proves nothing.
                studyRecordsResponse([]),
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
        XCTAssertEqual(snapshot.presentation.rows[1].compactBlockedReason, "未读取到可用词条目标")
        XCTAssertNil(snapshot.items[1].vocabularyID)
        XCTAssertEqual(
            transport.requests.count,
            4,
            "one batch query, one Study repair, and no content read for the unresolved entry"
        )
        XCTAssertEqual(transport.requests[1].route, .studyRecordsQuery)
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
