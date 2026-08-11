import Foundation

struct PhraseBatchEntry: Equatable, Sendable {
    let ordinal: Int
    let spelling: String
    let normalizedSpelling: String
    let english: String
    let chinese: String
    let source: String
}

/// The intentionally narrow phrase/example grammar frozen by Issue #82.
///
/// Values are single-line and retained byte-for-byte after the required label
/// prefix. Blank lines are accepted only between complete blocks.
enum PhraseBatchParser {
    private static let fields = ["EN: ", "ZH: ", "SOURCE: "]

    static func parse(_ document: String) throws -> [PhraseBatchEntry] {
        guard document.utf8.count <= CompanionConstants.maxInputBytes else {
            throw CompanionError.inputRejected
        }

        let lines = normalizeNewlines(document).components(separatedBy: "\n")
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
                guard isValidSpelling(spelling) else { throw CompanionError.inputRejected }
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

    private static func isValidSpelling(_ spelling: String) -> Bool {
        !spelling.isEmpty
            && spelling == spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            && spelling.unicodeScalars.count <= 256
            && !containsDisallowedControlCharacter(spelling, allowingNewline: false)
    }

    private static func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
