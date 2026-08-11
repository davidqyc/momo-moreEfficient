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
                vocabularyResponse("INVALID_VOC_A", "createword"),
                interpretationsResponse([]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.counts.create, 1)
        XCTAssertEqual(transport.getCount, 2)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testMixedPreviewClassifiesCreateUpdateMatchingAndBlocked() async throws {
        let document = "create\nn. 新建\nupdate\nn. 新\nmatching\nn. 同\nblocked\nn. 阻断"
        let (snapshot, _, _) = try await makeSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC_A", "create"), interpretationsResponse([]),
                vocabularyResponse("INVALID_VOC_B", "update"),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 旧", tags: ["考研"])]),
                vocabularyResponse("INVALID_VOC_C", "matching"),
                interpretationsResponse([interpretation("INVALID_RECORD_B", "n. 同")]),
                vocabularyResponse("INVALID_VOC_D", "blocked"),
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
                vocabularyResponse("INVALID_VOC", "word"),
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
                vocabularyResponse(rawVocabularyID, "word"),
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
                vocabularyResponse("INVALID_VOC", "word"),
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
                vocabularyResponse("INVALID_VOC", "word"),
                interpretationsResponse([
                    interpretation("bad/id", "n. 旧", tags: ["考研"]),
                ]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.rows[0].classification, .blocked)
        XCTAssertEqual(snapshot.presentation.rows[0].reason, "READ_FAILED")
    }

    func testObservedDataWrappersAreAccepted() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: "word\nn. 新",
            results: [
                jsonResponse(["data": ["voc": ["id": "INVALID_VOC", "spelling": "word"]]]),
                jsonResponse(["data": ["interpretations": []]]),
            ]
        )
        XCTAssertEqual(snapshot.presentation.rows[0].classification, .create)
    }

    func testPacingIsSequentialAndInjectable() async throws {
        let (_, transport, sleeper) = try await makeSnapshot(
            document: "one\nn. 一\ntwo\nn. 二",
            results: [
                vocabularyResponse("INVALID_VOC_A", "one"), interpretationsResponse([]),
                vocabularyResponse("INVALID_VOC_B", "two"), interpretationsResponse([]),
            ]
        )
        XCTAssertEqual(transport.requests.count, 4)
        XCTAssertEqual(sleeper.seconds, [1.6, 1.6, 1.6])
    }
}
