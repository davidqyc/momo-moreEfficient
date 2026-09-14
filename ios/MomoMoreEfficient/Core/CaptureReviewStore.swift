import Foundation

/// The accessibility identifiers physical- and simulator-device Capture
/// regression tests address the review surface by.
///
/// They are a validated external contract, not styling: `MomoMoreEfficientUITests`
/// looks each one up by literal string, so the #161 Capture redesign re-homes the
/// surface but must keep these values byte-identical. `RetrofitCharacterizationTests`
/// pins them.
enum CaptureAccessibilityIdentifier {
    static let status = "captureReviewStatus"
    static let textEditor = "captureReviewTextEditor"
    static let cancelButton = "cancelCaptureButton"
}

/// The source-agnostic in-app boundary for text that still needs human review.
///
/// This type deliberately owns no credential, transport, parser, Preview or write
/// dependency. App Intent capture uses it now; a later transport such as #124 can
/// hand non-secret text to the same boundary without inheriting App Intent code.
/// Captures are process-local: they survive foreground/background transitions
/// while the app remains alive, but a terminated process relaunches empty.
@MainActor
final class CaptureReviewStore: ObservableObject {
    struct Review: Equatable, Identifiable {
        let id: UInt64
        var text: String
        let sourceURL: URL?
        let sourceTitle: String?
        let capturedAt: Date
        let replacementCount: Int
        /// Whether the Owner has edited this capture in the review surface. It
        /// affects presentation only; the captured text is authoritative either
        /// way, and editing never leaves this review.
        var isEdited = false

        var replacedExistingReview: Bool { replacementCount > 0 }
    }

    static let shared = CaptureReviewStore()

    @Published private(set) var review: Review?
    private var nextID: UInt64 = 0

    init() {}

    /// Accepts the boundary value exactly as supplied. Parsing and any parser
    /// normalization remain in the existing explicit Preview action.
    @discardableResult
    func receive(
        _ text: String,
        sourceURL: URL? = nil,
        sourceTitle: String? = nil,
        capturedAt: Date = Date()
    ) -> Bool {
        let previousReview = review
        // CaptureReviewStore is the single ordering authority across transports.
        // Only a strictly newer capture replaces the current review; the existing
        // review deterministically wins an exact timestamp tie.
        guard previousReview.map({ capturedAt > $0.capturedAt }) ?? true else {
            return false
        }

        nextID += 1
        review = Review(
            id: nextID,
            text: text,
            sourceURL: sourceURL,
            sourceTitle: sourceTitle,
            capturedAt: capturedAt,
            replacementCount: previousReview.map { $0.replacementCount + 1 } ?? 0
        )
        return true
    }

    func edit(_ text: String) {
        guard var review else { return }
        guard text != review.text else { return }
        review.text = text
        review.isEdited = true
        self.review = review
    }

    func cancel() {
        review = nil
    }

    /// Consumes only capture-review text. It does not produce a Preview or any
    /// execution authority; the caller must explicitly place it in the editor.
    func takeReviewedText() -> String? {
        guard let text = review?.text else { return nil }
        review = nil
        return text
    }
}
