import XCTest
@testable import MomoMoreEfficient

final class PhraseBatchParserTests: XCTestCase {
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
}
