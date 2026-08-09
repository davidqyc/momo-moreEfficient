import Foundation

struct AdaptedBatch: Equatable, Sendable {
    enum InputFormat: String, Equatable, Sendable {
        case canonicalMarkdown
        case compactPOS
        case blankDelimited
    }

    let entries: [BatchEntry]
    let canonicalText: String
    let inputFormat: InputFormat
}

enum BatchParser {
    static let posMarkers = [
        "n.", "v.", "adj.", "adv.", "phr.", "prep.",
        "conj.", "pron.", "det.", "num.", "interj.",
    ]

    static func parseDailyInput(_ document: String) throws -> AdaptedBatch {
        guard document.utf8.count <= CompanionConstants.maxInputBytes else {
            throw CompanionError.inputRejected
        }
        let normalized = normalizeNewlines(document)
        let lines = normalized.components(separatedBy: "\n")

        if lines.contains(where: { trimTrailingWhitespace($0).hasPrefix("#") }) {
            return AdaptedBatch(
                entries: try parseCanonical(document),
                canonicalText: document,
                inputFormat: .canonicalMarkdown
            )
        }

        let blocks = nonEmptyBlocks(lines)
        guard !blocks.isEmpty, blocks.allSatisfy({ $0.count >= 2 }) else {
            throw CompanionError.inputRejected
        }

        var items: [[String]] = []
        var usedCompactGrammar = false
        for block in blocks {
            if posMarker(for: block[1]) != nil {
                usedCompactGrammar = true
                items.append(contentsOf: try compactItems(block))
            } else if blocks.count > 1 {
                items.append(block)
            } else {
                throw CompanionError.inputRejected
            }
        }

        let canonical = items.map { item in
            "## \(item[0])\n" + item.dropFirst().joined(separator: "\n")
        }.joined(separator: "\n\n")
        return AdaptedBatch(
            entries: try parseCanonical(canonical),
            canonicalText: canonical,
            inputFormat: usedCompactGrammar ? .compactPOS : .blankDelimited
        )
    }

    static func parseCanonical(_ document: String) throws -> [BatchEntry] {
        guard document.utf8.count <= CompanionConstants.maxInputBytes else {
            throw CompanionError.inputRejected
        }
        let lines = normalizeNewlines(document).components(separatedBy: "\n")
        var headings: [(spelling: String, body: [String])] = []

        for rawLine in lines {
            let headingLine = trimTrailingWhitespace(rawLine)
            if headingLine.hasPrefix("#") {
                guard headingLine.hasPrefix("## ") else {
                    throw CompanionError.inputRejected
                }
                let spelling = String(headingLine.dropFirst(3))
                guard let first = spelling.unicodeScalars.first,
                      !CharacterSet.whitespacesAndNewlines.contains(first),
                      isValidSpelling(spelling)
                else {
                    throw CompanionError.inputRejected
                }
                headings.append((spelling, []))
                guard headings.count <= CompanionConstants.maxBatchItems else {
                    throw CompanionError.inputRejected
                }
                continue
            }

            guard !headings.isEmpty else {
                if !rawLine.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    throw CompanionError.inputRejected
                }
                continue
            }
            headings[headings.count - 1].body.append(rawLine)
        }

        guard !headings.isEmpty else { throw CompanionError.inputRejected }
        var normalizedSpellings = Set<String>()
        var entries: [BatchEntry] = []

        for (index, heading) in headings.enumerated() {
            var body = heading.body
            while body.first?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                body.removeFirst()
            }
            while body.last?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true {
                body.removeLast()
            }
            let interpretation = body.joined(separator: "\n")
            try validateInterpretation(interpretation)
            let normalized = normalizeSpelling(heading.spelling)
            guard normalizedSpellings.insert(normalized).inserted else {
                throw CompanionError.inputRejected
            }
            entries.append(
                BatchEntry(
                    ordinal: index + 1,
                    spelling: heading.spelling,
                    normalizedSpelling: normalized,
                    interpretation: interpretation
                )
            )
        }
        return entries
    }

    private static func compactItems(_ block: [String]) throws -> [[String]] {
        guard block.count >= 2, posMarker(for: block[0]) == nil else {
            throw CompanionError.inputRejected
        }
        var items: [[String]] = []
        var spelling = block[0]
        var definitions: [String] = []

        for line in block.dropFirst() {
            if posMarker(for: line) != nil {
                definitions.append(line)
            } else {
                guard !definitions.isEmpty else { throw CompanionError.inputRejected }
                items.append([spelling] + definitions)
                spelling = line
                definitions = []
            }
        }
        guard !definitions.isEmpty else { throw CompanionError.inputRejected }
        items.append([spelling] + definitions)
        return items
    }

    private static func posMarker(for line: String) -> String? {
        posMarkers.first { marker in
            line.hasPrefix(marker)
                && !line.dropFirst(marker.count)
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    private static func nonEmptyBlocks(_ lines: [String]) -> [[String]] {
        var blocks: [[String]] = []
        var current: [String] = []
        for line in lines {
            if line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                if !current.isEmpty {
                    blocks.append(current)
                    current = []
                }
            } else {
                current.append(line)
            }
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }

    private static func isValidSpelling(_ spelling: String) -> Bool {
        !spelling.isEmpty
            && spelling == spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            && spelling.unicodeScalars.count <= 256
            && !containsDisallowedControlCharacter(spelling, allowingNewline: false)
    }

    private static func validateInterpretation(_ interpretation: String) throws {
        guard !interpretation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              interpretation.unicodeScalars.count <= CompanionConstants.maxInterpretationCharacters,
              !containsDisallowedControlCharacter(interpretation, allowingNewline: true)
        else {
            throw CompanionError.inputRejected
        }
    }

    static func normalizeSpelling(_ spelling: String) -> String {
        spelling.precomposedStringWithCompatibilityMapping.folding(
            options: [.caseInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
    }

    private static func normalizeNewlines(_ value: String) -> String {
        value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func trimTrailingWhitespace(_ value: String) -> String {
        var result = value
        while let scalar = result.unicodeScalars.last,
              CharacterSet.whitespacesAndNewlines.contains(scalar) {
            result.unicodeScalars.removeLast()
        }
        return result
    }
}
