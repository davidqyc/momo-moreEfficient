import XCTest
@testable import MomoMoreEfficient

final class PhraseBatchParserTests: XCTestCase {
    func testNativeThreeLineRecordHasNoSourceAndPreservesText() throws {
        let entries = try PhraseBatchParser.parse(
            "acquisition\nThe  acquisition strengthened our position\n这次收购加强了地位"
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].spelling, "acquisition")
        XCTAssertEqual(entries[0].english, "The  acquisition strengthened our position")
        XCTAssertEqual(entries[0].chinese, "这次收购加强了地位")
        XCTAssertNil(entries[0].source)
    }

    func testNativeFourLineRecordPreservesExactSource() throws {
        let entries = try PhraseBatchParser.parse(
            "liquidity\nLiquidity matters\n流动性很重要\n课堂笔记 / unit  2"
        )
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].source, "课堂笔记 / unit  2")
    }

    func testNativeSourceMayStartWithNonLegacyHashText() throws {
        let entries = try PhraseBatchParser.parse(
            "liquidity\nLiquidity matters\n流动性很重要\n#1 classroom note"
        )
        XCTAssertEqual(entries[0].source, "#1 classroom note")
    }

    func testNativeBatchMixesThreeAndFourLineRecordsAcrossArbitraryBlankLines() throws {
        let document = """

        acquisition

        The acquisition strengthened our position

        这次收购加强了地位


        liquidity
        Liquidity matters

        流动性很重要
        WSJ

        """
        let entries = try PhraseBatchParser.parse(document)
        XCTAssertEqual(entries.map(\.spelling), ["acquisition", "liquidity"])
        XCTAssertEqual(entries.map(\.source), [nil, "WSJ"])
    }

    func testSegmentationEngineAcceptsOneCompleteSolutionAndRejectsAmbiguity() throws {
        let unique = try PhraseBatchParser.uniqueSegmentation(lineCount: 7) { range in
            range == 0..<3 || range == 3..<7
        }
        XCTAssertEqual(unique, [0..<3, 3..<7])

        XCTAssertThrowsError(
            try PhraseBatchParser.uniqueSegmentation(lineCount: 12) { _ in true }
        ) {
            XCTAssertEqual($0 as? CompanionError, .inputRejected)
        }
    }

    func testMalformedIncompleteAndMixedGrammarNativeInputFailsClosed() {
        assertRejected("word\nEnglish only")
        assertRejected("中文词\nAn English sentence\n中文翻译")
        assertRejected("word\n英文和 English 混合\n中文翻译")
        assertRejected("word\n12345\n中文翻译")
        assertRejected("word\nAn English sentence\nChinese translation")
        assertRejected("word\nAn English sentence\n中文翻译\n" + String(repeating: "s", count: 257))
        assertRejected("""
        ## word
        EN: sentence
        ZH: 翻译
        SOURCE: 自编
        another
        Another sentence
        另一条翻译
        """)
    }

    func testNativeDuplicateSpellingUsesExistingNormalizationRule() {
        assertRejected("""
        Word
        First sentence
        第一条翻译
        word
        Second sentence
        第二条翻译
        """)
    }

    func testNativeLogicalValuesRejectLeadingAndTrailingWhitespace() {
        assertRejected("word\n English sentence\n中文翻译")
        assertRejected("word\nEnglish sentence \n中文翻译")
        assertRejected("word\nEnglish sentence\n 中文翻译")
        assertRejected("word\nEnglish sentence\n中文翻译 ")
        assertRejected("word\nEnglish sentence\n中文翻译\n source")
        assertRejected("word\nEnglish sentence\n中文翻译\nsource ")
    }

    func testValidMultiEntryBatchPreservesExactValues() throws {
        let document = """
        ## acquisition
        EN: The acquisition  strengthened the company's position.
        ZH: 这次收购加强了公司的地位。
        SOURCE: 自编

        ## liquidity
        EN: Liquidity matters in a crisis.
        ZH: 流动性在危机中很重要。
        SOURCE: 课堂笔记 / unit  2
        """
        let entries = try PhraseBatchParser.parse(document)
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries.map(\.ordinal), [1, 2])
        XCTAssertEqual(entries.map(\.spelling), ["acquisition", "liquidity"])
        XCTAssertEqual(
            entries[0].english,
            "The acquisition  strengthened the company's position."
        )
        XCTAssertEqual(entries[0].chinese, "这次收购加强了公司的地位。")
        XCTAssertEqual(entries[1].source, "课堂笔记 / unit  2")
    }

    func testMissingDuplicateUnknownAndOutOfOrderFieldsFailClosed() {
        assertRejected("""
        ## word
        EN: sentence
        ZH: 翻译
        """)
        assertRejected("""
        ## word
        EN: sentence
        EN: duplicate
        ZH: 翻译
        SOURCE: 自编
        """)
        assertRejected("""
        ## word
        EN: sentence
        ZH: 翻译
        NOTE: unknown
        SOURCE: 自编
        """)
        assertRejected("""
        ## word
        ZH: 翻译
        EN: sentence
        SOURCE: 自编
        """)
        assertRejected("""
        ## word
        EN: sentence

        ZH: 翻译
        SOURCE: 自编
        """)
    }

    func testDuplicateSpellingUsesExistingNormalizationRule() {
        assertRejected("""
        ## Word
        EN: first
        ZH: 第一
        SOURCE: 自编

        ## word
        EN: second
        ZH: 第二
        SOURCE: 自编
        """)
    }

    func testEmptyValuesControlCharactersAndMalformedHeadingsFailClosed() {
        assertRejected("## word\nEN: \nZH: 翻译\nSOURCE: 自编")
        assertRejected("## word\nEN:    \nZH: 翻译\nSOURCE: 自编")
        assertRejected("## word\nEN: sentence\u{0007}\nZH: 翻译\nSOURCE: 自编")
        assertRejected("##word\nEN: sentence\nZH: 翻译\nSOURCE: 自编")
        assertRejected("# word\nEN: sentence\nZH: 翻译\nSOURCE: 自编")
        assertRejected("""
        ## word
        EN: sentence continuation
        that must not be inferred
        ZH: 翻译
        SOURCE: 自编
        """)
    }

    private func assertRejected(
        _ document: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try PhraseBatchParser.parse(document), file: file, line: line) {
            XCTAssertEqual($0 as? CompanionError, .inputRejected, file: file, line: line)
        }
    }

    // MARK: - Issue #164 — blank lines optional, no artificial item cap

    func testNativeRecordsParseIdenticallyWithAndWithoutBlankLines() throws {
        let records = [
            "acquisition\nThe acquisition closed\n这次收购完成了",
            "liquidity\nLiquidity matters\n流动性很重要\nWSJ",
            "sphere\nThe sphere rolled away\n球体滚走了",
        ]
        let spaced = try PhraseBatchParser.parse(records.joined(separator: "\n\n"))
        let dense = try PhraseBatchParser.parse(records.joined(separator: "\n"))

        XCTAssertEqual(spaced, dense)
        XCTAssertEqual(dense.map(\.spelling), ["acquisition", "liquidity", "sphere"])
        XCTAssertEqual(dense.map(\.source), [nil, "WSJ", nil])
    }

    func testLegacyLabelledRecordsRemainCompatibleWithAndWithoutBlankLines() throws {
        let records = [
            "## acquisition\nEN: The acquisition closed\nZH: 这次收购完成了\nSOURCE: WSJ",
            "## liquidity\nEN: Liquidity matters\nZH: 流动性很重要\nSOURCE: 课堂笔记",
        ]
        let spaced = try PhraseBatchParser.parse(records.joined(separator: "\n\n"))
        let dense = try PhraseBatchParser.parse(records.joined(separator: "\n"))

        XCTAssertEqual(spaced, dense)
        XCTAssertEqual(dense.map(\.source), ["WSJ", "课堂笔记"])
    }

    func testPhraseBatchesWellBeyondThirtyItemsParse() throws {
        let records = (0..<300).map {
            "word\($0)\nThe word\($0) appeared again\n第\($0)个词又出现了"
        }
        let entries = try PhraseBatchParser.parse(records.joined(separator: "\n\n"))

        XCTAssertEqual(entries.count, 300)
        XCTAssertEqual(entries.map(\.ordinal), Array(1...300))
        XCTAssertEqual(entries.last?.spelling, "word299")
        XCTAssertEqual(
            try PhraseBatchParser.parse(records.joined(separator: "\n")),
            entries
        )
    }

    /// The former recursive search was exponential once the item cap was gone.
    /// A fully ambiguous document must still reject, in linear work, at a size
    /// the old engine could never have finished.
    func testFullyAmbiguousLargeSegmentationRejectsWithoutCombinatorialSearch() {
        var validations = 0
        XCTAssertThrowsError(
            try PhraseBatchParser.uniqueSegmentation(lineCount: 6_000) { _ in
                validations += 1
                return true
            }
        )
        XCTAssertLessThanOrEqual(validations, 2 * 6_000)
    }

    func testUniqueSegmentationOfALargeDocumentStaysLinear() throws {
        var validations = 0
        let segments = try PhraseBatchParser.uniqueSegmentation(lineCount: 3_000) { range in
            validations += 1
            return range.count == 3 && range.lowerBound % 3 == 0
        }
        XCTAssertEqual(segments.count, 1_000)
        XCTAssertEqual(segments.first, 0..<3)
        XCTAssertEqual(segments.last, 2_997..<3_000)
        XCTAssertLessThanOrEqual(validations, 2 * 3_000)
    }

    func testTotalInputByteBoundStillFailsClosed() {
        let oversized = (0..<20_000).map {
            "word\($0)\nThe word\($0) appeared again\n第\($0)个词又出现了"
        }.joined(separator: "\n\n")
        XCTAssertGreaterThan(oversized.utf8.count, CompanionConstants.maxInputBytes)
        XCTAssertThrowsError(try PhraseBatchParser.parse(oversized))
    }
}
