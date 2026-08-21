import Foundation

enum ShareCaptureDecision {
    case save(PendingCapture)
    case cancel
}

/// Maps the two extension buttons to their complete persistence effects.
/// The inbox closure is deliberately not evaluated for Cancel.
enum ShareCaptureActions {
    @discardableResult
    static func apply(
        _ decision: ShareCaptureDecision,
        inbox: () throws -> PendingCaptureInbox
    ) throws -> Bool {
        switch decision {
        case let .save(capture):
            try inbox().save(capture)
            return true
        case .cancel:
            return false
        }
    }
}
