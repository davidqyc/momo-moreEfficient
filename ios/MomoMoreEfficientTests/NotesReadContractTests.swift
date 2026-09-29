import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The strict read-only 助记 (notes) extension (#161).
///
/// Encodes the current first-party contract as an executable test so a drift in
/// the route, the query parameter or the schema is caught here rather than at
/// runtime. Evidence (Issue #161 adjudication comment 5553483948):
///
/// ```text
/// maimemo/memo-api-cli @ e883862  src/commands/note.ts, src/types/note.ts
/// base URL   https://open.maimemo.com/open/
/// list       GET /api/v1/notes?voc_id=<voc_id>
///            → effective public coordinate GET /open/api/v1/notes?voc_id=…
/// response   ListNotesResponse { notes: Note[] }
/// Note       id, note_type, note, status, created_time?, updated_time?
/// status     NOTE_STATUS_UNSPECIFIED | PUBLISHED | DELETED
/// ```
final class NotesReadContractTests: XCTestCase {

    // MARK: - Route contract

    func testNotesRouteIsAnAuthenticatedReadOnlyGETWithVocIDQuery() throws {
        let route = InterpretationRoute.notes(vocabularyID: "VOC_1")
        XCTAssertEqual(route.method, .get)
        XCTAssertFalse(route.isMutating)
        XCTAssertEqual(route.reviewedPath, "/open/api/v1/notes")
        XCTAssertEqual(
            try route.url().absoluteString,
            "https://open.maimemo.com/open/api/v1/notes?voc_id=VOC_1"
        )
    }

    func testNotesRouteRejectsAnUnsafeVocabularyIdentifier() {
        for unsafe in ["../secret", "VOC 1", "VOC/1", ""] {
            XCTAssertThrowsError(
                try InterpretationRoute.notes(vocabularyID: unsafe).url(),
                unsafe
            )
        }
    }

    func testNoNoteMutationRouteExists() {
        // Every mutating route in the app, enumerated. #161 adds none.
        let mutating: [InterpretationRoute] = [
            .createInterpretation,
            .updateInterpretation(recordID: "REC_1"),
            .createPhrase,
        ]
        XCTAssertTrue(mutating.allSatisfy(\.isMutating))
        let reads: [InterpretationRoute] = [
            .vocabulary(spelling: "apple"),
            .vocabularyQuery,
            .interpretations(vocabularyID: "VOC_1"),
            .phrases(vocabularyID: "VOC_1"),
            .notes(vocabularyID: "VOC_1"),
        ]
        XCTAssertTrue(reads.allSatisfy { !$0.isMutating })
    }

    // MARK: - Decoder

    func testDecodesTheFirstPartyListNotesResponse() async throws {
        let records = try await decodeNotes(
            notesResponse([
                note("NOTE_1", "记忆法一"),
                note("NOTE_2", "记忆法二", type: "ETYMOLOGY", status: "DELETED"),
                note("NOTE_3", "记忆法三", status: "NOTE_STATUS_UNSPECIFIED"),
            ])
        )
        XCTAssertEqual(records.map(\.id), ["NOTE_1", "NOTE_2", "NOTE_3"])
        XCTAssertEqual(records.map(\.noteType), ["MNEMONIC", "ETYMOLOGY", "MNEMONIC"])
        XCTAssertEqual(records[0].status, "PUBLISHED")
        // The whole collection comes back, DELETED included: what counts is
        // Query's own projection, not this shared transport (finding 7).
        XCTAssertTrue(records[1].isDeleted)
        XCTAssertTrue(records[2].hasUnsafeStatusForCounting)
    }

    func testDecodesTheOneLevelDataEnvelope() async throws {
        let records = try await decodeNotes(
            jsonResponse(["data": ["notes": [note("NOTE_1", "记忆法")]]])
        )
        XCTAssertEqual(records.count, 1)
    }

    func testEmptyCollectionIsAConfirmedZeroNotAFailure() async throws {
        let records = try await decodeNotes(notesResponse([]))
        XCTAssertTrue(records.isEmpty)
        XCTAssertEqual(QueryProjection.noteCell(records), .count(0))
    }

    func testUnrecognisedEnvelopeIsAWholeResponseRejection() async {
        for malformed in [
            jsonResponse(["items": [["id": "NOTE_1"]]]),
            jsonResponse(["notes": "not-a-list"]),
            jsonResponse([:]),
        ] {
            await assertNotesDecodeFails(malformed, expecting: .responseRejected)
        }
    }

    func testUnrecognisedRecordIsAnItemRejectionAndIsNeverGuessed() async {
        let cases: [[String: Any]] = [
            ["note_type": "MNEMONIC", "note": "x", "status": "PUBLISHED"],          // no id
            ["id": "bad id", "note_type": "M", "note": "x", "status": "PUBLISHED"], // unsafe id
            ["id": "NOTE_1", "note": "x", "status": "PUBLISHED"],                   // no note_type
            ["id": "NOTE_1", "note_type": "M", "status": "PUBLISHED"],              // no note
            ["id": "NOTE_1", "note_type": "M", "note": "x"],                        // no status
            ["id": "NOTE_1", "note_type": "M", "note": "x", "status": "ARCHIVED"],  // undocumented
            ["id": "NOTE_1", "note_type": "M", "note": "  ", "status": "PUBLISHED"],// blank note
        ]
        for record in cases {
            await assertNotesDecodeFails(
                notesResponse([record]),
                expecting: .itemResponseRejected
            )
        }
    }

    func testDuplicateIdentitiesFailClosedRatherThanDoubleCounting() async {
        await assertNotesDecodeFails(
            notesResponse([note("NOTE_1", "一"), note("NOTE_1", "二")]),
            expecting: .itemResponseRejected
        )
    }

    func testOptionalTimestampsAreToleratedButNotRequired() async throws {
        var withTimes = note("NOTE_1", "记忆法")
        withTimes["created_time"] = "2026-01-01T00:00:00Z"
        withTimes["updated_time"] = "2026-01-02T00:00:00Z"
        let records = try await decodeNotes(notesResponse([withTimes]))
        XCTAssertEqual(records.count, 1)
    }

    func testAuthAndRateLimitStatusesStayGlobalReadPlanAborts() async {
        for (status, expected) in [
            (401, CompanionError.authenticationRejected),
            (429, CompanionError.rateLimited),
            (503, CompanionError.serverFailure),
            (418, CompanionError.globalHTTPFailure),
        ] {
            await assertNotesDecodeFails(
                jsonResponse(["notes": []], status: status),
                expecting: expected
            )
            XCTAssertTrue(expected.abortsReadPlan, "\(status)")
        }
    }

    // MARK: - Helpers

    private func decodeNotes(_ result: StubbedResult) async throws -> [NoteRecord] {
        let lease = try credentialLease()
        defer { lease.clear() }
        let api = MaimemoTransport(
            transport: FakeHTTPTransport([result]),
            credential: lease,
            sleeper: RecordingSleeper()
        )
        return try await api.notes(vocabularyID: "VOC_1")
    }

    private func assertNotesDecodeFails(
        _ result: StubbedResult,
        expecting expected: CompanionError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await decodeNotes(result)
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as CompanionError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected \(error)", file: file, line: line)
        }
    }
}
