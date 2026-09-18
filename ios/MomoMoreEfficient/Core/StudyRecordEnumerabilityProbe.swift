import Foundation

/// The verdict of the StudyRecord enumerability probe (#155, diagnostic only).
///
/// Exactly one verdict per probe run. `datePartitionEnumerable` requires
/// every component to close: the global date partition, the lower anchor,
/// the after-last segment, every partition sum and every leaf.
enum StudyRecordEnumerabilityProbeVerdict: String, Equatable, Sendable, CaseIterable {
    case datePartitionEnumerable = "DATE_PARTITION_ENUMERABLE"
    case singleDayOverLimit = "SINGLE_DAY_OVER_LIMIT"
    case countPartitionInconsistent = "COUNT_PARTITION_INCONSISTENT"
    case leafCountDataGap = "LEAF_COUNT_DATA_GAP"
    case leafDuplicateIDs = "LEAF_DUPLICATE_IDS"
    case filteredResponseContainsNilDate = "FILTERED_RESPONSE_CONTAINS_NIL_DATE"
    case filteredResponseOutOfRange = "FILTERED_RESPONSE_OUT_OF_RANGE"
    case globalNotDatePartitionable = "GLOBAL_NOT_DATE_PARTITIONABLE"
    /// A newer boundary-search count moved the envelope earlier/later yet the
    /// count grew — provider count semantics are not monotonic under the
    /// documented date filters, so no partition math can be trusted.
    case boundaryCountNonMonotonic = "BOUNDARY_COUNT_NON_MONOTONIC"
    /// Backward compatibility only: the corrected boundary-search path never
    /// emits this (the lower bound is discovered by count-only search, not
    /// assumed from an unbounded first page).
    case lowerAnchorNotClosed = "LOWER_ANCHOR_NOT_CLOSED"
    /// Backward compatibility only: the corrected upper search moves the
    /// envelope forward with cheap count-only calls instead of terminating.
    case afterLastUnboundedOverLimit = "AFTER_LAST_UNBOUNDED_OVER_LIMIT"
    case requestBudgetExhausted = "REQUEST_BUDGET_EXHAUSTED"
    case cancelled = "CANCELLED"
    case otherSanitizedFailure = "OTHER_SANITIZED_FAILURE"

    /// The short Owner-facing Chinese label.
    var chineseLabel: String {
        switch self {
        case .datePartitionEnumerable: return "按日期分区可完整枚举"
        case .singleDayOverLimit: return "存在单日超过 1000 条，公开接口无法完整枚举"
        case .countPartitionInconsistent: return "分区 count 与父级 count 不一致"
        case .leafCountDataGap: return "区间 count 与实际返回行数不一致"
        case .leafDuplicateIDs: return "区间返回了重复词条记录"
        case .filteredResponseContainsNilDate: return "日期过滤结果包含缺少日期的记录"
        case .filteredResponseOutOfRange: return "日期过滤结果包含区间之外的日期"
        case .globalNotDatePartitionable: return "全量 count 无法按日期分区闭合"
        case .boundaryCountNonMonotonic: return "日期边界 count 不满足单调关系"
        case .lowerAnchorNotClosed: return "最早日期之前仍有记录，下界未闭合"
        case .afterLastUnboundedOverLimit: return "最后锚点之后超过 1000 条，无法有界追踪"
        case .requestBudgetExhausted: return "探针请求预算（32 次）已用完，结果不确定"
        case .cancelled: return "已取消"
        case .otherSanitizedFailure: return "探针未能完成（读取失败）"
        }
    }
}

/// A bounded, read-only, diagnostic-only probe answering one question (#155):
/// can public `query_study_records` enumerate every record its count APIs
/// claim exists, if `next_study_date` is partitioned into disjoint
/// whole-Beijing-day ranges?
///
/// Strictly bounded: at most `maxRequestBudget` count/data requests, no
/// retry, no invented pagination (the documented request contract has no
/// cursor/offset/secondary key), no production export semantic changes, and
/// no word lists. Every request and every decision lands in the existing
/// Study Export diagnostic journal as sanitized counts, ranges and fixed
/// verdicts — never voc_ids, spellings, credentials or raw payloads.
///
/// Stages:
/// 0. Baseline: global count + first data page → row/missing-date facts and
///    the first/last Beijing-day anchors (the coverage-gap anchor from the
///    failed export run extends the last-day bound when available).
/// 1. Global date-addressability: counts before firstDay / through lastDay /
///    after lastDay must partition the global total; an after-last segment
///    ≤1000 is fetched once and compared.
/// 2. Bounded recursive partition of [firstDay, lastDay] by whole-day
///    midpoints: every child count sum must equal its parent, every leaf
///    (count ≤ 1000) must close with rows == count == uniques and no nil or
///    out-of-range dates; one Beijing day holding more than 1000 records is
///    decisive (`singleDayOverLimit`) because the public contract cannot
///    enumerate it.
final class StudyRecordEnumerabilityProbe {
    static let maxRequestBudget = 32

