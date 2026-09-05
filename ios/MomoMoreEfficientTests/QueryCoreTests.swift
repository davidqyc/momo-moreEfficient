import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The pure Query core: input parsing, the request-budget advisory, the count
/// projection, and the local filter. Everything here is a function of its
/// arguments — no clock, no credential, no network.
final class QueryCoreTests: XCTestCase {

    // MARK: - Parser

    func testSplitsOnNewlineAndBothCommasOnly() throws {
        let parse = try QueryInputParser.parse("apple\nbanana,cherry，date")
        XCTAssertEqual(parse.inputs.map(\.spelling), ["apple", "banana", "cherry", "date"])
        XCTAssertEqual(parse.inputs.map(\.ordinal), [1, 2, 3, 4])
    }

    func testSemicolonIsNotASeparatorInV1() throws {
        // Frozen decision: `;` and `；` stay inside the word they were typed in.
        let parse = try QueryInputParser.parse("apple;banana")
        XCTAssertEqual(parse.inputs.map(\.spelling), ["apple;banana"])

        let full = try QueryInputParser.parse("apple；banana")
        XCTAssertEqual(full.inputs.map(\.spelling), ["apple；banana"])
    }

    func testNeverSplitsOnSpaceHyphenOrSlash() throws {
        let parse = try QueryInputParser.parse(
            "take into account\nwell-known\nand/or\nby and large"
        )
        XCTAssertEqual(
            parse.inputs.map(\.spelling),
            ["take into account", "well-known", "and/or", "by and large"]
        )
    }

    func testTrimsSurroundingWhitespaceWithoutTouchingInnerSpaces() throws {
        let parse = try QueryInputParser.parse("  take into account  ,\t banana \n")
        XCTAssertEqual(parse.inputs.map(\.spelling), ["take into account", "banana"])
    }

    func testDeduplicatesNetworkWorkWhilePreservingEveryVisibleRow() throws {
        let parse = try QueryInputParser.parse("Apple\nbanana\napple\nAPPLE\nbanana")
        // Every typed row stays visible, in order.
        XCTAssertEqual(
            parse.inputs.map(\.spelling),
            ["Apple", "banana", "apple", "APPLE", "banana"]
        )
        XCTAssertEqual(parse.visibleCount, 5)
        // Network work happens once per distinct normalized word.
        XCTAssertEqual(parse.uniqueSpellings, ["Apple", "banana"])
        XCTAssertEqual(parse.uniqueCount, 2)
        // Rows naming the same word share the same network identity.
        XCTAssertEqual(parse.inputs[0].normalized, parse.inputs[2].normalized)
        XCTAssertEqual(parse.inputs[0].normalized, parse.inputs[3].normalized)
    }

    func testBlankAndEmptyEntriesAreDroppedNotCounted() throws {
        let parse = try QueryInputParser.parse("apple\n\n\n,,,  ,\nbanana\n")
        XCTAssertEqual(parse.inputs.map(\.spelling), ["apple", "banana"])
    }

    func testMalformedInputFailsClosed() {
        for malformed in ["", "   \n\n  ", ",,,", "\n"] {
            XCTAssertThrowsError(try QueryInputParser.parse(malformed), malformed)
        }
        // An entry that cannot be safely resolved rejects the whole document
        // rather than being silently dropped.
        XCTAssertThrowsError(try QueryInputParser.parse("apple\nba\u{0007}nana"))
        XCTAssertThrowsError(
            try QueryInputParser.parse(String(repeating: "a", count: 257))
        )
        XCTAssertThrowsError(
            try QueryInputParser.parse(
                String(repeating: "a", count: CompanionConstants.maxInputBytes + 1)
            )
        )
    }

    func testParseForDisplayDistinguishesEmptyFromMalformed() {
        XCTAssertEqual(QueryInputParser.parseForDisplay("   "), QueryInputParse.empty)
        XCTAssertNil(QueryInputParser.parseForDisplay("ba\u{0007}nana"))
        XCTAssertEqual(QueryInputParser.parseForDisplay("apple")?.visibleCount, 1)
    }

    // MARK: - Request budget

