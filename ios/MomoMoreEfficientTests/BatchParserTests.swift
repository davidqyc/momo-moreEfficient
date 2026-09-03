import XCTest
@testable import MomoMoreEfficient

final class BatchParserTests: XCTestCase {
    func testCanonicalMarkdownParserParity() throws {
        let body = "v. 利用；借助\n\n   缩进保留"
        let batch = try BatchParser.parseDailyInput("## leverage\n\(body)\n")
        XCTAssertEqual(batch.inputFormat, .canonicalMarkdown)
        XCTAssertEqual(batch.entries[0].spelling, "leverage")
        XCTAssertEqual(batch.entries[0].interpretation, body)
    }

    func testCompactNoBlankParserParity() throws {
        let batch = try BatchParser.parseDailyInput(
            "reclaim\nv. 收回\nv. 开垦\nmass\nadj. 大规模的\nn. 大量"
        )
        XCTAssertEqual(batch.entries.map(\.spelling), ["reclaim", "mass"])
        XCTAssertEqual(batch.entries[0].interpretation, "v. 收回\nv. 开垦")
        XCTAssertEqual(batch.entries[1].interpretation, "adj. 大规模的\nn. 大量")
    }

    func testRealisticMultiItemClosedPOSFamily() throws {
        let batch = try BatchParser.parseDailyInput(
            "word1\nn. 一\nword2\nadv. 二\nword3\nphr. 三\nword4\nprep. 四"
        )
        XCTAssertEqual(batch.entries.count, 4)
        XCTAssertEqual(BatchParser.posMarkers.prefix(5), ["n.", "v.", "adj.", "adv.", "phr."])
    }

    func testBlankDelimitedLegacyInputRemainsDeterministic() throws {
        let batch = try BatchParser.parseDailyInput("first\nowner body\n\nsecond\nother body")
        XCTAssertEqual(batch.entries.map(\.interpretation), ["owner body", "other body"])
    }

    func testAmbiguousCompactInputFailsClosed() {
        for value in [
            "reclaim\nv. 收回\nmass",
            "reclaim\npossible continuation\nmass\nn. 大量",
            "reclaim\nv. 收回\nmass\nadj.",
        ] {
            XCTAssertThrowsError(try BatchParser.parseDailyInput(value))
        }
    }

    func testMalformedCanonicalHeadingFailsClosed() {
        for value in ["# word\nn. x", "##word\nn. x", "## \nn. x", "text\n## word\nn. x"] {
            XCTAssertThrowsError(try BatchParser.parseCanonical(value))
        }
    }

    func testDuplicateSpellingIsCaseInsensitive() {
        XCTAssertThrowsError(
            try BatchParser.parseCanonical("## Word\nn. 一\n\n## WORD\nn. 二")
        )
    }

    func testExactBodyTextPreservation() throws {
        let body = "n. 原文  \n\n   缩进\nv. 第二行"
        let entry = try BatchParser.parseCanonical("## exact\n\(body)\n\n")[0]
        XCTAssertEqual(entry.interpretation, body)
    }

    func testCanonicalDocumentRoundTripPreservesEntryOrderSpellingAndBodies() throws {
        let firstBody = "n. 原文尾空格  \n\n   缩进保留"
        let secondBody = "v. 第二条\nn. 最后一行"
        let source = [
            "## MiXeD-First\n\(firstBody)",
            "## second.EXACT\n\(secondBody)",
        ].joined(separator: "\n\n")
        let entries = try BatchParser.parseCanonical(source)

        let rebuilt = BatchParser.canonicalDocument(for: entries)
        let roundTripped = try BatchParser.parseDailyInput(rebuilt).entries

        XCTAssertEqual(roundTripped.map(\.spelling), ["MiXeD-First", "second.EXACT"])
        XCTAssertEqual(roundTripped.map(\.interpretation), entries.map(\.interpretation))
        XCTAssertEqual(roundTripped, entries)
    }

