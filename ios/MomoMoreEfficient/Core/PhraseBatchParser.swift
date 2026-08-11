import Foundation

struct PhraseBatchEntry: Equatable, Sendable {
    let ordinal: Int
    let spelling: String
    let normalizedSpelling: String
    let english: String
    let chinese: String
    let source: String?
}

enum PhraseBatchParser {
    private static let fields = ["EN: ", "ZH: ", "SOURCE: "]

    static func parse(_ document: String) throws -> [PhraseBatchEntry] {
        guard document.utf8.count <= CompanionConstants.maxInputBytes else {
            throw CompanionError.inputRejected
        }

        let normalized = normalizeNewlines(document)
        let lines = normalized.components(separatedBy: "\n")
        let hasLegacySyntax = lines.contains { line in
            line.hasPrefix("## ")
                || fields.contains(where: line.hasPrefix)
        }
        return try hasLegacySyntax ? parseLegacy(lines) : parseNative(lines)
    }

    /// The original strict Issue #82 grammar. It remains intentionally exact:
    /// all three labels, including SOURCE, are still required in this form.
    private static func parseLegacy(_ lines: [String]) throws -> [PhraseBatchEntry] {
        var blocks: [(spelling: String, values: [String])] = []
        var currentSpelling: String?
        var currentValues: [String] = []
        var sawSeparatorAfterCompleteBlock = false

        func finishCurrent() throws {
            guard let spelling = currentSpelling else { return }
            guard currentValues.count == fields.count else {
                throw CompanionError.inputRejected
            }
            blocks.append((spelling, currentValues))
            guard blocks.count <= CompanionConstants.maxBatchItems else {
                throw CompanionError.inputRejected
            }
            currentSpelling = nil
            currentValues = []
            sawSeparatorAfterCompleteBlock = false
        }

        for line in lines {
            if line.isEmpty {
                if currentSpelling == nil { continue }
                guard currentValues.count == fields.count else {
                    throw CompanionError.inputRejected
                }
                sawSeparatorAfterCompleteBlock = true
                continue
            }

            if line.hasPrefix("#") {
                guard line.hasPrefix("## ") else { throw CompanionError.inputRejected }
                try finishCurrent()
                let spelling = String(line.dropFirst(3))
                guard isValidLegacySpelling(spelling) else {
                    throw CompanionError.inputRejected
                }
                currentSpelling = spelling
                continue
            }

            guard currentSpelling != nil,
                  !sawSeparatorAfterCompleteBlock,
                  currentValues.count < fields.count
            else {
                throw CompanionError.inputRejected
            }
            let expectedPrefix = fields[currentValues.count]
            guard line.hasPrefix(expectedPrefix) else { throw CompanionError.inputRejected }
            let value = String(line.dropFirst(expectedPrefix.count))
            try validateValue(value, maximumCharacters: maximumCharacters(for: expectedPrefix))
            currentValues.append(value)
        }

        try finishCurrent()
        guard !blocks.isEmpty else { throw CompanionError.inputRejected }

        var normalizedSpellings = Set<String>()
        return try blocks.enumerated().map { index, block in
            let normalized = BatchParser.normalizeSpelling(block.spelling)
            guard normalizedSpellings.insert(normalized).inserted else {
                throw CompanionError.inputRejected
            }
            return PhraseBatchEntry(
                ordinal: index + 1,
                spelling: block.spelling,
                normalizedSpelling: normalized,
                english: block.values[0],
                chinese: block.values[1],
                source: block.values[2]
            )
        }
    }