    private let api: MaimemoTransport
    private let journal: StudyExportDiagnosticJournal?
    private let hintAnchorDate: Date?
    private let now: () -> Date

    private var control: ExecutionControl?
    private var requestsUsed = 0
    private var runID = ""

    init(
        api: MaimemoTransport,
        journal: StudyExportDiagnosticJournal?,
        hintAnchorDate: Date?,
        now: @escaping () -> Date = Date.init
    ) {
        self.api = api
        self.journal = journal
        self.hintAnchorDate = hintAnchorDate
        self.now = now
    }

    /// Runs the probe to exactly one verdict. Never throws; every failure
    /// path is a sanitized verdict. Never auto-invoked: the Owner taps the
    /// explicit probe action.
    func run(control: ExecutionControl, runID: String) async -> StudyRecordEnumerabilityProbeVerdict {
        self.control = control
        self.runID = runID
        log("enumerability_probe_start")
        let verdict: StudyRecordEnumerabilityProbeVerdict
        do {
            verdict = try await execute()
        } catch let abort as Abort {
            switch abort {
            case .budgetExhausted:
                log("probe_stop reason=request_budget requests_used=\(requestsUsed)")
                verdict = .requestBudgetExhausted
            case .cancelled:
                log("probe_stop reason=cancelled requests_used=\(requestsUsed)")
                verdict = .cancelled
            case let .sanitized(category):
                log("probe_stop reason=sanitized_failure category=\(category) requests_used=\(requestsUsed)")
                verdict = .otherSanitizedFailure
            }
        } catch {
            // Unreachable while every helper sanitizes its errors; kept so the
            // catch is exhaustive and a stray failure can never crash the app.
            log("probe_stop reason=sanitized_failure category=unknown requests_used=\(requestsUsed)")
            verdict = .otherSanitizedFailure
        }
        // Exactly one verdict line, on every path (success, bounded failure,
        // cancellation alike).
        log("enumerability_probe_verdict verdict=\(verdict.rawValue)")
        return verdict
    }

    // MARK: - Stages