    /// #164 removed the artificial 30-item product cap. The real bounds — total
    /// input bytes, per-interpretation length and duplicate spellings — stay.
    func testRealInputBoundsFailClosedWithoutAnArtificialItemCap() throws {
        let beyondOldCap = (0..<200).map { "## w\($0)\nn. x" }.joined(separator: "\n\n")
        XCTAssertEqual(try BatchParser.parseCanonical(beyondOldCap).count, 200)

        XCTAssertThrowsError(
            try BatchParser.parseCanonical("## word\n" + String(repeating: "释", count: 2_001))
        )
        XCTAssertThrowsError(
            try BatchParser.parseCanonical("## word\nn. 一\n\n## WORD\nn. 二")
        )
        let oversized = (0..<40_000).map { "## w\($0)\nn. 释义" }.joined(separator: "\n\n")
        XCTAssertGreaterThan(oversized.utf8.count, CompanionConstants.maxInputBytes)
        XCTAssertThrowsError(try BatchParser.parseCanonical(oversized))
    }

    @MainActor
    func testCredentialMovesToDedicatedObjectAndEditableStringClears() throws {
        var draft = fakeToken
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            transportFactory: { FakeHTTPTransport([]) },
            sleeperFactory: { RecordingSleeper() }
        )
        model.installVerifiedCredentialForTesting(token: &draft)
        XCTAssertTrue(model.isConnected)
        XCTAssertTrue(draft.isEmpty)
    }

    func testCredentialDebugDescriptionsAreRedacted() throws {
        let credential = try InMemoryCredential(token: fakeToken)
        let lease = try credential.makeOperationLease()
        XCTAssertFalse(credential.debugDescription.contains(fakeToken))
        XCTAssertFalse(lease.debugDescription.contains(fakeToken))
        XCTAssertEqual(credential.fingerprint.count, 16)
    }

    // MARK: - Issue #164 — blank lines optional, no artificial item cap

    /// The same unambiguous compact batch, with and without blank separators,
    /// must produce identical entries.
    func testCompactBatchParsesIdenticallyWithAndWithoutBlankLines() throws {
        let records = [
            "acquisition\nn. 收购\nv. 取得",
            "liquidity\nn. 流动性",
            "sphere\nn. 球体\nadj. 球形的",
        ]
        let spaced = try BatchParser.parseDailyInput(records.joined(separator: "\n\n"))
        let dense = try BatchParser.parseDailyInput(records.joined(separator: "\n"))

        XCTAssertEqual(spaced.entries, dense.entries)
        XCTAssertEqual(dense.entries.map(\.spelling), ["acquisition", "liquidity", "sphere"])
        XCTAssertEqual(dense.entries[0].interpretation, "n. 收购\nv. 取得")
        XCTAssertEqual(spaced.canonicalText, dense.canonicalText)
    }

    func testCanonicalMarkdownParsesIdenticallyWithAndWithoutBlankLines() throws {
        let records = ["## alpha\nn. 一", "## beta\nn. 二", "## gamma\nn. 三"]
        XCTAssertEqual(
            try BatchParser.parseCanonical(records.joined(separator: "\n\n")),
            try BatchParser.parseCanonical(records.joined(separator: "\n"))
        )
    }

    /// Removing the item cap must not make free-form boundaries guessable.
    func testAmbiguousBoundariesStillRejectRatherThanGuess() {
        XCTAssertThrowsError(try BatchParser.parseDailyInput("alpha\n一\nbeta\n二"))
        XCTAssertThrowsError(try BatchParser.parseDailyInput("alpha\nn. 一\nbeta\n二"))
        XCTAssertThrowsError(try BatchParser.parseDailyInput("n. 一\nn. 二"))
    }

    func testBatchesWellBeyondThirtyItemsParseInBothLayouts() throws {
        let records = (0..<400).map { "word\($0)\nn. 释义\($0)" }
        let spaced = try BatchParser.parseDailyInput(records.joined(separator: "\n\n"))
        let dense = try BatchParser.parseDailyInput(records.joined(separator: "\n"))

        XCTAssertEqual(spaced.entries.count, 400)
        XCTAssertEqual(spaced.entries, dense.entries)
        XCTAssertEqual(spaced.entries.map(\.ordinal), Array(1...400))
        XCTAssertEqual(spaced.entries.last?.spelling, "word399")
    }
}
