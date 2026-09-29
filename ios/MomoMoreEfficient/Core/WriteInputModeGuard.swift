import Foundation
import OSLog

/// One high-confidence cross-mode input shape verdict (#180). Fixed reasons
/// only — never a semantic guess, never any content.
enum WriteInputModeSafetyIssue: Equatable, Sendable {
    /// Interpretation mode selected, but the document parses under the strict
    /// phrase grammar.
    case looksLikePhrase(reason: Reason)
    /// Phrase mode selected, but the document shows a high-confidence
    /// interpretation shape.
    case looksLikeInterpretation(reason: Reason)

    enum Reason: String, Equatable, Sendable {
        /// The strict PhraseBatchParser safely accepted the whole document.
        case strictPhraseShape = "strict_phrase_shape"
        /// The interpretation parser accepted a compact-POS document.
        case compactPOS = "compact_pos"
        /// The phrase parser could not safely parse the document while the
        /// interpretation parser could.
        case interpretationOnlyShape = "interpretation_only_shape"
    }

    /// The mode the Owner most likely wanted.
    var suggestedMode: ContentMode {
        switch self {
        case .looksLikePhrase: return .phrase
        case .looksLikeInterpretation: return .interpretation
        }
    }

    var reason: Reason {
        switch self {
        case let .looksLikePhrase(reason): return reason
        case let .looksLikeInterpretation(reason): return reason
        }
    }

    /// The frozen Owner-facing banner title for this verdict.
    var bannerTitle: String {
        switch self {
        case .looksLikePhrase:
            return "检测到例句格式，当前是释义录入。为防止写错，已阻止预览。"
        case .looksLikeInterpretation:
            return "检测到释义格式，当前是例句录入。为防止写错，已阻止预览。"
        }
    }

    /// The frozen one-tap action label; switching preserves the exact text.
    var switchActionTitle: String {
        switch suggestedMode {
        case .phrase: return "切换到例句并保留内容"
        case .interpretation: return "切换到释义并保留内容"
        }
    }
}

/// The #180 cross-mode write protection: one pure, local, deterministic
/// guard — not a classifier, not AI, no network. It compares the current
/// document against the two existing strict parsers and blocks only on the
/// high-confidence shapes the Owner's real wrong-mode incident motivates.
///
/// Selected interpretation: a document the strict phrase parser accepts is
/// high-confidence phrase-shaped input and blocks interpretation Preview.
///
/// Selected phrase: no weak semantic guessing. Two signals block — a
/// compact-POS interpretation document (the strong interpretation signature,
/// regardless of phrase-parser acceptance), or a non-compact document the
/// phrase parser cannot safely parse while the interpretation parser can
/// (the phrase path could not proceed safely anyway). When BOTH parsers
/// accept a non-compact document, the selected strict phrase path proceeds
/// unblocked: ambiguity alone never blocks.
enum WriteInputModeGuard {
    static func safetyIssue(
        document: String,
        selectedMode: ContentMode
    ) -> WriteInputModeSafetyIssue? {
        switch selectedMode {
        case .interpretation:
            if (try? PhraseBatchParser.parse(document)) != nil {
                return .looksLikePhrase(reason: .strictPhraseShape)
            }
            return nil
        case .phrase:
            guard let batch = try? BatchParser.parseDailyInput(document) else {
                return nil
            }
            if batch.inputFormat == .compactPOS {
                return .looksLikeInterpretation(reason: .compactPOS)
            }
            if (try? PhraseBatchParser.parse(document)) == nil {
                return .looksLikeInterpretation(reason: .interpretationOnlyShape)
            }
            return nil
        }
    }
}

/// The #180 guard's sanitized diagnostic surface (Owner standing rule):
/// visible banner + copyable plain text + one OSLog category. Only the
/// selected mode, the suggested mode and the fixed reason — never source
/// text, spellings, phrase or interpretation content, Token, account id,
/// raw requests or paths. No persistent storage: the guard is deterministic
/// and blocks locally, so a copied report plus the visible banner is the
/// whole trail.
enum WriteModeGuardDiagnostics {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.davidqyc.momoMoreEfficient",
        category: "write-mode-guard"
    )

    static func logBlocked(selected: ContentMode, issue: WriteInputModeSafetyIssue) {
        logger.log("\(report(selected: selected, issue: issue), privacy: .public)")
    }

    static func report(
        selected: ContentMode,
        issue: WriteInputModeSafetyIssue
    ) -> String {
        [
            "小黑鸟伴侣 Write Mode Guard Diagnostic v1",
            "selected=\(selected.diagnosticName)",
            "suggested=\(issue.suggestedMode.diagnosticName)",
            "reason=\(issue.reason.rawValue)",
        ].joined(separator: "\n")
    }
}

extension ContentMode {
    /// Stable, non-sensitive mode name for diagnostics.
    var diagnosticName: String {
        switch self {
        case .interpretation: return "interpretation"
        case .phrase: return "phrase"
        }
    }
}
