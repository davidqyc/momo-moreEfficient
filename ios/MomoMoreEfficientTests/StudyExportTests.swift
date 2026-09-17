import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The headless study word export (#155).
///
/// Covers the frozen v1 semantics: closed provider decoding, the today-item
/// presets and their completeness rules, the Beijing study-calendar day, the
/// bounded sliding-`next_study_date` record pagination, identity/cancellation
/// lifecycle, and the read-only guarantee of the whole surface. Everything
/// runs against fake transports; no test touches a real credential or
/// Maimemo, and nothing here can reach a study mutation route.
@MainActor
final class StudyExportTests: XCTestCase {

    /// 2026-03-20 04:00 UTC == 12:00 Beijing. Fixed so the Beijing-day and
    /// review-window rules are deterministic.
    private let fixedNow = studyFixedDate("2026-03-20T04:00:00+00:00")

    private func makeRunner(_ transport: FakeHTTPTransport) -> (StudyExportRunner, FakeHTTPTransport) {
        let api = MaimemoTransport(
            transport: transport,
            credential: try! credentialLease(),
            sleeper: RecordingSleeper()
        )
        return (StudyExportRunner(api: api), transport)
    }

    private func requestBody(_ transport: FakeHTTPTransport, index: Int) throws -> [String: Any] {
        let request = transport.requests[index]
        return try JSONSerialization.jsonObject(with: request.body ?? Data()) as? [String: Any] ?? [:]
    }

    /// Runs one today-items decode and reports the thrown error, if any.
    /// (`XCTAssertThrowsError` has no async autoclosure, so errors surface
    /// through this helper instead.)
    private func todayItemDecodeError(_ record: [String: Any]) async -> Error? {
        let (runner, _) = makeRunner(FakeHTTPTransport([studyTodayItemsResponse([record])]))
        do {
            _ = try await runner.api.studyTodayItems()
            return nil
        } catch {
            return error
        }
    }

    private func recordDecodeError(_ record: [String: Any]) async -> Error? {
        let (runner, _) = makeRunner(FakeHTTPTransport([studyRecordsResponse([record])]))
        do {
            _ = try await runner.api.studyRecords(asCount: false)
            return nil
        } catch {
            return error
        }
    }

    private func runnerError(
        _ preset: StudyExportPreset,
        _ stubs: [StubbedResult]
    ) async -> Error? {
        let (runner, _) = makeRunner(FakeHTTPTransport(stubs))
        do {
            _ = try await runner.run(preset, control: ExecutionControl(), now: fixedNow)
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Route contract (read-only surface)

    func testStudyRoutesAreReadOnlyPOSTsWithDocumentedPaths() throws {
        XCTAssertEqual(InterpretationRoute.studyProgress.method, .post)
        XCTAssertFalse(InterpretationRoute.studyProgress.isMutating)
        XCTAssertEqual(InterpretationRoute.studyProgress.reviewedPath, "/open/api/v1/study/get_study_progress")
        XCTAssertEqual(InterpretationRoute.studyTodayItems.method, .post)
        XCTAssertFalse(InterpretationRoute.studyTodayItems.isMutating)
        XCTAssertEqual(InterpretationRoute.studyTodayItems.reviewedPath, "/open/api/v1/study/get_today_items")
        XCTAssertEqual(InterpretationRoute.studyRecords.method, .post)
        XCTAssertFalse(InterpretationRoute.studyRecords.isMutating)
        XCTAssertEqual(InterpretationRoute.studyRecords.reviewedPath, "/open/api/v1/study/query_study_records")
    }

    /// The only study routes that exist are read routes: the documented
    /// `/study/add_words` and `/study/advance_study` mutations have no case,
    /// so no export code path can even name them. Every preset, end to end,
    /// observes only these three and never a mutating POST.
    func testEveryPresetObservesOnlyStudyReadRoutesAndZeroMutatingPOSTs() async throws {
        let todayItems = studyTodayItemsResponse([
            studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isNew: true, isFinished: true),
        ])
        let records = studyRecordsResponse([
            studyRecord(
                id: "VOC_A",
                spelling: "apple",
                addDate: "2026-03-20T10:00:00+08:00",
                nextStudyDate: "2026-03-21T00:00:00+08:00"
            ),
        ])
        let progress = studyProgressResponse(finished: 1, total: 5)
        let cases: [StudyExportPreset: [StubbedResult]] = [
            .todayLearned: [progress, todayItems],
            .todayNew: [todayItems],
            .todayForgotten: [progress, todayItems],
            .todayVague: [progress, todayItems],
            .todayAdded: [studyCountResponse(1), records],
            .sticking: [studyCountResponse(1), records],
            .wellFamiliar: [studyCountResponse(1), records],
            .reviewWithin(days: 7): [studyCountResponse(1), records],
            .allWords: [studyCountResponse(1), records],
        ]
        var observedRoutes: [InterpretationRoute] = []
        for (preset, stubs) in cases {
            let (runner, transport) = makeRunner(FakeHTTPTransport(stubs))
            _ = try await runner.run(preset, control: ExecutionControl(), now: fixedNow)
            observedRoutes.append(contentsOf: transport.requests.map(\.route))
            // Write-safety accounting sees zero mutating requests from any preset.
            XCTAssertEqual(transport.postCount, 0, "\(preset)")
        }
        let allowed: [InterpretationRoute] = [.studyProgress, .studyTodayItems, .studyRecords]
        XCTAssertTrue(observedRoutes.allSatisfy { allowed.contains($0) })
        for route in allowed {
            XCTAssertTrue(observedRoutes.contains(route), "\(route) never exercised")
        }
    }

    // MARK: - 今日待复习

    func testTodayPendingSendsIsFinishedFalseWithoutIsNewAndPreservesOrder() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 6, total: 10),
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_R", spelling: "review", order: 3, isFinished: false),
                studyTodayItem(id: "VOC_N", spelling: "brand new", order: 4, isNew: true, isFinished: false),
                // Unfinished today's new words are included, not filtered out.
                studyTodayItem(id: "VOC_N", spelling: "brand new", order: 4, isNew: true, isFinished: false),
            ]),
        ]))
        let outcome = try await runner.run(.todayPending, control: ExecutionControl(), now: fixedNow)

        XCTAssertEqual(transport.requests.map(\.route), [.studyProgress, .studyTodayItems])
        let items = try requestBody(transport, index: 1)
        XCTAssertEqual(items["is_finished"] as? Bool, false)
        XCTAssertNil(items["is_new"])
        XCTAssertEqual(items["voc_ids"] as? [String], [])
        XCTAssertEqual(items["spellings"] as? [String], [])
        XCTAssertEqual(items["limit"] as? Int, 1000)

        // Unfinished review words AND unfinished new words, provider order,
        // deduped by voc_id.
        XCTAssertEqual(outcome.words, ["review", "brand new"])
        // expected_remaining = 10 - 6 = 4; fetched 3 rows → truthful mismatch.
        XCTAssertEqual(
            outcome.completeness,
            .mismatchedWithRemainingProgress(remaining: 4, read: 3)
        )
    }

    func testTodayPendingCompletenessRules() async throws {
        let unfinished: [[String: Any]] = (0..<3).map {
            studyTodayItem(id: "VOC_\($0)", spelling: "word\($0)", order: $0, isFinished: false)
        }
        // 1. fetched == expected_remaining → complete, including exact 1000.
        let (equal, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 7, total: 10),
            studyTodayItemsResponse(unfinished),
        ]))
        let equalOutcome = try await equal.run(.todayPending, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(equalOutcome.completeness, .complete)

        let fullPage: [[String: Any]] = (0..<1000).map {
            studyTodayItem(id: "VOC_\($0)", spelling: "word\($0)", order: $0, isFinished: false)
        }
        let (exact1000, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 0, total: 1000),
            studyTodayItemsResponse(fullPage),
        ]))
        let exactOutcome = try await exact1000.run(.todayPending, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(exactOutcome.completeness, .complete)

        // 2. fetched != expected_remaining → mismatch, never complete.
        let (unequal, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 2, total: 10),
            studyTodayItemsResponse(unfinished),
        ]))
        let unequalOutcome = try await unequal.run(.todayPending, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(
            unequalOutcome.completeness,
            .mismatchedWithRemainingProgress(remaining: 8, read: 3)
        )

        // 3. progress fails + fetched < 1000 → complete from terminal short page.
        let (noProgress, _) = makeRunner(FakeHTTPTransport([
            .failure(.transport),
            studyTodayItemsResponse(unfinished),
        ]))
        let noProgressOutcome = try await noProgress.run(.todayPending, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(noProgressOutcome.completeness, .complete)

        // 4. progress fails + fetched == 1000 → capped.
        let (noProgressFull, _) = makeRunner(FakeHTTPTransport([
            .failure(.transport),
            studyTodayItemsResponse(fullPage),
        ]))
        let cappedOutcome = try await noProgressFull.run(.todayPending, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(cappedOutcome.completeness, .cappedAtSingleCallLimit)

        // 5. impossible progress (finished > total) is unusable: no negative
        // count, page-size fallback instead.
        let (impossible, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 20, total: 10),
            studyTodayItemsResponse(unfinished),
        ]))
        let impossibleOutcome = try await impossible.run(.todayPending, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(impossibleOutcome.completeness, .complete)
    }

    func testPresetOrderLeadsWithTodayPresets() {
        XCTAssertEqual(
            StudyExportPreset.all.prefix(6).map(\.caseName),
            ["todayLearned", "todayPending", "todayAdded", "todayNew", "todayForgotten", "todayVague"]
        )
    }

    // MARK: - Provider request contract

    /// The proto-derived official request types make `voc_ids` / `spellings`
    /// required (empty for v1's unfiltered reads) and the official CLI always
    /// sends them; filters are added only when requested.
    func testTodayRequestSendsGeneratedTypeRequiredFields() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([studyTodayItemsResponse([])]))
        _ = try await runner.api.studyTodayItems()
        let body = try requestBody(transport, index: 0)
        XCTAssertEqual(body["voc_ids"] as? [String], [])
        XCTAssertEqual(body["spellings"] as? [String], [])
        XCTAssertEqual(body["limit"] as? Int, 1000)
        XCTAssertNil(body["is_finished"])
        XCTAssertNil(body["is_new"])

        // is_finished=true adds exactly that filter, retaining empty arrays.
        let (finishedRunner, finishedTransport) = makeRunner(FakeHTTPTransport([
            studyTodayItemsResponse([]),
        ]))
        _ = try await finishedRunner.api.studyTodayItems(isFinished: true)
        let finishedBody = try requestBody(finishedTransport, index: 0)
        XCTAssertEqual(finishedBody["is_finished"] as? Bool, true)
        XCTAssertNil(finishedBody["is_new"])
        XCTAssertEqual(finishedBody["voc_ids"] as? [String], [])
        XCTAssertEqual(finishedBody["spellings"] as? [String], [])
        XCTAssertEqual(finishedBody["limit"] as? Int, 1000)

        // is_new=true likewise.
        let (newRunner, newTransport) = makeRunner(FakeHTTPTransport([
            studyTodayItemsResponse([]),
        ]))
        _ = try await newRunner.api.studyTodayItems(isNew: true)
        let newBody = try requestBody(newTransport, index: 0)
        XCTAssertEqual(newBody["is_new"] as? Bool, true)
        XCTAssertNil(newBody["is_finished"])
        XCTAssertEqual(newBody["voc_ids"] as? [String], [])
        XCTAssertEqual(newBody["spellings"] as? [String], [])
    }

    /// `QueryStudyRecordsRequest` sends an explicit `as_count` boolean on
    /// every page — data pages send `false`, never omit it — plus the empty
    /// identity arrays and the limit.
    func testRecordsRequestSendsExplicitAsCountAndEmptyArrays() async throws {
        // Count page.
        let (countRunner, countTransport) = makeRunner(FakeHTTPTransport([studyCountResponse(0)]))
        _ = try await countRunner.api.studyRecords(asCount: true)
        let countBody = try requestBody(countTransport, index: 0)
        XCTAssertEqual(countBody["voc_ids"] as? [String], [])
        XCTAssertEqual(countBody["spellings"] as? [String], [])
        XCTAssertEqual(countBody["as_count"] as? Bool, true)
        XCTAssertEqual(countBody["limit"] as? Int, 1000)
        XCTAssertNil(countBody["next_study_date"])

        // Ordinary data page.
        let (dataRunner, dataTransport) = makeRunner(FakeHTTPTransport([studyRecordsResponse([])]))
        _ = try await dataRunner.api.studyRecords(asCount: false)
        let dataBody = try requestBody(dataTransport, index: 0)
        XCTAssertEqual(dataBody["voc_ids"] as? [String], [])
        XCTAssertEqual(dataBody["spellings"] as? [String], [])
        XCTAssertEqual(dataBody["as_count"] as? Bool, false)
        XCTAssertEqual(dataBody["limit"] as? Int, 1000)

        // Ranged data page keeps the explicit false plus the exact range.
        let (rangedRunner, rangedTransport) = makeRunner(FakeHTTPTransport([
            studyRecordsResponse([]),
        ]))
        _ = try await rangedRunner.api.studyRecords(
            nextStudyDateStart: "2026-03-02T00:00:00+08:00",
            nextStudyDateEnd: "2026-03-21T12:00:00+08:00",
            asCount: false
        )
        let rangedBody = try requestBody(rangedTransport, index: 0)
        XCTAssertEqual(rangedBody["as_count"] as? Bool, false)
        XCTAssertEqual(rangedBody["voc_ids"] as? [String], [])
        XCTAssertEqual(rangedBody["spellings"] as? [String], [])
        let range = rangedBody["next_study_date"] as? [String: Any]
        XCTAssertEqual(range?["start"] as? String, "2026-03-02T00:00:00+08:00")
        XCTAssertEqual(range?["end"] as? String, "2026-03-21T12:00:00+08:00")
    }

    // MARK: - Closed decoding

    func testStudyProgressClosedDecoding() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 10, total: 20, studyTime: 114514),
        ]))
        let progress = try await runner.api.studyProgress()
        XCTAssertEqual(progress, StudyProgress(finished: 10, total: 20, studyTimeMilliseconds: 114514))
        XCTAssertEqual(transport.requests.count, 1)

        // One-level data wrapper tolerance, same as the rest of the family.
        let (wrappedRunner, _) = makeRunner(FakeHTTPTransport([
            jsonResponse(["data": ["progress": ["finished": 1, "total": 2, "study_time": 3]]]),
        ]))
        let wrapped = try await wrappedRunner.api.studyProgress()
        XCTAssertEqual(wrapped.finished, 1)

        // Missing required field fails closed.
        let (missingRunner, _) = makeRunner(FakeHTTPTransport([
            jsonResponse(["progress": ["finished": 1, "total": 2]]),
        ]))
        do {
            _ = try await missingRunner.api.studyProgress()
            XCTFail("expected responseRejected")
        } catch { }

        // Negative counts are malformed.
        let (negativeRunner, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: -1, total: 2),
        ]))
        do {
            _ = try await negativeRunner.api.studyProgress()
            XCTFail("expected responseRejected")
        } catch { }
    }

    func testStudyTodayItemClosedDecoding() async throws {
        let (runner, _) = makeRunner(FakeHTTPTransport([studyTodayItemsResponse([
            studyTodayItem(
                id: "VOC_1", spelling: "apple", order: 3,
                firstResponse: "FORGET", isNew: true, isFinished: true
            ),
        ])]))
        let valid = try await runner.api.studyTodayItems()
        XCTAssertEqual(valid.count, 1)
        XCTAssertEqual(valid[0].firstResponse, .forget)
        XCTAssertEqual(valid[0].isNew, true)
        XCTAssertEqual(valid[0].isFinished, true)

        // Unknown response value is an item rejection, never a guessed meaning.
        let unknownResponse = await todayItemDecodeError(studyTodayItem(
            id: "VOC_1", spelling: "apple", order: 1, firstResponse: "SOMETHING_ELSE"
        ))
        XCTAssertEqual(unknownResponse as? CompanionError, .itemResponseRejected)
        // A number is not a boolean.
        let numericFlag = await todayItemDecodeError([
            "voc_id": "VOC_1", "voc_spelling": "apple", "order": 1, "is_new": 1, "is_finished": true,
        ])
        XCTAssertEqual(numericFlag as? CompanionError, .itemResponseRejected)
        // Missing required order.
        let missingOrder = await todayItemDecodeError([
            "voc_id": "VOC_1", "voc_spelling": "apple", "is_new": true, "is_finished": true,
        ])
        XCTAssertEqual(missingOrder as? CompanionError, .itemResponseRejected)
        // Unsafe identifier.
        let unsafeID = await todayItemDecodeError(studyTodayItem(
            id: "BAD ID!", spelling: "apple", order: 1
        ))
        XCTAssertEqual(unsafeID as? CompanionError, .itemResponseRejected)
    }

    func testStudyRecordClosedDecoding() async throws {
        // Array tags decode into the closed set, including the neutral
        // proto-derived sentinel.
        let (arrayRunner, _) = makeRunner(FakeHTTPTransport([studyRecordsResponse([
            studyRecord(
                id: "VOC_1", spelling: "apple", addDate: "2026-01-01T00:00:00+08:00",
                nextStudyDate: "2026-03-25T00:00:00+08:00",
                tags: ["STUDY_RECORD_TAG_UNSPECIFIED", "STICKING", "WELL_FAMILIAR"]
            ),
        ])]))
        let arrayTags = try await arrayRunner.api.studyRecords(asCount: false)
        XCTAssertEqual(
            arrayTags.records[0].tags,
            [.unspecified, .sticking, .wellFamiliar]
        )
        XCTAssertEqual(arrayTags.records[0].nextStudyDate, studyFixedDate("2026-03-24T16:00:00+00:00"))

        // A present, parseable add_date decodes; date-only form is interpreted
        // on the documented Beijing calendar.
        let (datedRunner, _) = makeRunner(FakeHTTPTransport([studyRecordsResponse([
            studyRecord(id: "VOC_1", spelling: "apple", addDate: "2026-01-01"),
        ])]))
        let dated = try await datedRunner.api.studyRecords(asCount: false)
        XCTAssertEqual(dated.records[0].addDate, studyFixedDate("2025-12-31T16:00:00+00:00"))

        // The two first-party sources conflict on scalar-vs-array tags; the
        // narrow shape both cover is scalar-or-array over the same closed
        // enum, a scalar normalizing to a one-element array.
        let (scalarRunner, _) = makeRunner(FakeHTTPTransport([studyRecordsResponse([
            studyRecord(id: "VOC_1", spelling: "apple", addDate: "2026-01-01", tags: "STICKING"),
        ])]))
        let scalarTags = try await scalarRunner.api.studyRecords(asCount: false)
        XCTAssertEqual(scalarTags.records[0].tags, [.sticking])

        // Unknown tag value fails closed with its field category.
        let unknownTag = await recordDecodeError(studyRecord(
            id: "VOC_1", spelling: "apple", addDate: "2026-01-01", tags: ["NEW_TAG"]
        ))
        XCTAssertEqual(unknownTag as? StudyRecordDecodeError, StudyRecordDecodeError(field: .tagsValue))
        let unknownScalarTag = await recordDecodeError(studyRecord(
            id: "VOC_1", spelling: "apple", addDate: "2026-01-01", tags: "NEW_TAG"
        ))
        XCTAssertEqual(unknownScalarTag as? StudyRecordDecodeError, StudyRecordDecodeError(field: .tagsValue))
        // Wrong container type fails closed as tagsType.
        let wrongContainer = await recordDecodeError(studyRecord(
            id: "VOC_1", spelling: "apple", addDate: "2026-01-01", tags: 42
        ))
        XCTAssertEqual(wrongContainer as? StudyRecordDecodeError, StudyRecordDecodeError(field: .tagsType))
        // Present-but-malformed add_date fails closed as addDateFormat.
        let malformedAddDate = await recordDecodeError(studyRecord(
            id: "VOC_1", spelling: "apple", addDate: "not-a-date"
        ))
        XCTAssertEqual(malformedAddDate as? StudyRecordDecodeError, StudyRecordDecodeError(field: .addDateFormat))
        // Present-but-malformed optional next_study_date fails closed.
        let malformedNext = await recordDecodeError(studyRecord(
            id: "VOC_1", spelling: "apple", addDate: "2026-01-01", nextStudyDate: "soon"
        ))
        XCTAssertEqual(malformedNext as? StudyRecordDecodeError, StudyRecordDecodeError(field: .nextStudyDateFormat))
    }

    /// The official proto-derived type declares `add_date?: string`: a record
    /// without one decodes safely as `nil` instead of rejecting the page.
    func testOfficialOptionalAddDateDecodesAsNil() async throws {
        let (absentRunner, _) = makeRunner(FakeHTTPTransport([studyRecordsResponse([
            studyRecord(id: "VOC_1", spelling: "apple", addDate: nil, nextStudyDate: "2026-03-25T00:00:00+08:00"),
        ])]))
        let page = try await absentRunner.api.studyRecords(asCount: false)
        XCTAssertNil(page.records[0].addDate)
        XCTAssertNotNil(page.records[0].nextStudyDate)
    }

    // MARK: - 今天已学

    func testTodayLearnedSendsIsFinishedTrueAndPreservesProviderOrder() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 3, total: 10),
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_B", spelling: "banana", order: 2, isFinished: true),
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isFinished: true),
                // Same provider identity twice: deduplicated, first spelling kept.
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isFinished: true),
            ]),
        ]))
        let outcome = try await runner.run(.todayLearned, control: ExecutionControl(), now: fixedNow)

        XCTAssertEqual(transport.requests.map(\.route), [.studyProgress, .studyTodayItems])
        let items = try requestBody(transport, index: 1)
        XCTAssertEqual(items["is_finished"] as? Bool, true)
        XCTAssertNil(items["is_new"])
        XCTAssertEqual(items["limit"] as? Int, 1000)

        // Provider order, never sorted by `order`.
        XCTAssertEqual(outcome.words, ["banana", "apple"])
        XCTAssertEqual(outcome.completeness, .complete)
    }

    func testTodayLearnedProgressExceedingListBlocksCompleteness() async throws {
        let (runner, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 5, total: 10),
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isFinished: true),
                studyTodayItem(id: "VOC_B", spelling: "banana", order: 2, isFinished: true),
                studyTodayItem(id: "VOC_C", spelling: "cherry", order: 3, isFinished: true),
            ]),
        ]))
        let outcome = try await runner.run(.todayLearned, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(outcome.completeness, .mismatchedWithProgress(finished: 5, read: 3))
    }

    func testTodayLearnedExactlyLimitIsCappedUnlessProgressProvesEquality() async throws {
        let fullPage: [[String: Any]] = (0..<1000).map {
            studyTodayItem(id: "VOC_\($0)", spelling: "word\($0)", order: $0, isFinished: true)
        }
        // Exactly 1000 with matching progress: proven complete.
        let (proved, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 1000, total: 1000),
            studyTodayItemsResponse(fullPage),
        ]))
        let provedOutcome = try await proved.run(.todayLearned, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(provedOutcome.completeness, .complete)

        // Exactly 1000 with a higher progress count: truthful mismatch.
        let (mismatched, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 1500, total: 2000),
            studyTodayItemsResponse(fullPage),
        ]))
        let mismatchedOutcome = try await mismatched.run(
            .todayLearned, control: ExecutionControl(), now: fixedNow
        )
        XCTAssertEqual(mismatchedOutcome.completeness, .mismatchedWithProgress(finished: 1500, read: 1000))

        // Exactly 1000 with no progress proof: honestly capped, never
        // silently complete.
        let (capped, _) = makeRunner(FakeHTTPTransport([
            .failure(.transport),
            studyTodayItemsResponse(fullPage),
        ]))
        let cappedOutcome = try await capped.run(.todayLearned, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(cappedOutcome.completeness, .cappedAtSingleCallLimit)
    }

    // MARK: - 今天新学 / 今天忘记 / 今天模糊

    func testTodayNewSendsIsNewTrue() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isNew: true),
            ]),
        ]))
        let outcome = try await runner.run(.todayNew, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests[0].route, .studyTodayItems)
        let items = try requestBody(transport, index: 0)
        XCTAssertEqual(items["is_new"] as? Bool, true)
        XCTAssertNil(items["is_finished"])
        XCTAssertEqual(outcome.words, ["apple"])
    }

    func testTodayForgottenAndVagueFilterFirstResponseOfCompletedItems() async throws {
        let completed = studyTodayItemsResponse([
            studyTodayItem(id: "VOC_F", spelling: "forget", order: 1, firstResponse: "FORGET", isFinished: true),
            studyTodayItem(id: "VOC_V", spelling: "vague", order: 2, firstResponse: "VAGUE", isFinished: true),
            studyTodayItem(id: "VOC_K", spelling: "known", order: 3, firstResponse: "FAMILIAR", isFinished: true),
            // The official proto-derived sentinel is a valid, neutral response.
            studyTodayItem(
                id: "VOC_U", spelling: "unspecified", order: 4,
                firstResponse: "STUDY_RESPONSE_UNSPECIFIED", isFinished: true
            ),
            studyTodayItem(id: "VOC_N", spelling: "unanswered", order: 5, isFinished: true),
        ])
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 5, total: 10),
            completed,
        ]))
        let forgotten = try await runner.run(.todayForgotten, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(forgotten.words, ["forget"])

        let (vagueRunner, vagueTransport) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 5, total: 10),
            completed,
        ]))
        let vague = try await vagueRunner.run(.todayVague, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(vague.words, ["vague"])

        // Both presets read today's *completed* items (progress first, then
        // the same completed read 今天已学 uses), never records and never
        // last_response.
        for t in [transport, vagueTransport] {
            XCTAssertEqual(t.requests.map(\.route), [.studyProgress, .studyTodayItems])
            let body = try requestBody(t, index: 1)
            XCTAssertEqual(body["is_finished"] as? Bool, true)
        }
    }

    func testStudyResponseUnspecifiedIsNeutralAndUnknownFailsClosed() async throws {
        let (runner, _) = makeRunner(FakeHTTPTransport([studyTodayItemsResponse([
            studyTodayItem(
                id: "VOC_U", spelling: "neutral", order: 1,
                firstResponse: "STUDY_RESPONSE_UNSPECIFIED", isFinished: true
            ),
        ])]))
        let items = try await runner.api.studyTodayItems()
        XCTAssertEqual(items[0].firstResponse, .unspecified)
        // The sentinel matches neither preset, and is never a user-facing
        // response category.
        XCTAssertFalse(StudyExportSemantics.isFirstResponse(.forget, in: items[0]))
        XCTAssertFalse(StudyExportSemantics.isFirstResponse(.vague, in: items[0]))

        let unknown = await todayItemDecodeError(studyTodayItem(
            id: "VOC_1", spelling: "apple", order: 1, firstResponse: "SOMETHING_ELSE"
        ))
        XCTAssertEqual(unknown as? CompanionError, .itemResponseRejected)
    }

    /// 忘记/模糊 inherit exactly the completed-items source's completeness:
    /// the Coordinator counterexample (progress 5, 3 completed rows, one
    /// FORGET) must not present a filtered subset as complete.
    func testForgottenAndVagueInheritCompletedListCompleteness() async throws {
        let completed = studyTodayItemsResponse([
            studyTodayItem(id: "VOC_F", spelling: "forget", order: 1, firstResponse: "FORGET", isFinished: true),
            studyTodayItem(id: "VOC_V", spelling: "vague", order: 2, firstResponse: "VAGUE", isFinished: true),
            studyTodayItem(id: "VOC_K", spelling: "known", order: 3, firstResponse: "FAMILIAR", isFinished: true),
        ])
        let (forgotten, forgottenTransport) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 5, total: 10),
            completed,
        ]))
        let forgottenOutcome = try await forgotten.run(
            .todayForgotten, control: ExecutionControl(), now: fixedNow
        )
        XCTAssertEqual(forgottenOutcome.words, ["forget"])
        XCTAssertEqual(
            forgottenOutcome.completeness,
            .mismatchedWithProgress(finished: 5, read: 3)
        )
        XCTAssertEqual(forgottenTransport.requests.count, 2)

        let (vague, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 5, total: 10),
            completed,
        ]))
        let vagueOutcome = try await vague.run(.todayVague, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(vagueOutcome.words, ["vague"])
        XCTAssertEqual(
            vagueOutcome.completeness,
            .mismatchedWithProgress(finished: 5, read: 3)
        )
    }

    func testFilteredTodayPresetsInheritCappedAndProvenCompleteness() async throws {
        let fullPage: [[String: Any]] = (0..<1000).map {
            studyTodayItem(id: "VOC_\($0)", spelling: "word\($0)", order: $0, isFinished: true)
        }
        // Exactly 1000 completed rows with no progress proof: the filtered
        // preset is capped, never silently complete.
        let (capped, _) = makeRunner(FakeHTTPTransport([
            .failure(.transport),
            studyTodayItemsResponse(fullPage),
        ]))
        let cappedOutcome = try await capped.run(
            .todayForgotten, control: ExecutionControl(), now: fixedNow
        )
        XCTAssertEqual(cappedOutcome.completeness, .cappedAtSingleCallLimit)

        // Matching progress equality proves the 1000-row read complete.
        let (proved, _) = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 1000, total: 1000),
            studyTodayItemsResponse(fullPage),
        ]))
        let provedOutcome = try await proved.run(
            .todayVague, control: ExecutionControl(), now: fixedNow
        )
        XCTAssertEqual(provedOutcome.completeness, .complete)
    }

    // MARK: - 今天新添加 (Beijing study day)

    func testTodayAddedFollowsBeijingCalendarDayAcrossUTCMidnight() {
        // now = 07:30 Beijing Jan 2 (23:30 UTC Jan 1): today is Beijing Jan 2.
        let now = studyFixedDate("2026-01-01T23:30:00+00:00")
        let lateJan1Beijing = studyFixedDate("2026-01-01T15:30:00+00:00") // 23:30 Beijing Jan 1
        let earlyJan2Beijing = studyFixedDate("2026-01-01T16:30:00+00:00") // 00:30 Beijing Jan 2
        let inDay = StudyExportSemantics.beijingStudyDay(containing: now)
        XCTAssertFalse(inDay.contains(lateJan1Beijing))
        XCTAssertTrue(inDay.contains(earlyJan2Beijing))

        // Half a day earlier, the Jan 1 evening word is today's.
        let nowJan1 = studyFixedDate("2026-01-01T13:00:00+00:00") // 21:00 Beijing Jan 1
        XCTAssertTrue(StudyExportSemantics.beijingStudyDay(containing: nowJan1).contains(lateJan1Beijing))
        XCTAssertFalse(StudyExportSemantics.beijingStudyDay(containing: nowJan1).contains(earlyJan2Beijing))

        XCTAssertEqual(inDay.lowerBound, studyFixedDate("2026-01-01T16:00:00+00:00"))
        XCTAssertEqual(inDay.upperBound, studyFixedDate("2026-01-02T16:00:00+00:00"))
    }

    func testTodayAddedReadsAllRecordsThenFiltersLocally() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyCountResponse(3),
            studyRecordsResponse([
                studyRecord(id: "VOC_OLD", spelling: "old", addDate: "2026-03-19T10:00:00+08:00"),
                studyRecord(id: "VOC_TODAY", spelling: "today", addDate: "2026-03-20T09:00:00+08:00"),
                studyRecord(id: "VOC_TONIGHT", spelling: "tonight", addDate: "2026-03-20T23:00:00+08:00"),
            ]),
        ]))
        let outcome = try await runner.run(.todayAdded, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(outcome.words, ["today", "tonight"])
        XCTAssertEqual(outcome.completeness, .complete)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testTodayAddedFailsClosedOnMalformedAddDate() async throws {
        let thrown = await runnerError(.todayAdded, [
            studyCountResponse(2),
            studyRecordsResponse([
                studyRecord(id: "VOC_OK", spelling: "ok", addDate: "2026-03-20T09:00:00+08:00"),
                studyRecord(id: "VOC_BAD", spelling: "bad", addDate: "20/03/2026"),
            ]),
        ])
        // A malformed add_date must fail the preset, never silently skip the
        // record and still claim completeness — with the exact field class.
        XCTAssertEqual(thrown as? StudyRecordDecodeError, StudyRecordDecodeError(field: .addDateFormat))
    }

    /// 今天新添加 is the one preset that must classify *every* record by add
    /// date, so one otherwise-valid record without `add_date` fails this
    /// preset truthfully instead of silently omitting it.
    func testTodayAddedFailsClosedWhenAnyRecordLacksAddDate() async throws {
        let thrown = await runnerError(.todayAdded, [
            studyCountResponse(2),
            studyRecordsResponse([
                studyRecord(id: "VOC_OK", spelling: "ok", addDate: "2026-03-20T09:00:00+08:00"),
                studyRecord(id: "VOC_UNKNOWN", spelling: "unknown", addDate: nil),
            ]),
        ])
        XCTAssertEqual(thrown as? StudyExportError, .addDateUnavailable)
    }

    // MARK: - 顽固词 / 熟知词

    func testStickingAndWellFamiliarFilterProviderTags() async throws {
        let records = studyRecordsResponse([
            studyRecord(id: "VOC_S", spelling: "sticky", addDate: "2026-01-01", tags: ["STICKING"]),
            studyRecord(id: "VOC_W", spelling: "familiar", addDate: "2026-01-01", tags: ["WELL_FAMILIAR"]),
            // The neutral sentinel matches neither preset.
            studyRecord(id: "VOC_U", spelling: "neutral", addDate: nil, tags: ["STUDY_RECORD_TAG_UNSPECIFIED"]),
            studyRecord(id: "VOC_P", spelling: "plain", addDate: "2026-01-01", tags: []),
        ])
        let (sticking, _) = makeRunner(FakeHTTPTransport([studyCountResponse(4), records]))
        let stickingOutcome = try await sticking.run(.sticking, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(stickingOutcome.words, ["sticky"])

        let (familiar, _) = makeRunner(FakeHTTPTransport([studyCountResponse(4), records]))
        let familiarOutcome = try await familiar.run(.wellFamiliar, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(familiarOutcome.words, ["familiar"])
    }

    // MARK: - Optional add_date (proto-derived official shape)

    /// Records without `add_date` are legitimate for every preset that does
    /// not classify by add date: 全部学习词 exports them, and 顽固词 /
    /// 熟知词 / N 天内复习 keep working.
    func testRecordPresetsNotRequiringAddDateOperateWithoutIt() async throws {
        let records = studyRecordsResponse([
            studyRecord(
                id: "VOC_S", spelling: "sticky", addDate: nil,
                nextStudyDate: "2026-03-22T00:00:00+08:00", tags: ["STICKING"]
            ),
            studyRecord(
                id: "VOC_W", spelling: "familiar", addDate: nil,
                nextStudyDate: "2026-03-23T00:00:00+08:00", tags: ["WELL_FAMILIAR"]
            ),
            studyRecord(
                id: "VOC_P", spelling: "plain", addDate: nil,
                nextStudyDate: "2026-03-24T00:00:00+08:00"
            ),
        ])
        let (allWords, _) = makeRunner(FakeHTTPTransport([studyCountResponse(3), records]))
        let allOutcome = try await allWords.run(.allWords, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(allOutcome.words, ["sticky", "familiar", "plain"])

        let (sticking, _) = makeRunner(FakeHTTPTransport([studyCountResponse(3), records]))
        let stickingOutcome = try await sticking.run(.sticking, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(stickingOutcome.words, ["sticky"])

        let (familiar, _) = makeRunner(FakeHTTPTransport([studyCountResponse(3), records]))
        let familiarOutcome = try await familiar.run(.wellFamiliar, control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(familiarOutcome.words, ["familiar"])

        let (review, _) = makeRunner(FakeHTTPTransport([studyCountResponse(3), records]))
        let reviewOutcome = try await review.run(
            .reviewWithin(days: 3), control: ExecutionControl(), now: fixedNow
        )
        XCTAssertEqual(reviewOutcome.completeness, .complete)
    }

    // MARK: - N 天内复习

    func testReviewWindowConstructsFixedEndBoundaries() async throws {
        // fixedNow = 12:00 Beijing. Rolling window: now + N days, expressed
        // on the documented Beijing offset.
        let expectedEnds: [Int: String] = [
            1: "2026-03-21T12:00:00+08:00",
            3: "2026-03-23T12:00:00+08:00",
            7: "2026-03-27T12:00:00+08:00",
            30: "2026-04-19T12:00:00+08:00",
        ]
        for (days, expectedEnd) in expectedEnds {
            let (runner, transport) = makeRunner(FakeHTTPTransport([
                studyCountResponse(0),
            ]))
            let outcome = try await runner.run(
                .reviewWithin(days: days), control: ExecutionControl(), now: fixedNow
            )
            XCTAssertEqual(outcome.words, [])
            XCTAssertEqual(transport.requests[0].route, .studyRecords)
            let body = try requestBody(transport, index: 0)
            XCTAssertEqual(body["as_count"] as? Bool, true)
            let range = body["next_study_date"] as? [String: Any]
            XCTAssertEqual(range?["end"] as? String, expectedEnd, "days=\(days)")
            XCTAssertNil(range?["start"])
        }
    }

    func testReviewWindowPaginationKeepsTheEndBoundaryFixed() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyCountResponse(2),
            studyRecordsResponse([
                studyRecord(
                    id: "VOC_DUE", spelling: "due", addDate: "2026-01-01",
                    nextStudyDate: "2026-03-22T00:00:00+08:00"
                ),
                studyRecord(
                    id: "VOC_LATER", spelling: "later", addDate: "2026-01-01",
                    nextStudyDate: "2026-06-01T00:00:00+08:00"
                ),
            ]),
        ]))
        let outcome = try await runner.run(.reviewWithin(days: 1), control: ExecutionControl(), now: fixedNow)
        XCTAssertEqual(transport.requests.count, 2)
        let dataPage = try requestBody(transport, index: 1)
        let range = dataPage["next_study_date"] as? [String: Any]
        XCTAssertEqual(range?["end"] as? String, "2026-03-21T12:00:00+08:00")
        XCTAssertEqual(outcome.completeness, .complete)
    }

    // MARK: - Full-record sliding pagination

    /// 2500 unique records over three pages, where page 2 re-returns 100
    /// boundary-date records already seen on page 1. Everything must dedupe
    /// by `voc_id`, keep first-seen order, and prove completeness against the
    /// provider count — well past the 1000 single-call limit.
    func testSlidingPaginationDedupesBoundaryDuplicatesAndCompletes() async throws {
        let b2 = "2026-03-02T00:00:00+08:00"
        let page1: [[String: Any]] = (0..<1000).map { index in
            studyRecord(
                id: "VOC_\(index)",
                spelling: "word\(index)",
                addDate: "2026-01-01",
                nextStudyDate: index < 900 ? "2026-03-01T00:00:00+08:00" : b2
            )
        }
        let page2: [[String: Any]] =
            (900..<1000).map { index in
                studyRecord(
                    id: "VOC_\(index)", spelling: "word\(index)",
                    addDate: "2026-01-01", nextStudyDate: b2
                )
            }
            + (1000..<1900).map { index in
                studyRecord(
                    id: "VOC_\(index)", spelling: "word\(index)",
                    addDate: "2026-01-01", nextStudyDate: "2026-03-03T00:00:00+08:00"
                )
            }
        let page3: [[String: Any]] = (1900..<2500).map { index in
            studyRecord(
                id: "VOC_\(index)", spelling: "word\(index)",
                addDate: "2026-01-01", nextStudyDate: "2026-03-04T00:00:00+08:00"
            )
        }
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyCountResponse(2500),
            studyRecordsResponse(page1),
            studyRecordsResponse(page2),
            studyRecordsResponse(page3),
        ]))
        let outcome = try await runner.run(.allWords, control: ExecutionControl(), now: fixedNow)

        XCTAssertEqual(transport.requests.count, 4)
        let secondPageBody = try requestBody(transport, index: 2)
        let range = secondPageBody["next_study_date"] as? [String: Any]
        XCTAssertEqual(range?["start"] as? String, b2)
        XCTAssertNil(range?["end"])

        // All 2500 unique identities, in deterministic first-seen order —
        // never silently truncated to the 1000-item single-call limit.
        XCTAssertEqual(outcome.words.count, 2500)
        XCTAssertEqual(outcome.words, (0..<2500).map { "word\($0)" })
        XCTAssertEqual(outcome.completeness, .complete)
    }

    func testNonAdvancingBoundaryFailsClosedWithoutLooping() async throws {
        let b1 = "2026-03-01T00:00:00+08:00"
        // Pathological page: more than a page worth of records sharing one
        // indistinguishable cursor date. The documented API cannot paginate
        // past it, so the loader must stop with a truthful completeness error
        // after a bounded number of requests.
        let page: [[String: Any]] = (0..<1000).map { index in
            studyRecord(id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01", nextStudyDate: b1)
        }
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyCountResponse(2500),
            studyRecordsResponse(page),
            studyRecordsResponse(page),
            studyRecordsResponse(page),
            studyRecordsResponse(page),
            studyRecordsResponse(page),
        ]))
        var thrown: Error?
        do {
            _ = try await runner.run(.allWords, control: ExecutionControl(), now: fixedNow)
        } catch {
            thrown = error
        }
        XCTAssertEqual(thrown as? StudyExportError, .paginationNotAdvancing)
        // count + page1 + page2, then stop. No infinite loop.
        XCTAssertEqual(transport.requests.count, 3)
    }

    /// Terminal short page below the provider's own count — the Owner's
    /// real-use shape, synthetic (unique totals 1000 / 1186 / 1471 / 1565
    /// against expected 2710): exactly one read-only coverage probe runs
    /// against the final decoded record's date, its numbers are logged, and
    /// the preset still fails closed — never a partial success.
    func testTerminalMismatchIssuesOneProbeAndFailsClosed() async throws {
        func date(_ day: Int, _ hour: Int) -> String {
            String(format: "2026-03-%02dT%02d:00:00+08:00", day, hour)
        }
        func record(_ index: Int, _ date: String) -> [[String: Any]].Element {
            studyRecord(
                id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01", nextStudyDate: date
            )
        }
        // Each page's last record carries a fresh date so the documented
        // boundary advances; duplicate rows re-use earlier identities.
        // rows 1000 / 1000 / 1000 / 673; new 1000 / 186 / 285 / 94.
        let page1: [[String: Any]] = (0..<1000).map { index in
            record(
                index,
                index < 900 ? date(1, 0) : (index < 999 ? date(2, 0) : date(2, 1))
            )
        }
        let page2: [[String: Any]] =
            (186..<1000).map { record($0, $0 < 900 ? date(1, 0) : ($0 < 999 ? date(2, 0) : date(2, 1))) }
            + (1000..<1186).map { record($0, $0 < 1185 ? date(2, 2) : date(2, 3)) }
        let page3: [[String: Any]] =
            (1000..<1186).map { record($0, $0 < 1185 ? date(2, 2) : date(2, 3)) }
            + (0..<529).map { record($0, $0 < 528 ? date(1, 0) : date(2, 0)) }
            + (1186..<1471).map { record($0, $0 < 1470 ? date(3, 0) : date(3, 1)) }
        let page4: [[String: Any]] =
            (0..<579).map { record($0, $0 < 528 ? date(1, 0) : date(2, 0)) }
            + (1471..<1565).map { record($0, $0 < 1564 ? date(4, 0) : date(4, 1)) }

        let transport = FakeHTTPTransport([
            studyCountResponse(2710),
            studyRecordsResponse(page1),
            studyRecordsResponse(page2),
            studyRecordsResponse(page3),
            studyRecordsResponse(page4),
            // The single coverage probe response.
            studyCountResponse(1600),
        ])
        let (runner, _) = makeRunner(transport)
        var thrown: Error?
        do {
            _ = try await runner.run(.allWords, control: ExecutionControl(), now: fixedNow, runID: "probe1")
        } catch {
            thrown = error
        }

        XCTAssertEqual(
            thrown as? StudyExportError,
            .coverageGap(expected: 2710, read: 1565, countedThroughFinalDate: 1600, finalDate: studyFixedDate("2026-03-04T01:00:00+08:00"))
        )
        // count + 4 pages + exactly one probe = 6 requests. No partial success.
        XCTAssertEqual(transport.requests.count, 6)
        let probeBody = try requestBody(transport, index: 5)
        XCTAssertEqual(probeBody["as_count"] as? Bool, true)
        XCTAssertEqual(probeBody["voc_ids"] as? [String], [])
        let range = probeBody["next_study_date"] as? [String: Any]
        XCTAssertEqual(range?["end"] as? String, date(4, 1))
        XCTAssertNil(range?["start"])
    }

    /// A failed probe never replaces the original truthful mismatch.
    func testProbeFailurePreservesOriginalMismatch() async throws {
        func date(_ day: Int, _ hour: Int) -> String {
            String(format: "2026-03-%02dT%02d:00:00+08:00", day, hour)
        }
        func record(_ index: Int, _ date: String) -> [[String: Any]].Element {
            studyRecord(
                id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01", nextStudyDate: date
            )
        }
        let page1: [[String: Any]] = (0..<1000).map { index in
            record(index, index < 999 ? date(1, 0) : date(2, 1))
        }
        let page2: [[String: Any]] =
            (999..<1000).map { record($0, date(2, 1)) }
            + (1000..<1565).map { record($0, $0 < 1564 ? date(3, 0) : date(3, 1)) }
        let transport = FakeHTTPTransport([
            studyCountResponse(2710),
            studyRecordsResponse(page1),
            studyRecordsResponse(page2),
            .failure(CompanionError.transport),
        ])
        let (runner, _) = makeRunner(transport)
        var thrown: Error?
        do {
            _ = try await runner.run(.allWords, control: ExecutionControl(), now: fixedNow, runID: "probe2")
        } catch {
            thrown = error
        }
        XCTAssertEqual(
            thrown as? StudyExportError,
            .recordCountMismatch(expected: 2710, read: 1565)
        )
        XCTAssertEqual(transport.requests.count, 4)
    }

    /// Failure A regression: the live provider documents scalar tags, so a
    /// `reviewWithin(1)` fixture whose records carry scalar tags must now
    /// succeed end to end.
    func testReviewWithinSucceedsWithScalarTagsFixture() async throws {
        let (runner, transport) = makeRunner(FakeHTTPTransport([
            studyCountResponse(2),
            studyRecordsResponse([
                studyRecord(
                    id: "VOC_A", spelling: "apple", addDate: "2026-01-01",
                    nextStudyDate: "2026-03-21T00:00:00+08:00", tags: "STICKING"
                ),
                studyRecord(
                    id: "VOC_B", spelling: "banana", addDate: "2026-01-01",
                    nextStudyDate: "2026-03-21T06:00:00+08:00", tags: "STUDY_RECORD_TAG_UNSPECIFIED"
                ),
            ]),
        ]))
        let outcome = try await runner.run(
            .reviewWithin(days: 1), control: ExecutionControl(), now: fixedNow, runID: "probe3"
        )
        XCTAssertEqual(outcome.words, ["apple", "banana"])
        XCTAssertEqual(outcome.completeness, .complete)
        XCTAssertEqual(transport.requests.count, 2)
    }

    func testBoundaryRecordWithoutNextStudyDateFailsClosed() async throws {
        let page: [[String: Any]] = (0..<1000).map { index in
            studyRecord(
                id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01",
                nextStudyDate: index == 999 ? nil : "2026-03-01T00:00:00+08:00"
            )
        }
        let thrown = await runnerError(.allWords, [
            studyCountResponse(2500),
            studyRecordsResponse(page),
        ])
        XCTAssertEqual(thrown as? StudyExportError, .paginationBoundaryUnavailable)
    }

    func testDistinctIdentitiesSharingASpellingAreBothKept() async throws {
        let (runner, _) = makeRunner(FakeHTTPTransport([
            studyCountResponse(2),
            studyRecordsResponse([
                studyRecord(id: "VOC_1", spelling: "bank", addDate: "2026-01-01"),
                studyRecord(id: "VOC_2", spelling: "bank", addDate: "2026-01-02"),
            ]),
        ]))
        let outcome = try await runner.run(.allWords, control: ExecutionControl(), now: fixedNow)
        // Dedup is by provider voc_id, never by normalised spelling.
        XCTAssertEqual(outcome.words, ["bank", "bank"])
    }

    // MARK: - Store: payload, identity, cancellation, auth

    private func makeStore() -> StudyExportStore {
        StudyExportStore(
            dateProvider: { studyFixedDate("2026-03-20T04:00:00+00:00") },
            journal: nil
        )
    }

    func testCopyPayloadIsExactlyNewlineSpellings() async throws {
        let store = makeStore()
        XCTAssertNil(store.copyPayload)

        let transport = FakeHTTPTransport([
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isNew: true),
                studyTodayItem(id: "VOC_B", spelling: "example phrase", order: 2, isNew: true),
            ]),
        ])
        store.start(.todayNew, lease: try queryLease(transport))
        await store.awaitRunCompletion()

        guard case .completed = store.phase else {
            return XCTFail("expected completed, got \(store.phase)")
        }
        XCTAssertEqual(store.copyPayload, "apple\nexample phrase")
        XCTAssertEqual(store.resultWordCount, 2)
        XCTAssertFalse(store.copyPayload!.contains("2"))
        XCTAssertFalse(store.copyPayload!.contains("今天"))

        store.returnToPresetList()
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.copyPayload)
    }

    func testAccountIdentityChangeClearsResult() async throws {
        let store = makeStore()
        let transport = FakeHTTPTransport([
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isNew: true),
            ]),
        ])
        store.handleAccountIdentityChange(to: AccountIdentity(fingerprint: "FP_1", authorityGeneration: 1))
        store.start(.todayNew, lease: try queryLease(transport))
        await store.awaitRunCompletion()
        guard case .completed = store.phase else {
            return XCTFail("expected completed, got \(store.phase)")
        }

        // An explicit, successful connect/replace/remove is a real identity
        // change and clears the account-derived result — even with the same
        // fingerprint, only the generation moves.
        store.handleAccountIdentityChange(to: AccountIdentity(fingerprint: "FP_1", authorityGeneration: 2))
        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.copyPayload)

        // The same identity arriving again is a no-op.
        store.handleAccountIdentityChange(to: AccountIdentity(fingerprint: "FP_1", authorityGeneration: 2))
        XCTAssertEqual(store.phase, .idle)
    }

    func testAuthenticationRejectionReportsToRootAndFailsClosed() async throws {
        let store = makeStore()
        let transport = FakeHTTPTransport([
            .response(TransportResponse(status: 401, body: Data("{}".utf8))),
        ])
        let authRejected = CallCounter()
        let laneReleased = CallCounter()
        store.start(.todayNew, lease: try queryLease(
            transport,
            onAuthenticationRejected: { authRejected.record() },
            onFinish: { laneReleased.record() }
        ))
        await store.awaitRunCompletion()

        guard case let .failed(preset, failure) = store.phase else {
            return XCTFail("expected failed, got \(store.phase)")
        }
        XCTAssertEqual(preset, .todayNew)
        XCTAssertNil(store.copyPayload)
        // The 401 went to the existing root rejection path, and the lane was
        // still released exactly once.
        XCTAssertTrue(authRejected.didFire)
        XCTAssertTrue(laneReleased.didFire)
        XCTAssertTrue(failure.title.contains("Token"))
    }

    func testStopCancelsPendingReadAndReleasesLane() async throws {
        let store = makeStore()
        let transport = SteppedHTTPTransport([
            studyProgressResponse(finished: 1, total: 5),
        ])
        let laneReleased = CallCounter()
        store.start(.todayLearned, lease: try queryLease(
            transport,
            onFinish: { laneReleased.record() }
        ))
        await transport.waitUntilParked()

        store.stop()
        await transport.release()
        await store.awaitRunCompletion()

        XCTAssertEqual(store.phase, .idle)
        XCTAssertNil(store.copyPayload)
        // The run unwound: progress + the parked items read, and nothing more.
        let requestCount = await transport.requests.count
        XCTAssertEqual(requestCount, 2)
        XCTAssertTrue(laneReleased.didFire)
    }

    func testProviderReadFailureFailsWithoutAutoRetry() async throws {
        let store = makeStore()
        let transport = FakeHTTPTransport([
            .failure(CompanionError.rateLimited),
        ])
        store.start(.todayNew, lease: try queryLease(transport))
        await store.awaitRunCompletion()

        guard case let .failed(_, failure) = store.phase else {
            return XCTFail("expected failed, got \(store.phase)")
        }
        XCTAssertNil(store.copyPayload)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertTrue(failure.title.contains("频繁"))
    }

    func testPaginationFailureSurfacesTruthfulCompletenessMessage() async throws {
        let store = makeStore()
        let page: [[String: Any]] = (0..<1000).map { index in
            studyRecord(
                id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01",
                nextStudyDate: "2026-03-01T00:00:00+08:00"
            )
        }
        let transport = FakeHTTPTransport([
            studyCountResponse(2500),
            studyRecordsResponse(page),
            studyRecordsResponse(page),
        ])
        store.start(.allWords, lease: try queryLease(transport))
        await store.awaitRunCompletion()

        guard case let .failed(_, failure) = store.phase else {
            return XCTFail("expected failed, got \(store.phase)")
        }
        XCTAssertEqual(failure.title, "无法证明读取完整")
        XCTAssertNil(store.copyPayload)
    }

    /// The Owner-facing coverage-gap copy states the provider's count, the
    /// safely enumerable count, and refuses the export — never a partial
    /// list labelled complete.
    func testCoverageGapFailureSurfacesTruthfulCopy() async throws {
        let store = makeStore()
        func date(_ day: Int, _ hour: Int) -> String {
            String(format: "2026-03-%02dT%02d:00:00+08:00", day, hour)
        }
        func record(_ index: Int, _ date: String) -> [String: Any] {
            studyRecord(
                id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01", nextStudyDate: date
            )
        }
        let transport = FakeHTTPTransport([
            studyCountResponse(2710),
            studyRecordsResponse((0..<1000).map { index in
                record(index, index < 999 ? date(1, 0) : date(2, 1))
            }),
            studyRecordsResponse(
                (999..<1000).map { record($0, date(2, 1)) }
                    + (1000..<1565).map { record($0, $0 < 1564 ? date(3, 0) : date(3, 1)) }
            ),
            studyCountResponse(1600),
        ])
        store.start(.allWords, lease: try queryLease(transport))
        await store.awaitRunCompletion()

        guard case let .failed(_, failure) = store.phase else {
            return XCTFail("expected failed, got \(store.phase)")
        }
        XCTAssertEqual(failure.title, "无法证明读取完整")
        XCTAssertTrue(failure.message.contains("2710"))
        XCTAssertTrue(failure.message.contains("1565"))
        XCTAssertTrue(failure.message.contains("不会导出可能遗漏的名单"))
        XCTAssertNil(store.copyPayload)
    }
}