    func testBudgetIsResolverChunksPlusThreeReadsPerUniqueInput() {
        let budget = QueryRequestBudget.estimate(uniqueInputCount: 10)
        XCTAssertEqual(budget.resolverRequests, 1)
        XCTAssertEqual(budget.contentRequests, 30)
        XCTAssertEqual(budget.estimatedRequests, 31)

        // Resolver chunking follows the documented 1000-per-request bound.
        XCTAssertEqual(QueryRequestBudget.estimate(uniqueInputCount: 1_000).resolverRequests, 1)
        XCTAssertEqual(QueryRequestBudget.estimate(uniqueInputCount: 1_001).resolverRequests, 2)
        XCTAssertEqual(QueryRequestBudget.estimate(uniqueInputCount: 0).estimatedRequests, 0)
    }

    func testAdvisoryTiersFollowTheRealSchedulerWindows() {
        // <= 40 estimated requests: no advisory at all.
        let quiet = QueryRequestBudget.estimate(uniqueInputCount: 13) // 1 + 39 = 40
        XCTAssertEqual(quiet.estimatedRequests, 40)
        XCTAssertEqual(quiet.tier, .quiet)
        XCTAssertNil(quiet.advisory)

        // Just over the 40/60s window: a calm duration hint.
        let calm = QueryRequestBudget.estimate(uniqueInputCount: 14) // 1 + 42 = 43
        XCTAssertEqual(calm.tier, .calm)
        let calmCopy = try? XCTUnwrap(calm.advisory)
        XCTAssertEqual(
            calmCopy,
            "较大批次：预计约 43 次请求（定位 1 次 + 每项最多 3 次读取），"
                + "受墨墨频率限制约需 2 分钟；读取中可随时停止，已读结果保留。"
        )

        // At/above the 2000/5h allowance: the 建议分批 advisory.
        let strong = QueryRequestBudget.estimate(uniqueInputCount: 700) // 1 + 2100
        XCTAssertEqual(strong.tier, .suggestSplitting)
        XCTAssertEqual(
            strong.advisory,
            "建议分批：预计约 2101 次请求，超出墨墨 5 小时内 2000 次的额度，"
                + "一次读完可能需要等待数小时。建议每批 600 项以内；仍可开始，读取中可随时停止。"
        )
    }

    func testAdvisoryIsNeverACapAndIsDrivenByUniqueItemsNotVisibleRows() throws {
        // 600 items is advisory wording, not a limit: a larger batch still
        // produces a budget and stays startable.
        let huge = QueryRequestBudget.estimate(uniqueInputCount: 5_000)
        XCTAssertEqual(huge.tier, .suggestSplitting)
        XCTAssertGreaterThan(huge.estimatedRequests, 2_000)

        // Duplicates cost nothing extra.
        let parse = try QueryInputParser.parse(
            (0..<50).map { _ in "apple" }.joined(separator: "\n")
        )
        XCTAssertEqual(parse.visibleCount, 50)
        XCTAssertEqual(QueryRequestBudget.estimate(for: parse).estimatedRequests, 4)
    }

    // MARK: - Projection

    func testInterpretationCountsBothPublishedAndUnpublishedButNotDeleted() {
        let records = [
            InterpretationRecord(id: "A", interpretation: "x", tags: [], status: "PUBLISHED"),
            InterpretationRecord(id: "B", interpretation: "y", tags: [], status: "UNPUBLISHED"),
            InterpretationRecord(id: "C", interpretation: "z", tags: [], status: "DELETED"),
        ]
        XCTAssertEqual(QueryProjection.interpretationCell(records), .count(2))
        XCTAssertEqual(QueryProjection.activeInterpretations(records).map(\.id), ["A", "B"])
        XCTAssertEqual(QueryProjection.interpretationCell([]), .count(0))
    }

    func testTwoSafeInterpretationsAreSimplyTwoNotAQueryError() {
        // Write Preview treats multiple self-authored interpretations as
        // AMBIGUOUS because it cannot pick a unique update target. Read-only
        // Query has no such problem: it is just 释义 2.
        let records = [
            InterpretationRecord(id: "A", interpretation: "x", tags: [], status: "PUBLISHED"),
            InterpretationRecord(id: "B", interpretation: "y", tags: [], status: "PUBLISHED"),
        ]
        XCTAssertEqual(QueryProjection.interpretationCell(records), .count(2))
    }

