import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The #155 on-device diagnostic trail (Owner standing rule, Issue #155
/// comment 5686449945).
///
/// Proves the journal's bounded persistence, its privacy boundary (no Token,
/// no `voc_id`, no spelling ever reaches the report), that logging failure
/// never fails Study Export, and that the required event coverage — run
/// lifecycle, route reads, pagination facts, completeness decisions, mapped
/// failure categories, cancellation and auth — is emitted with counts only.
/// Every test uses temp files or memory-only journals; nothing touches the
/// real Application Support file.
@MainActor
final class StudyExportDiagnosticTests: XCTestCase {

    private let fixedNow = studyFixedDate("2026-03-20T04:00:00+00:00")

    private func tempJournalURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("study-export-diagnostics-tests")
            .appendingPathComponent("\(UUID().uuidString).json")
    }

    private func makeJournal(_ url: URL?) -> StudyExportDiagnosticJournal {
        StudyExportDiagnosticJournal(storeURL: url) { self.fixedNow }
    }

    private func makeStore(journal: StudyExportDiagnosticJournal?) -> StudyExportStore {
        StudyExportStore(dateProvider: { self.fixedNow }, journal: journal)
    }

    private func makeRunner(
        _ transport: FakeHTTPTransport,
        journal: StudyExportDiagnosticJournal
    ) -> StudyExportRunner {
        StudyExportRunner(
            api: MaimemoTransport(
                transport: transport,
                credential: try! credentialLease(),
                sleeper: RecordingSleeper()
            ),
            journal: journal
        )
    }

    private func runRunnerError(
        _ preset: StudyExportPreset,
        _ stubs: [StubbedResult],
        journal: StudyExportDiagnosticJournal
    ) async -> Error? {
        let runner = makeRunner(FakeHTTPTransport(stubs), journal: journal)
        do {
            _ = try await runner.run(preset, control: ExecutionControl(), now: fixedNow, runID: "testrun1")
            return nil
        } catch {
            return error
        }
    }

    // MARK: - Persistence, caps, clear

    func testPersistenceSurvivesNewJournalInstance() {
        let url = tempJournalURL()
        let first = makeJournal(url)
        first.log("run_start preset=todayNew run=run000001", run: "run000001")
        first.log("run_success preset=todayNew count=3 completeness=complete", run: "run000001")

        // A brand-new instance — the simulated relaunch — reads the same trail.
        let second = makeJournal(url)
        let report = second.formattedReport()
        XCTAssertTrue(report.contains("run_start preset=todayNew run=run000001"))
        XCTAssertTrue(report.contains("run_success preset=todayNew count=3 completeness=complete"))
    }

    func testTrimmingEnforcesEventAndByteCaps() {
        let url = tempJournalURL()
        let journal = makeJournal(url)
        for index in 0..<(StudyExportDiagnosticJournal.maxEventCount + 100) {
            journal.log("records_page index=\(index) rows=1000 new=1000 total=1000")
        }
        let report = journal.formattedReport()
        let eventLines = report.split(separator: "\n")
            .filter { $0.contains("records_page index=") }.count
        XCTAssertLessThanOrEqual(eventLines, StudyExportDiagnosticJournal.maxEventCount)

        // Byte cap: many large-but-safe events still trim to the bound.
        let bigJournal = makeJournal(tempJournalURL())
        let bigLine = String(repeating: "a", count: 2_000)
        for _ in 0..<200 {
            bigJournal.log("tag_filter tag=STICKING padding=\(bigLine)")
        }
        let encoded = bigJournal.formattedReport()
        XCTAssertLessThanOrEqual(encoded.utf8.count, StudyExportDiagnosticJournal.maxByteCount + 8_000)
        // Oldest trimmed first; the most recent evidence survives.
        XCTAssertTrue(encoded.contains("tag_filter"))
    }

    func testClearRemovesPersistedAndMemoryData() {
        let url = tempJournalURL()
        let journal = makeJournal(url)
        journal.log("run_start preset=todayNew run=run000001", run: "run000001")
        XCTAssertFalse(journal.formattedReport().contains("(no events)"))

        journal.clear()
        XCTAssertTrue(journal.formattedReport().contains("(no events)"))

        // Persisted evidence is gone for a fresh instance too.
        let reloaded = makeJournal(url)
        XCTAssertTrue(reloaded.formattedReport().contains("(no events)"))
    }

    /// Logging failure NEVER fails Study Export: an unwritable store location
    /// degrades to best-effort while the run outcome is untouched.
    func testPersistenceFailureDoesNotFailStudyExport() async throws {
        let unwritable = URL(fileURLWithPath: "/dev/null/study-export-diagnostics/impossible.json")
        let journal = makeJournal(unwritable)
        let runner = makeRunner(FakeHTTPTransport([
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isNew: true),
            ]),
        ]), journal: journal)
        let outcome = try await runner.run(.todayNew, control: ExecutionControl(), now: fixedNow, runID: "testrun1")
        XCTAssertEqual(outcome.words, ["apple"])
        XCTAssertEqual(outcome.completeness, .complete)
    }

    // MARK: - Privacy boundary

    /// The report must never contain the credential, provider identifiers or
    /// word payload — even though all three flowed through the same run.
    func testReportExcludesCredentialIDsAndSpellings() async throws {
        let journal = makeJournal(tempJournalURL())
        let runner = StudyExportRunner(
            api: MaimemoTransport(
                transport: FakeHTTPTransport([
                    studyCountResponse(1),
                    studyRecordsResponse([
                        studyRecord(
                            id: "VOC_SECRET", spelling: "TOPSECRETWORD",
                            addDate: "2026-03-20T09:00:00+08:00", tags: ["STICKING"]
                        ),
                    ]),
                ]),
                credential: try credentialLease(fakeToken),
                sleeper: RecordingSleeper()
            ),
            journal: journal
        )
        let outcome = try await runner.run(.sticking, control: ExecutionControl(), now: fixedNow, runID: "testrun1")
        XCTAssertEqual(outcome.words, ["TOPSECRETWORD"])

        let report = journal.formattedReport()
        XCTAssertFalse(report.contains(fakeToken), "credential leaked into diagnostics")
        XCTAssertFalse(report.contains("VOC_SECRET"), "provider id leaked into diagnostics")
        XCTAssertFalse(report.contains("TOPSECRETWORD"), "spelling leaked into diagnostics")
        // Counts are the safe currency of the report.
        XCTAssertTrue(report.contains("tag_filter tag=STICKING count=1"))
        XCTAssertTrue(report.contains("records_count_ok expected=1"))
    }

    // MARK: - Event coverage

    func testSuccessEmitsRunLifecycleWithCountsOnly() async throws {
        let journal = makeJournal(tempJournalURL())
        let store = makeStore(journal: journal)
        let transport = FakeHTTPTransport([
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isNew: true),
                studyTodayItem(id: "VOC_B", spelling: "banana", order: 2, isNew: true),
            ]),
        ])
        store.start(.todayNew, lease: try queryLease(transport))
        await store.awaitRunCompletion()

        guard case .completed = store.phase else {
            return XCTFail("expected completed, got \(store.phase)")
        }
        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("run_start preset=todayNew run="))
        XCTAssertTrue(report.contains("today_items_start is_finished=nil is_new=true limit=1000"))
        XCTAssertTrue(report.contains("today_items_ok rows=2"))
        XCTAssertTrue(report.contains("today_completeness fetched=2 progress_finished=nil result=complete"))
        XCTAssertTrue(report.contains("run_success preset=todayNew count=2 completeness=complete"))
        XCTAssertFalse(report.contains("apple"))
        XCTAssertFalse(report.contains("banana"))
    }

    func testRouteFailureEmitsMappedSanitizedCategory() async throws {
        let journal = makeJournal(tempJournalURL())
        let store = makeStore(journal: journal)
        let transport = FakeHTTPTransport([
            jsonResponse(["raw provider story": "do not log me"], status: 500),
        ])
        store.start(.todayNew, lease: try queryLease(transport))
        await store.awaitRunCompletion()

        guard case .failed = store.phase else {
            return XCTFail("expected failed, got \(store.phase)")
        }
        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("today_items_error category=companion.serverFailure"))
        XCTAssertTrue(report.contains("run_failed category=companion.serverFailure"))
        XCTAssertFalse(report.contains("do not log me"))
        XCTAssertFalse(report.contains("raw provider story"))
    }

    func testProgressMismatchLogsCountsAndCompleteness() async throws {
        let journal = makeJournal(tempJournalURL())
        let runner = makeRunner(FakeHTTPTransport([
            studyProgressResponse(finished: 5, total: 10),
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_F", spelling: "forget", order: 1, firstResponse: "FORGET", isFinished: true),
                studyTodayItem(id: "VOC_V", spelling: "vague", order: 2, firstResponse: "VAGUE", isFinished: true),
                studyTodayItem(id: "VOC_K", spelling: "known", order: 3, firstResponse: "FAMILIAR", isFinished: true),
            ]),
        ]), journal: journal)
        let outcome = try await runner.run(.todayForgotten, control: ExecutionControl(), now: fixedNow, runID: "testrun1")
        XCTAssertEqual(outcome.words, ["forget"])

        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("progress_ok finished=5 total=10"))
        XCTAssertTrue(report.contains("today_completeness fetched=3 progress_finished=5 result=mismatchedWithProgress"))
        XCTAssertTrue(report.contains("first_response_filter response=FORGET count=1"))
        XCTAssertFalse(report.contains("forget"))
    }

    func testTodayAddedMissingAddDateLogsCountAndCategoryOnly() async throws {
        let journal = makeJournal(tempJournalURL())
        let thrown = await runRunnerError(.todayAdded, [
            studyCountResponse(2),
            studyRecordsResponse([
                studyRecord(id: "VOC_OK", spelling: "GHOSTWORD_OK", addDate: "2026-03-20T09:00:00+08:00"),
                studyRecord(id: "VOC_UNKNOWN", spelling: "GHOSTWORD_MISSING", addDate: nil),
            ]),
        ], journal: journal)
        XCTAssertEqual(thrown as? StudyExportError, .addDateUnavailable)

        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("added_missing_add_date count=1"))
        // run_failed is a store-level event; this runner-level trail carries
        // the missing-add-date count and the decode facts only.
        XCTAssertFalse(report.contains("GHOSTWORD"))
    }

    func testPaginationLogsPageAndCountFactsWithoutIDs() async throws {
        let journal = makeJournal(tempJournalURL())
        let runner = makeRunner(FakeHTTPTransport([
            studyCountResponse(2500),
            studyRecordsResponse((0..<1000).map { index in
                studyRecord(
                    id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01",
                    nextStudyDate: index < 999
                        ? "2026-03-01T00:00:00+08:00" : "2026-03-02T00:00:00+08:00"
                )
            }),
            studyRecordsResponse((1000..<2500).map { index in
                studyRecord(
                    id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01",
                    nextStudyDate: "2026-03-03T00:00:00+08:00"
                )
            }),
        ]), journal: journal)
        let outcome = try await runner.run(.allWords, control: ExecutionControl(), now: fixedNow, runID: "testrun1")
        XCTAssertEqual(outcome.words.count, 2500)

        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("records_count_ok expected=2500"))
        XCTAssertTrue(report.contains("records_page index=1 start=nil end=nil rows=1000 new=1000 total=1000"))
        XCTAssertTrue(report.contains("records_page index=2"))
        XCTAssertTrue(report.contains("records_done reason=expected_total pages=2"))
        XCTAssertFalse(report.contains("VOC_"))
        XCTAssertFalse(report.contains("word0"))
    }

    func testCancellationLogsAndLaneStillReleases() async throws {
        let journal = makeJournal(tempJournalURL())
        let store = makeStore(journal: journal)
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
        XCTAssertTrue(laneReleased.didFire)
        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("run_start preset=todayLearned"))
        XCTAssertTrue(report.contains("run_stopped preset=todayLearned"))
    }

    func testAuthRejectionLogsCategoryAndRootPathStaysIntact() async throws {
        let journal = makeJournal(tempJournalURL())
        let store = makeStore(journal: journal)
        let transport = FakeHTTPTransport([
            .response(TransportResponse(status: 401, body: Data("{}".utf8))),
        ])
        let authRejected = CallCounter()
        store.start(.todayNew, lease: try queryLease(
            transport,
            onAuthenticationRejected: { authRejected.record() }
        ))
        await store.awaitRunCompletion()

        guard case .failed = store.phase else {
            return XCTFail("expected failed, got \(store.phase)")
        }
        XCTAssertTrue(authRejected.didFire)
        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("auth_rejected category=companion.authenticationRejected"))
        XCTAssertTrue(report.contains("run_failed category=companion.authenticationRejected"))
    }

    func testAccountChangeLogsEventWithoutIdentityValue() {
        let journal = makeJournal(tempJournalURL())
        let store = makeStore(journal: journal)
        store.handleAccountIdentityChange(to: AccountIdentity(fingerprint: "FP_SECRET", authorityGeneration: 3))
        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("account_changed"))
        XCTAssertFalse(report.contains("FP_SECRET"))
    }

    // MARK: - Owner-visible policy

    func testDiagnosticsSurfaceIsOwnerVisibleUnderUnstableFeaturePolicy() {
        // Keep true until the Owner confirms #155 stable; the Study Export
        // screen renders its diagnostics row only while this holds.
        XCTAssertTrue(StudyExportDiagnosticsPolicy.isOwnerVisible)
    }
}