    /// Native human/AI paste format. Blank lines are structural whitespace; all
    /// remaining lines are retained exactly and the whole document must have one
    /// and only one valid 3/4-line segmentation.
    private static func parseNative(_ lines: [String]) throws -> [PhraseBatchEntry] {
        let logicalLines = lines.filter {
            !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        guard logicalLines.count >= 3,
              logicalLines.count <= CompanionConstants.maxBatchItems * 4
        else {
            throw CompanionError.inputRejected
        }

        let segments = try uniqueSegmentation(lineCount: logicalLines.count) { range in
            isValidNativeRecord(Array(logicalLines[range]))
        }
        guard !segments.isEmpty, segments.count <= CompanionConstants.maxBatchItems else {
            throw CompanionError.inputRejected
        }

        var normalizedSpellings = Set<String>()
        return try segments.enumerated().map { index, range in
            let values = Array(logicalLines[range])
            let spelling = values[0]
            let normalized = BatchParser.normalizeSpelling(spelling)
            guard normalizedSpellings.insert(normalized).inserted else {
                throw CompanionError.inputRejected
            }
            return PhraseBatchEntry(
                ordinal: index + 1,
                spelling: spelling,
                normalizedSpelling: normalized,
                english: values[1],
                chinese: values[2],
                source: values.count == 4 ? values[3] : nil
            )
        }
    }

    /// The exact segmentation engine used by native parsing. The closure keeps
    /// record validation local while making the ambiguity fail-closed branch
    /// directly testable even though the current Han/no-Han grammar is strongly
    /// self-synchronizing for ordinary input.
    static func uniqueSegmentation(
        lineCount: Int,
        isValidRecord: (Range<Int>) -> Bool
    ) throws -> [Range<Int>] {
        var solutions: [[Range<Int>]] = []

        func search(from index: Int, segments: [Range<Int>]) {
            guard solutions.count < 2, segments.count <= CompanionConstants.maxBatchItems else {
                return
            }
            if index == lineCount {
                solutions.append(segments)
                return
            }
            guard segments.count < CompanionConstants.maxBatchItems else { return }
            for length in [3, 4] where index + length <= lineCount {
                let range = index..<(index + length)
                guard isValidRecord(range) else { continue }
                search(from: range.upperBound, segments: segments + [range])
            }
        }

        search(from: 0, segments: [])
        guard solutions.count == 1, let result = solutions.first else {
            throw CompanionError.inputRejected
        }
        return result
    }

    private static func isValidNativeRecord(_ values: [String]) -> Bool {
        guard values.count == 3 || values.count == 4 else { return false }
        return isValidNativeSpelling(values[0])
            && isValidEnglish(values[1])
            && isValidChinese(values[2])
            && (values.count == 3 || isValidSource(values[3]))
    }

    private static func maximumCharacters(for prefix: String) -> Int {
        prefix == "SOURCE: " ? 256 : CompanionConstants.maxInterpretationCharacters
    }

    private static func validateValue(_ value: String, maximumCharacters: Int) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= maximumCharacters,
              !containsDisallowedControlCharacter(value, allowingNewline: false)
        else {
            throw CompanionError.inputRejected
        }
    }

    private static func isValidLegacySpelling(_ spelling: String) -> Bool {
        !spelling.isEmpty
            && spelling == spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            && spelling.unicodeScalars.count <= 256
            && !containsDisallowedControlCharacter(spelling, allowingNewline: false)
    }

    private static func isValidNativeSpelling(_ spelling: String) -> Bool {
        isValidLegacySpelling(spelling) && !containsHan(spelling)
    }

    private static func isValidEnglish(_ value: String) -> Bool {
        isSafeNonemptyLine(value, maximumCharacters: CompanionConstants.maxInterpretationCharacters)
            && value.unicodeScalars.contains(where: isLatin)
            && !containsHan(value)
    }

    private static func isValidChinese(_ value: String) -> Bool {
        isSafeNonemptyLine(value, maximumCharacters: CompanionConstants.maxInterpretationCharacters)
            && containsHan(value)
    }

    private static func isValidSource(_ value: String) -> Bool {
        isSafeNonemptyLine(value, maximumCharacters: 256)
    }

    private static func isSafeNonemptyLine(_ value: String, maximumCharacters: Int) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && value.unicodeScalars.count <= maximumCharacters
            && !containsDisallowedControlCharacter(value, allowingNewline: false)
    }

    private static func containsHan(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF,
                 0x20000...0x2FA1F, 0x30000...0x323AF:
                return true
            default:
                return false
            }
        }
    }

    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF:
            return true
        default:
            return false
        }
    }

    private static func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