    func testPhraseCountsPublishedOnly() {
        let records = [
            makePhrase("A", status: "PUBLISHED"),
            makePhrase("B", status: "DELETED"),
        ]
        XCTAssertEqual(QueryProjection.phraseCell(records), .count(1))
        XCTAssertEqual(QueryProjection.activePhrases(records).map(\.id), ["A"])
    }

    func testNoteCountsPublishedExcludesDeletedAndFailsClosedOnUnspecified() {
        let counted = [
            NoteRecord(id: "A", noteType: "M", note: "a", status: "PUBLISHED"),
            NoteRecord(id: "B", noteType: "M", note: "b", status: "DELETED"),
        ]
        XCTAssertEqual(QueryProjection.noteCell(counted), .count(1))
        XCTAssertEqual(QueryProjection.activeNotes(counted).map(\.id), ["A"])

        // An UNSPECIFIED status has no safe counting meaning: the cell becomes
        // unavailable rather than reporting a smaller number.
        let unsafe = counted + [
            NoteRecord(id: "C", noteType: "M", note: "c", status: "NOTE_STATUS_UNSPECIFIED"),
        ]
        XCTAssertEqual(
            QueryProjection.noteCell(unsafe),
            .unavailable(.responseNotSafelyReadable)
        )
        XCTAssertNil(QueryProjection.noteCell(unsafe).knownCount)
    }

    func testZeroIsNeverTheSameAsUnavailable() {
        let zero = QueryCellState.count(0)
        let unavailable = QueryCellState.unavailable(.responseNotSafelyReadable)
        XCTAssertNotEqual(zero, unavailable)
        XCTAssertEqual(zero.knownCount, 0)
        XCTAssertNil(unavailable.knownCount)
        XCTAssertNil(QueryCellState.unread.knownCount)
        XCTAssertNil(QueryCellState.queued.knownCount)
        XCTAssertNil(QueryCellState.loading.knownCount)
    }

    func testOnlyTruthfulTerminalCellStatesCountAsDone() {
        XCTAssertTrue(QueryCellState.count(0).isTerminal)
        XCTAssertTrue(QueryCellState.unavailable(.targetNotFound).isTerminal)
        XCTAssertFalse(QueryCellState.queued.isTerminal)
        XCTAssertFalse(QueryCellState.loading.isTerminal)
        // Unread is explicitly *not* terminal: 继续查阅 may still read it.
        XCTAssertFalse(QueryCellState.unread.isTerminal)
    }

    func testAGlobalFailureIsNotDowngradedToAPerCellInability() {
        for global in [
            CompanionError.authenticationRejected, .transport, .rateLimited,
            .serverFailure, .globalHTTPFailure, .responseRejected,
        ] {
            XCTAssertNil(QueryProjection.cellFailure(global), "\(global)")
        }
        XCTAssertNil(QueryProjection.cellFailure(.cancelled))
        XCTAssertEqual(
            QueryProjection.cellFailure(.itemResponseRejected),
            .unavailable(.responseNotSafelyReadable)
        )
    }

    // MARK: - Filter

    func testDimensionsCombineWithAND() {
        let rows = [
            makeRow(1, "alpha", interpretation: .count(0), phrase: .count(2), note: .count(0)),
            makeRow(2, "beta", interpretation: .count(0), phrase: .count(0), note: .count(0)),
            makeRow(3, "gamma", interpretation: .count(3), phrase: .count(2), note: .count(1)),
        ]
        var filter = QueryFilter()
        filter.interpretation = .zero
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["alpha", "beta"])

