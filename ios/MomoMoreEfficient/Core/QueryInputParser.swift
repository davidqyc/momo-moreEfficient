import Foundation

/// One visible Query input row, in the order the Owner typed it.
///
/// `ordinal` is the display identity and never collapses: two rows naming the
/// same word both stay visible. `normalized` is the *network* identity, so the
/// resolver and the content reads happen once per distinct word.
struct QueryInput: Equatable, Identifiable, Sendable {
    let ordinal: Int
    let spelling: String
    let normalized: String

    var id: Int { ordinal }
}

/// The parse of one Query input document.
struct QueryInputParse: Equatable, Sendable {
    /// Visible rows, in input order, duplicates preserved.
    let inputs: [QueryInput]
    /// Distinct normalized spellings in first-appearance order — the exact set
    /// of items any network work is planned against.
    let uniqueSpellings: [String]

    var isEmpty: Bool { inputs.isEmpty }
    var visibleCount: Int { inputs.count }
    var uniqueCount: Int { uniqueSpellings.count }

    static let empty = QueryInputParse(inputs: [], uniqueSpellings: [])
}

/// Query input parsing, v1 (#161).
///
/// Deliberately narrow and deterministic:
///
/// - newline is the recommended batch separator; `,` and `，` are the two
///   supported convenience separators;
/// - `;` / `；` are **not** separators in v1 (frozen decision), so a semicolon
///   stays inside the word it was typed in;
/// - an ordinary space, `-` and `/` are never split on, because every one of
///   them occurs inside legitimate expressions
///   (`take into account`, `well-known`, `and/or`);
/// - there is no fuzzy spelling repair of any kind.
///
/// The whole document fails closed rather than silently dropping an unsafe
/// token: an oversized or control-character-bearing entry cannot be safely
/// resolved, and quietly discarding it would understate the batch.
enum QueryInputParser {
    /// Only these three. Adding one is a product decision, not a tweak.
    static let separators: Set<Character> = ["\n", ",", "，"]
    static let maximumSpellingScalars = 256

    static func parse(_ document: String) throws -> QueryInputParse {
        guard document.utf8.count <= CompanionConstants.maxInputBytes else {
            throw CompanionError.inputRejected
        }
        let normalizedNewlines = document
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let tokens = normalizedNewlines
            .split(whereSeparator: { separators.contains($0) })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        guard !tokens.isEmpty else { throw CompanionError.inputRejected }

        var inputs: [QueryInput] = []
        var uniqueSpellings: [String] = []
        var seen = Set<String>()

        for (index, token) in tokens.enumerated() {
            guard isSafeSpelling(token) else { throw CompanionError.inputRejected }
            let normalized = BatchParser.normalizeSpelling(token)
            inputs.append(
                QueryInput(ordinal: index + 1, spelling: token, normalized: normalized)
            )
            if seen.insert(normalized).inserted {
                uniqueSpellings.append(token)
            }
        }

        return QueryInputParse(inputs: inputs, uniqueSpellings: uniqueSpellings)
    }

    /// A best-effort parse for live editor feedback: `nil` means the current
    /// text is not something this parser can safely act on.
    static func parseForDisplay(_ document: String) -> QueryInputParse? {
        guard !document.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return QueryInputParse.empty
        }
        return try? parse(document)
    }

    private static func isSafeSpelling(_ spelling: String) -> Bool {
        !spelling.isEmpty
            && spelling.unicodeScalars.count <= maximumSpellingScalars
            && !containsDisallowedControlCharacter(spelling, allowingNewline: false)
    }
}
