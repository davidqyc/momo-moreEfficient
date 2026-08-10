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

    func testBatchAndInterpretationBoundsFailClosed() {
        let tooMany = (0...30).map { "## w\($0)\nn. x" }.joined(separator: "\n\n")
        XCTAssertThrowsError(try BatchParser.parseCanonical(tooMany))
        XCTAssertThrowsError(try BatchParser.parseCanonical("## word\n" + String(repeating: "释", count: 2_001)))
    }

    @MainActor
    func testCredentialMovesToDedicatedObjectAndEditableStringClears() throws {
        var draft = fakeToken
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            transportFactory: { FakeHTTPTransport([]) },
            sleeperFactory: { RecordingSleeper() }
        )
        model.connect(token: &draft)
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
}