        filter.phrase = .positive
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["alpha"])

        filter.note = .positive
        XCTAssertTrue(filter.apply(to: rows).isEmpty)
    }

    func testUnreadLoadingAndUnavailableNeverSatisfyANumericPredicate() {
        let rows = [
            makeRow(1, "unread", interpretation: .unread, phrase: .unread, note: .unread),
            makeRow(2, "loading", interpretation: .loading, phrase: .queued, note: .queued),
            makeRow(
                3, "broken",
                interpretation: .unavailable(.responseNotSafelyReadable),
                phrase: .count(0),
                note: .count(0)
            ),
            makeRow(4, "known", interpretation: .count(0), phrase: .count(0), note: .count(0)),
        ]
        var zero = QueryFilter()
        zero.interpretation = .zero
        XCTAssertEqual(zero.apply(to: rows).map(\.spelling), ["known"])

        var positive = QueryFilter()
        positive.interpretation = .positive
        XCTAssertTrue(positive.apply(to: rows).isEmpty)
    }

    func testAPartiallyReadableRowStillMatchesItsKnownNumbers() {
        let row = makeRow(
            1, "partial",
            interpretation: .count(2),
            phrase: .count(0),
            note: .unavailable(.responseNotSafelyReadable)
        )
        var filter = QueryFilter()
        filter.interpretation = .positive
        filter.phrase = .zero
        XCTAssertTrue(filter.matches(row))
        // …and it is an 无法读取 row, not a 正常 one.
        XCTAssertEqual(row.readStatus, .unavailable)

        filter.note = .zero
        XCTAssertFalse(filter.matches(row))
    }

    func testReadStatusDimensionAndPresentOnlyReasonNarrowing() {
        var notFound = makeRow(1, "missing", interpretation: .queued, phrase: .queued, note: .queued)
        notFound.rowInability = .targetNotFound
        let decoderFailure = makeRow(
            2, "broken",
            interpretation: .count(1),
            phrase: .count(0),
            note: .unavailable(.responseNotSafelyReadable)
        )
        let normal = makeRow(3, "fine", interpretation: .count(1), phrase: .count(0), note: .count(0))
        let unread = makeRow(4, "later", interpretation: .unread, phrase: .unread, note: .unread)
        let rows = [notFound, decoderFailure, normal, unread]

        var filter = QueryFilter()
        filter.readStatus = .normal
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["fine"])

        filter.readStatus = .unread
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["later"])

        filter.readStatus = .unavailable
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["missing", "broken"])

        // Reason narrowing only applies within 无法读取.
        filter.inabilityReasons = [.targetNotFound]
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["missing"])

        filter.inabilityReasons = [.responseNotSafelyReadable]
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["broken"])

        filter.inabilityReasons = [.targetNotFound, .responseNotSafelyReadable]
        XCTAssertEqual(filter.apply(to: rows).map(\.spelling), ["missing", "broken"])
    }

    func testFilterResetAndActiveChipLabels() {
        var filter = QueryFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue(filter.activeChipLabels.isEmpty)

        filter.phrase = .zero
        filter.note = .positive
        filter.readStatus = .unavailable
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual(
            filter.activeChipLabels,
            ["例句 = 0", "助记 > 0", "读取状态 无法读取"]
        )

        filter = .none
        XCTAssertFalse(filter.isActive)
    }

    func testAWhollyUnresolvedRowDoesNotMatchEqualsZero() {
        var row = makeRow(1, "missing", interpretation: .queued, phrase: .queued, note: .queued)
        row.rowInability = .targetNotFound
        var filter = QueryFilter()
        filter.interpretation = .zero
        XCTAssertFalse(filter.matches(row))
    }

    // MARK: - Helpers

    private func makeRow(
        _ ordinal: Int,
        _ spelling: String,
        interpretation: QueryCellState,
        phrase: QueryCellState,
        note: QueryCellState
    ) -> QueryRow {
        var row = QueryRow(
            input: QueryInput(
                ordinal: ordinal,
                spelling: spelling,
                normalized: BatchParser.normalizeSpelling(spelling)
            )
        )
        row.cells[.interpretation] = interpretation
        row.cells[.phrase] = phrase
        row.cells[.note] = note
        return row
    }

    private func makePhrase(_ id: String, status: String) -> PhraseRecord {
        PhraseRecord(
            id: id,
            phrase: "en",
            interpretation: "zh",
            tags: nil,
            origin: "",
            status: status,
            highlight: .missing
        )
    }
}