    private func execute() async throws -> StudyRecordEnumerabilityProbeVerdict {
        // Step 0 — baseline.
        let globalCount = try await countCall(start: nil, end: nil)
        log("probe_global total=\(globalCount)")
        let firstPage = try await dataCall(start: nil, end: nil)
        let datedRows = firstPage.records.compactMap(\.nextStudyDate)
        let missingNextDate = firstPage.records.count - datedRows.count
        log(
            "probe_first_page rows=\(firstPage.records.count)"
                + " missing_next_date=\(missingNextDate)"
        )
        guard let minDated = datedRows.min(), let maxDated = datedRows.max() else {
            log("probe_stop reason=no_dated_anchor")
            return .otherSanitizedFailure
        }
        // The first page's min/max are SEARCH SEEDS only — the Owner's real
        // account proved the unbounded first page can miss genuinely earlier
        // dated records (LOWER_ANCHOR_NOT_CLOSED at head 6c35421).
        var lowerCandidate = StudyExportSemantics.beijingDayStart(minDated)
        var upperCandidate = StudyExportSemantics.beijingDayStart(maxDated)
        if let hint = hintAnchorDate {
            let hintDay = StudyExportSemantics.beijingDayStart(hint)
            if hintDay > upperCandidate { upperCandidate = hintDay }
        }
        log(
            "probe_anchor seed_first_day=\(StudyExportSemantics.beijingDayString(lowerCandidate))"
                + " seed_last_day=\(StudyExportSemantics.beijingDayString(upperCandidate))"
        )

        // Part A — lower-bound closure: count-only exponential backward search
        // until the envelope's lower edge is proven closed (countBefore == 0).
        // Counts must be non-increasing as the candidate moves earlier.
        var lowerStep = 1
        var previousCountBefore: Int?
        var lowerClosed = false
        while lowerClosed == false {
            let countBefore = try await countCall(
                start: nil,
                end: StudyExportSemantics.previousDayEnd(lowerCandidate)
            )
            log(
                "probe_lower_search step=\(lowerStep)"
                    + " candidate=\(StudyExportSemantics.beijingDayString(lowerCandidate))"
                    + " count_before=\(countBefore)"
            )
            if let previous = previousCountBefore, countBefore > previous {
                log("probe_stop reason=boundary_count_non_monotonic direction=lower")
                return .boundaryCountNonMonotonic
            }
            if countBefore == 0 {
                lowerClosed = true
                log(
                    "probe_lower_closed date=\(StudyExportSemantics.beijingDayString(lowerCandidate))"
                        + " requests_used=\(requestsUsed)"
                )
                break
            }
            lowerCandidate = StudyExportSemantics.beijingDayShift(lowerCandidate, days: -lowerStep)
            lowerStep *= 2
            previousCountBefore = countBefore
        }

        // Part B — upper-bound closure: the symmetric exponential forward
        // search. Cheap count-only calls move the envelope arbitrarily far —
        // no unbounded-future early exit exists in the corrected route.
        var upperStep = 1
        var previousCountAfter: Int?
        var upperClosed = false
        while upperClosed == false {
            let countAfter = try await countCall(
                start: StudyExportSemantics.nextDayStart(upperCandidate),
                end: nil
            )
            log(
                "probe_upper_search step=\(upperStep)"
                    + " candidate=\(StudyExportSemantics.beijingDayString(upperCandidate))"
                    + " count_after=\(countAfter)"
            )
            if let previous = previousCountAfter, countAfter > previous {
                log("probe_stop reason=boundary_count_non_monotonic direction=upper")
                return .boundaryCountNonMonotonic
            }
            if countAfter == 0 {
                upperClosed = true
                log(
                    "probe_upper_closed date=\(StudyExportSemantics.beijingDayString(upperCandidate))"
                        + " requests_used=\(requestsUsed)"
                )
                break
            }
            upperCandidate = StudyExportSemantics.beijingDayShift(upperCandidate, days: upperStep)
            upperStep *= 2
            previousCountAfter = countAfter
        }

        // Part C — bounded-root equality: the decisive check for records the
        // global count sees but the fully closed date envelope cannot account
        // for. Never labelled next_study_date=nil without a returned record
        // proving exactly that.
        let envelopeStart = lowerCandidate
        let envelopeEnd = StudyExportSemantics.beijingDayEnd(upperCandidate)
        log(
            "probe_boundary_closed"
                + " lower=\(StudyExportSemantics.beijingDayString(envelopeStart))"
                + " upper=\(StudyExportSemantics.beijingDayString(upperCandidate))"
        )
        let boundedRootCount = try await countCall(start: envelopeStart, end: envelopeEnd)
        log("probe_bounded_root global=\(globalCount) bounded=\(boundedRootCount)")
        if boundedRootCount != globalCount {
            return .globalNotDatePartitionable
        }

        // Part D — bounded recursive partition of the proven envelope
        // [lowerClosed .. upperClosed].
        let rootStart = envelopeStart
        let rootEnd = envelopeEnd
        let rootCount = boundedRootCount
        log(
            "probe_range depth=0"
                + " start=\(StudyExportSemantics.beijingDayString(rootStart))"
                + " end=\(StudyExportSemantics.beijingDayString(rootEnd))"
                + " count=\(rootCount)"
        )
        // Explicit stack (right child first) — no recursion depth risk.
        var stack: [(start: Date, end: Date, count: Int, depth: Int)] = [
            (rootStart, rootEnd, rootCount, 0)
        ]
        while let item = stack.popLast() {
            if let control, control.isCancellationRequested {
                throw Abort.cancelled
            }
            if item.count == 0 {
                continue // An empty child closes trivially.
            }
            if item.count <= CompanionConstants.studyPageSize {
                let verdict = try await closeLeaf(
                    start: item.start, end: item.end, expectedCount: item.count
                )
                if let verdict { return verdict }
            } else {
                let spanDays = StudyExportSemantics.beijingDayDistance(from: item.start, to: item.end) + 1
                guard spanDays > 1 else {
                    // One Beijing day holding more than the public page limit:
                    // with no cursor/offset/secondary key that day cannot be
                    // proven fully enumerable. Never re-read the same day.
                    log(
                        "probe_stop reason=single_day_over_limit"
                            + " date=\(StudyExportSemantics.beijingDayString(item.start))"
                            + " count=\(item.count)"
                    )
                    return .singleDayOverLimit
                }
                // Whole-day midpoint: the left child's closing day. With
                // spanDays ≥ 2 this is strictly inside the range, so both
                // children are smaller than the parent and recursion converges.
                let midpointDay = StudyExportSemantics.beijingDayShift(item.start, days: (spanDays - 1) / 2)
                let leftEnd = StudyExportSemantics.beijingDayEnd(midpointDay)
                let rightStart = StudyExportSemantics.nextDayStart(midpointDay)
                let leftCount = try await countCall(start: item.start, end: leftEnd)
                let rightCount = try await countCall(start: rightStart, end: item.end)
                log(
                    "probe_split parent=\(item.count) left=\(leftCount) right=\(rightCount)"
                        + " depth=\(item.depth)"
                )
                if leftCount + rightCount != item.count {
                    return .countPartitionInconsistent
                }
                // Disjoint and exhaustive by construction:
                // [item.start, leftEnd] ∪ [rightStart, item.end].
                if leftCount > 0 {
                    stack.append((item.start, leftEnd, leftCount, item.depth + 1))
                }
                if rightCount > 0 {
                    stack.append((rightStart, item.end, rightCount, item.depth + 1))
                }
            }
        }
        return .datePartitionEnumerable
    }

