import Foundation

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
        let replacementCount: Int

        var replacedExistingReview: Bool { replacementCount > 0 }
    }

    static let shared = CaptureReviewStore()

    @Published private(set) var review: Review?
    private var nextID: UInt64 = 0

    init() {}

    /// Accepts the boundary value exactly as supplied. Parsing and any parser
    /// normalization remain in the existing explicit Preview action.
    func receive(
        _ text: String,
        sourceURL: URL? = nil,
        sourceTitle: String? = nil
    ) {
        nextID += 1
        review = Review(
            id: nextID,
            text: text,
            sourceURL: sourceURL,
            sourceTitle: sourceTitle,
            replacementCount: review.map { $0.replacementCount + 1 } ?? 0
        )
    }

    func edit(_ text: String) {
        guard var review else { return }
        review.text = text
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
