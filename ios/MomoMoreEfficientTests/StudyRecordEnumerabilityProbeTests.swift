import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The #155 StudyRecord enumerability probe: a bounded, read-only,
/// diagnostic-only partition probe over whole Beijing calendar days.
///
/// Tests drive the probe through a synthetic provider world that implements
/// the documented `query_study_records` contract (count/data over inclusive
/// next_study_date ranges), so every stage — global partition, after-last
/// segment, recursive whole-day splits, leaf closure rules, the 32-request
/// hard budget, cancellation and privacy — is exercised against realistic
/// count/data semantics without any live call.
@MainActor
final class StudyRecordEnumerabilityProbeTests: XCTestCase {

    // MARK: - Synthetic provider world

    /// Serves `query_study_records` exactly as documented: counts and data
    /// pages over inclusive `next_study_date` ranges, ordered by date, max
    /// 1000 rows per data page. Injects anomalies (count overrides, nil-date
    /// leaks, out-of-range leaks, duplicate IDs) for the classification tests.
    final class ProbeWorldTransport: HTTPTransport, @unchecked Sendable {
        struct WorldRecord {
            let vocID: String
            let spelling: String
            let date: Date?

            func payload() -> [String: Any] {
                var record: [String: Any] = [
                    "voc_id": vocID,
                    "voc_spelling": spelling,
                    "study_count": 1,
                    "tags": [String](),
                ]
                if let date {
                    record["add_date"] = "2026-01-01"
                    record["next_study_date"] = StudyExportSemantics.beijingISO8601(date)
                } else {
                    record["add_date"] = "2026-01-01"
                }
                return record
            }
        }

        /// Records in canonical (date, then voc id) ascending order.
        var records: [WorldRecord] = []
        /// Count overrides keyed by "start|end" ISO strings (nil = "").
        var countOverride: [String: Int] = [:]
        /// When set, a record with a nil date is served under any date-filtered
        /// data request (the FILTERED_RESPONSE_CONTAINS_NIL_DATE anomaly).
        var nilDateLeak = false
        /// When set, the first row served under a date-filtered data request
        /// carries a date one day after the range end (the
        /// FILTERED_RESPONSE_OUT_OF_RANGE anomaly).
        var outOfRangeLeak = false
        private(set) var requests: [TransportRequest] = []

        func send(
            _ request: TransportRequest,
            credential: OperationCredentialLease
        ) async throws -> TransportResponse {
            requests.append(request)
            let body = (try? JSONSerialization.jsonObject(with: request.body ?? Data())) as? [String: Any] ?? [:]
            let range = body["next_study_date"] as? [String: Any]
            let start = (range?["start"] as? String).flatMap(StudyDateParsing.parse)
            let end = (range?["end"] as? String).flatMap(StudyDateParsing.parse)
            let key = "\((range?["start"] as? String) ?? "")|\((range?["end"] as? String) ?? "")"
            let asCount = (body["as_count"] as? NSNumber)?.boolValue ?? false

            func inRange(_ record: WorldRecord) -> Bool {
                // Nil-dated rows answer only the unfiltered global query;
                // they never appear under a date-filtered request.
                guard let date = record.date else { return start == nil && end == nil }
                if let start, !(date >= start) { return false }
                if let end, !(date <= end) { return false }
                return true
            }

            if asCount {
                let matched = records.filter(inRange).count
                let count = countOverride[key] ?? matched
                return worldResponse(["records": [], "count": count])
            }

            var matched = records.filter(inRange)
            // Leak anomalies REPLACE a row so the page size stays equal to the
            // range count; only the row's date/nil-ness is wrong.
            if nilDateLeak, !matched.isEmpty {
                matched[0] = WorldRecord(vocID: "NILLEAK", spelling: "hidden", date: nil)
            }
            if outOfRangeLeak, let end, !matched.isEmpty {
                matched[0] = WorldRecord(
                    vocID: "RANGELEAK", spelling: "hidden", date: StudyExportSemantics.nextDayStart(end)
                )
            }
            let page = Array(matched.prefix(CompanionConstants.studyPageSize))
            return worldResponse(["records": page.map { $0.payload() }, "count": 0])
        }