    /// One leaf: exactly one data call with the exact same start/end, then the
    /// frozen closure rules. Returns a terminal verdict when the leaf fails to
    /// close, `nil` when it closes.
    private func closeLeaf(
        start: Date,
        end: Date,
        expectedCount: Int
    ) async throws -> StudyRecordEnumerabilityProbeVerdict? {
        log(
            "probe_leaf_start"
                + " start=\(StudyExportSemantics.beijingDayString(start))"
                + " end=\(StudyExportSemantics.beijingDayString(end))"
                + " count=\(expectedCount)"
        )
        let page = try await dataCall(start: start, end: end)
        let rows = page.records.count
        let uniqueCount = Set(page.records.map(\.vocabularyID)).count
        let dated = page.records.compactMap(\.nextStudyDate)
        let missingNextDate = rows - dated.count
        let outOfRange = dated.contains { $0 < start || $0 > end }
        log(
            "probe_leaf"
                + " start=\(StudyExportSemantics.beijingDayString(start))"
                + " end=\(StudyExportSemantics.beijingDayString(end))"
                + " count=\(expectedCount) rows=\(rows) unique=\(uniqueCount)"
                + " missing_next_date=\(missingNextDate)"
        )
        if rows != expectedCount {
            return .leafCountDataGap
        }
        if uniqueCount != rows {
            return .leafDuplicateIDs
        }
        if missingNextDate > 0 {
            return .filteredResponseContainsNilDate
        }
        if outOfRange {
            return .filteredResponseOutOfRange
        }
        return nil
    }

    // MARK: - Bounded request helpers

    private func checkBudgetAndCancellation() throws {
        if let control, control.isCancellationRequested {
            throw Abort.cancelled
        }
        guard requestsUsed < Self.maxRequestBudget else {
            throw Abort.budgetExhausted
        }
        requestsUsed += 1
    }

    private func countCall(start: Date?, end: Date?) async throws -> Int {
        try checkBudgetAndCancellation()
        do {
            let page = try await api.studyRecords(
                nextStudyDateStart: start.map(StudyExportSemantics.beijingISO8601),
                nextStudyDateEnd: end.map(StudyExportSemantics.beijingISO8601),
                asCount: true,
                control: control
            )
            return page.count
        } catch {
            throw sanitize(error)
        }
    }

    private func dataCall(start: Date?, end: Date?) async throws -> StudyRecordsPage {
        try checkBudgetAndCancellation()
        do {
            return try await api.studyRecords(
                nextStudyDateStart: start.map(StudyExportSemantics.beijingISO8601),
                nextStudyDateEnd: end.map(StudyExportSemantics.beijingISO8601),
                asCount: false,
                control: control
            )
        } catch {
            throw sanitize(error)
        }
    }

    private func sanitize(_ error: Error) -> Abort {
        if error is CancellationError {
            return .cancelled
        }
        if let companionError = error as? CompanionError, companionError == .cancelled {
            return .cancelled
        }
        return .sanitized(StudyExportDiagnosticCategory.sanitized(error))
    }

    private func log(_ text: String) {
        journal?.log(text, run: runID)
    }

    private enum Abort: Error {
        case budgetExhausted
        case cancelled
        case sanitized(String)
    }
}