        private func worldResponse(_ object: [String: Any]) -> TransportResponse {
            TransportResponse(
                status: 200,
                body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            )
        }

        var requestCount: Int { requests.count }
        var allReadOnly: Bool { requests.allSatisfy { !$0.route.isMutating } }
        func dataRequestsCovering(start: Date, end: Date) -> Int {
            let startString = StudyExportSemantics.beijingISO8601(start)
            let endString = StudyExportSemantics.beijingISO8601(end)
            return requests.filter { request in
                guard !request.route.isMutating, let body = request.body,
                      let object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
                      (object["as_count"] as? NSNumber)?.boolValue == false
                else { return false }
                let range = object["next_study_date"] as? [String: Any] ?? [:]
                return (range["start"] as? String) == startString
                    && (range["end"] as? String) == endString
            }.count
        }
    }

    private let fixedNow = studyFixedDate("2026-09-18T04:00:00+00:00")

    /// Beijing day `day` (1-based from 2026-05-01) at hour:minute — supports
    /// day numbers beyond a single month by shifting whole days.
    private func day(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        let base = StudyDateParsing.parse("2026-05-01T00:00:00+08:00")!
        let dayStart = StudyExportSemantics.beijingDayShift(base, days: day - 1)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = StudyExportSemantics.studyTimeZone
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: dayStart)!
    }

    private func makeProbe(
        _ transport: ProbeWorldTransport,
        anchor: Date? = nil,
        journal: StudyExportDiagnosticJournal? = nil
    ) -> StudyRecordEnumerabilityProbe {
        StudyRecordEnumerabilityProbe(
            api: MaimemoTransport(
                transport: transport,
                credential: try! credentialLease(),
                sleeper: RecordingSleeper()
            ),
            journal: journal,
            hintAnchorDate: anchor
        )
    }

    private func runProbe(_ probe: StudyRecordEnumerabilityProbe) async -> StudyRecordEnumerabilityProbeVerdict {
        await probe.run(control: ExecutionControl(), runID: "probetest1")
    }

    // MARK: - World builders

    /// `count` unique records evenly spread across `days` Beijing days
    /// starting at May 1, `hour`-granular ordering inside a day.
    private func spreadRecords(ids: String, count: Int, days: [Int]) -> [ProbeWorldTransport.WorldRecord] {
        var result: [ProbeWorldTransport.WorldRecord] = []
        let perDay = count / days.count
        var remaining = count
        for (index, day) in days.enumerated() {
            let dayCount = index == days.count - 1 ? remaining : perDay
            for i in 0..<dayCount {
                result.append(.init(
                    vocID: "\(ids)_\(day)_\(i)",
                    spelling: "word\(day)_\(i)",
                    date: self.day(day, 0, i % 60)
                ))
            }
            remaining -= dayCount
        }
        return result
    }

    // MARK: - Stage 0/1 + happy path

    /// Tests 1–3, 6, 7, 9: the Owner's real 2716/2316/400 shape closes fully.
    /// 2316 dated records over 3 days (772 each) + 400 after the anchor;
    /// the coverage-gap anchor (day 3 boundary area) extends lastDay so
    /// through_last=2316 and after_last=400; the after-last segment closes
    /// count=rows=unique; the whole-day split is disjoint and exhaustive and
    /// every child sum equals its parent; all three leaves close.
    func testPartitionCase2716ClosesEndToEnd() async {
        let anchor = day(4, 12) // the coverageGap final-date anchor (day 4)
        let journal = makeJournal()
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 2316, days: [1, 2, 3])
            + spreadRecords(ids: "AFTER", count: 400, days: [5, 6])
        // First page (first 1000 by date order): min day 1, max day 2.
        // lastDay extends to day 4 via the anchor.
        world.countOverride = [:]

        let verdict = await runProbe(makeProbe(world, anchor: anchor, journal: journal))

        XCTAssertEqual(verdict, .datePartitionEnumerable)
        // Whole-day split ranges are disjoint and exhaustive: no data page was
        // ever requested for a >1000 single day (there are none), and every
        // request was read-only.
        XCTAssertTrue(world.allReadOnly)
    }

    /// Test 3: after_last > 0 proves the previous terminal short page was not
    /// globally terminal — logged as probe_partition_root after_last=N.
    func testAfterLastPartitionProvesEarlierTerminalWasNotGlobal() async {
        let anchor = day(4, 12)
        let journal = makeJournal()
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 2316, days: [1, 2, 3])
            + spreadRecords(ids: "AFTER", count: 400, days: [5, 6])

        _ = await runProbe(makeProbe(world, anchor: anchor, journal: journal))

        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("probe_partition_root before_first=0 through_last=2316 after_last=400"))
        XCTAssertTrue(report.contains("probe_after_last count=400 rows=400 unique=400"))
    }

    // MARK: - Stage 1 verdicts

    /// Test 4: through_last + after_last != global → GLOBAL_NOT_DATE_PARTITIONABLE.
    func testGlobalPartitionMismatch() async {
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 100, days: [1])
            // Nil-date records match no date-filtered range, so the partition
            // sum falls below the global count.
            + (0..<10).map { .init(vocID: "UNDATED_\($0)", spelling: "u\($0)", date: nil) }

        let verdict = await runProbe(makeProbe(world))

        XCTAssertEqual(verdict, .globalNotDatePartitionable)
    }

    /// Test 5: before_first > 0 → LOWER_ANCHOR_NOT_CLOSED.
    func testBeforeFirstPositiveFailsLowerAnchor() async {
        let anchor = day(3)
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 50, days: [3, 4])
        // The provider claims records before the first-page's earliest day.
        world.countOverride["|2026-05-02T23:59:59+08:00"] = 5

        let verdict = await runProbe(makeProbe(world, anchor: anchor))

        XCTAssertEqual(verdict, .lowerAnchorNotClosed)
    }

    /// After-last > 1000 → AFTER_LAST_UNBOUNDED_OVER_LIMIT; the unbounded
    /// future is never chased. The first page is exactly filled by records at
    /// or before the anchor day, so lastDay stays the anchor day.
    func testAfterLastOverLimitIsNotChased() async {
        let anchor = day(2, 12)
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 1000, days: [1, 2])
            + spreadRecords(ids: "AFTER", count: 1200, days: [3, 4, 5])

        let verdict = await runProbe(makeProbe(world, anchor: anchor))

        XCTAssertEqual(verdict, .afterLastUnboundedOverLimit)
    }

    // MARK: - Stage 2 partition verdicts

    /// Test 8: left + right != parent → COUNT_PARTITION_INCONSISTENT.
    func testChildSumMismatchIsInconsistent() async {
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 2316, days: [1, 2, 3])
        // Corrupt one child count (left = [day1..day2], right = [day3..day3]).
        world.countOverride["2026-05-01T00:00:00+08:00|2026-05-02T23:59:59+08:00"] = 1200

        let verdict = await runProbe(makeProbe(world))

        XCTAssertEqual(verdict, .countPartitionInconsistent)
    }

    /// Test 10: leaf rows < count → LEAF_COUNT_DATA_GAP.
    func testLeafRowsBelowCount() async {
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 500, days: [2])
        world.countOverride["2026-05-02T00:00:00+08:00|2026-05-02T23:59:59+08:00"] = 600

        let verdict = await runProbe(makeProbe(world))

        XCTAssertEqual(verdict, .leafCountDataGap)
    }

    /// Test 11: duplicate provider identities in one leaf → LEAF_DUPLICATE_IDS.
    func testLeafDuplicateIDs() async {
        var world = ProbeWorldTransport()
        var records = spreadRecords(ids: "VOC", count: 500, days: [2])
        records.append(.init(vocID: "VOC_2_0", spelling: "word2_0", date: day(2, 0, 30)))
        world.records = records

        let verdict = await runProbe(makeProbe(world))

        XCTAssertEqual(verdict, .leafDuplicateIDs)
    }

    /// Test 12: a nil-date row inside a date-filtered response →
    /// FILTERED_RESPONSE_CONTAINS_NIL_DATE.
    func testFilteredResponseContainsNilDate() async {
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 500, days: [2])
        world.nilDateLeak = true

        let verdict = await runProbe(makeProbe(world))

        XCTAssertEqual(verdict, .filteredResponseContainsNilDate)
    }

    /// Test 13: an out-of-range date inside a filtered response →
    /// FILTERED_RESPONSE_OUT_OF_RANGE.
    func testFilteredResponseOutOfRange() async {
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 500, days: [2])
        world.outOfRangeLeak = true

        let verdict = await runProbe(makeProbe(world))

        XCTAssertEqual(verdict, .filteredResponseOutOfRange)
    }

    /// Test 14: one Beijing day holding 1001 records is decisive
    /// (SINGLE_DAY_OVER_LIMIT) and the same day is never re-read.
    func testSingleDayOverLimitIsDecisiveWithoutRepeatedReads() async {
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 1001, days: [2])

        let verdict = await runProbe(makeProbe(world))

        XCTAssertEqual(verdict, .singleDayOverLimit)
        // The single day was counted (root) but never fetched as data, and
        // no repeated same-day data reads exist.
        XCTAssertEqual(world.dataRequestsCovering(
            start: StudyExportSemantics.beijingDayStart(day(2)),
            end: StudyExportSemantics.beijingDayEnd(day(2))
        ), 0)
    }

    /// Test 15: the 32-request hard budget exhausts into an inconclusive
    /// verdict without ever exceeding the cap.
    func testRequestBudgetHardCap() async {
        var world = ProbeWorldTransport()
        // 1600 days × 10 records with an anchor on the last day: four split
        // levels alone need 2+4+8+16 = 30 count requests before any leaf, so
        // the 32-request budget exhausts mid-partition.
        world.records = spreadRecords(
            ids: "VOC", count: 16000,
            days: (1...1600).map { $0 }
        )

        let verdict = await runProbe(makeProbe(world, anchor: day(1600, 12)))

        XCTAssertEqual(verdict, .requestBudgetExhausted)
        XCTAssertLessThanOrEqual(world.requestCount, StudyRecordEnumerabilityProbe.maxRequestBudget)
    }

    /// Test 16: cancellation stops future calls and the lane releases.
    func testCancellationStopsFutureCallsAndReleasesLane() async throws {
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 2000, days: (1...40).map { $0 })

        let journal = makeJournal()
        let store = makeStore(journal: journal)
        store.handleAccountIdentityChange(to: AccountIdentity(fingerprint: "FP_1", authorityGeneration: 1))
        // Produce a coverageGap failure state first so the probe may run.
        await seedCoverageGapFailure(store: store)

        // Park the probe on its very first count request.
        let transport = GatedHTTPTransport(jsonResponse(["records": [], "count": 2716]))
        let laneReleased = ThreadSafeCounter()
        let lease = try queryLease(
            transport,
            onAuthenticationRejected: {},
            onFinish: { laneReleased.record() }
        )
        store.startCoverageProbe(lease: lease)
        await transport.waitUntilRequested()

        store.cancelProbe()
        await transport.resume()
        await store.awaitProbeCompletion()

        XCTAssertEqual(store.probePhase, .idle)
        // The lane releases through the probe task's own epilogue; allow the
        // main-actor queue to settle instead of pinning exact scheduling.
        for _ in 0..<200 where !laneReleased.didFire {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertTrue(laneReleased.didFire)
        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("probe_stop reason=cancelled"))
        XCTAssertTrue(report.contains("enumerability_probe_verdict verdict=CANCELLED"))
    }

    // MARK: - Privacy + read-only

    /// Test 17: the copied diagnostics carry counts/ranges/verdicts only —
    /// never the fake token, voc_ids or spellings.
    func testProbeDiagnosticsLeakNoCredentialsOrContent() async {
        let journal = makeJournal()
        let anchor = day(4, 12)
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC_SECRET", count: 2316, days: [1, 2, 3])
            + spreadRecords(ids: "AFTER_SECRET", count: 400, days: [5, 6])

        let verdict = await runProbe(makeProbe(world, anchor: anchor, journal: journal))
        XCTAssertEqual(verdict, .datePartitionEnumerable)

        let report = journal.formattedReport()
        XCTAssertTrue(report.contains("enumerability_probe_start"))
        XCTAssertTrue(report.contains("probe_global total=2716"))
        XCTAssertTrue(report.contains("probe_anchor first_day=2026-05-01 last_day=2026-05-04"))
        XCTAssertTrue(report.contains("enumerability_probe_verdict verdict=DATE_PARTITION_ENUMERABLE"))
        XCTAssertFalse(report.contains("VOC_SECRET"))
        XCTAssertFalse(report.contains("AFTER_SECRET"))
        XCTAssertFalse(report.contains("word1"))
        XCTAssertFalse(report.contains(fakeToken))
    }

    /// Test 18: every probe request is a read-semantic study records call.
    func testProbeUsesOnlyReadOnlyRoutes() async {
        let anchor = day(4, 12)
        let journal = makeJournal()
        var world = ProbeWorldTransport()
        world.records = spreadRecords(ids: "VOC", count: 2316, days: [1, 2, 3])
            + spreadRecords(ids: "AFTER", count: 400, days: [5, 6])

        let verdict = await runProbe(makeProbe(world, anchor: anchor, journal: journal))

        XCTAssertEqual(verdict, .datePartitionEnumerable)
        XCTAssertTrue(world.allReadOnly)
        XCTAssertEqual(world.requests.count, 14)
    }

    // MARK: - Store gating (test 21)

    /// The probe action unlocks only on the coverageGap failure; other
    /// failures and fresh runs keep it hidden.
    func testProbeActionGatedToCoverageGapOnly() async throws {
        let journal = makeJournal()
        let store = makeStore(journal: journal)
        store.handleAccountIdentityChange(to: AccountIdentity(fingerprint: "FP_1", authorityGeneration: 1))

        // A non-coverageGap failure must not unlock the probe.
        let rateLimited = FakeHTTPTransport([.failure(CompanionError.rateLimited)])
        store.start(.todayNew, lease: try queryLease(rateLimited))
        await store.awaitRunCompletion()
        guard case .failed = store.phase else { return XCTFail("expected failed") }
        XCTAssertFalse(store.showsCoverageProbe)

        // A coverageGap failure unlocks it, carrying the safe anchor.
        func date(_ day: Int, _ hour: Int) -> String {
            String(format: "2026-05-%02dT%02d:00:00+08:00", day, hour)
        }
        func record(_ index: Int, _ date: String) -> [String: Any] {
            studyRecord(
                id: "VOC_\(index)", spelling: "word\(index)", addDate: "2026-01-01", nextStudyDate: date
            )
        }
        let coverageGap = FakeHTTPTransport([
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
        store.start(.allWords, lease: try queryLease(coverageGap))
        await store.awaitRunCompletion()
        guard case .failed = store.phase else { return XCTFail("expected failed") }
        XCTAssertTrue(store.showsCoverageProbe)

        // A fresh run hides the probe affordance again.
        let fresh = FakeHTTPTransport([
            studyTodayItemsResponse([
                studyTodayItem(id: "VOC_A", spelling: "apple", order: 1, isNew: true),
            ]),
        ])
        store.start(.todayNew, lease: try queryLease(fresh))
        await store.awaitRunCompletion()
        XCTAssertFalse(store.showsCoverageProbe)
        XCTAssertEqual(store.probePhase, .idle)
    }

    /// Thread-safe release flag: the probe task's epilogue (lease.finish →
    /// onFinish) runs on whatever thread the nonisolated async boundary lands
    /// on, so a @MainActor counter would race its own visibility.
    final class ThreadSafeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var fired = false
        func record() {
            lock.lock()
            fired = true
            lock.unlock()
        }
        var didFire: Bool {
            lock.lock()
            defer { lock.unlock() }
            return fired
        }
    }

    // MARK: - Fixtures

    private func makeJournal() -> StudyExportDiagnosticJournal {
        StudyExportDiagnosticJournal(storeURL: nil) { self.fixedNow }
    }

    private func makeStore(journal: StudyExportDiagnosticJournal?) -> StudyExportStore {
        StudyExportStore(dateProvider: { self.fixedNow }, journal: journal)
    }

    /// Produces a real coverageGap failure + anchor through the production
    /// runner/store path (not by touching private state).
    private func seedCoverageGapFailure(store: StudyExportStore) async {
        func date(_ day: Int, _ hour: Int) -> String {
            String(format: "2026-05-%02dT%02d:00:00+08:00", day, hour)
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
        store.start(.allWords, lease: try! queryLease(transport))
        await store.awaitRunCompletion()
    }
}
