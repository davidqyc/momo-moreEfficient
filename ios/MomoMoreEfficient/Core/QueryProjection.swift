import Foundation

/// Turns fully decoded provider records into Query's count truth.
///
/// This exists as a **pure projection over whole record collections**
/// specifically so the shared transport never has to pre-filter anything for
/// Query's convenience (adjudication finding 7). `MaimemoTransport` keeps
/// returning every safely decoded record — including `DELETED` ones — because
/// the write planner, the classification logic and the authenticated readback
/// all depend on seeing them. Deciding what *counts* is Query's own business and
/// lives here.
///
/// The counting contract, from Issue #161:
///
/// ```text
/// interpretation  PUBLISHED + UNPUBLISHED count · DELETED excluded
/// phrase          PUBLISHED counts · DELETED excluded
/// note            PUBLISHED counts · DELETED excluded
/// unknown/unsafe  UNAVAILABLE — never 0
/// ```
enum QueryProjection {

    /// 释义. Both documented publication states are real content the Owner has;
    /// only `DELETED` is excluded.
    static func interpretationCell(_ records: [InterpretationRecord]) -> QueryCellState {
        // Defence in depth: the transport decoder already rejects an
        // undocumented status, so this can only fire if that contract ever
        // loosens. It must fail closed rather than undercount.
        guard records.allSatisfy({
            InterpretationPublicationStatus.isDocumentedWriteStatus($0.status)
                || $0.status == "DELETED"
        }) else {
            return .unavailable(.responseNotSafelyReadable)
        }
        return .count(records.count { $0.status != "DELETED" })
    }

    /// 例句. The provider exposes no unpublished phrase state, so `PUBLISHED` is
    /// the whole active set.
    static func phraseCell(_ records: [PhraseRecord]) -> QueryCellState {
        guard records.allSatisfy({
            $0.status == CompanionConstants.status || $0.status == "DELETED"
        }) else {
            return .unavailable(.responseNotSafelyReadable)
        }
        return .count(records.count { $0.status == CompanionConstants.status })
    }

    /// 助记. `NOTE_STATUS_UNSPECIFIED` is documented but carries no safe
    /// counting meaning, so a collection containing one is unavailable rather
    /// than silently reported as a smaller number.
    static func noteCell(_ records: [NoteRecord]) -> QueryCellState {
        guard records.allSatisfy({ !$0.hasUnsafeStatusForCounting }) else {
            return .unavailable(.responseNotSafelyReadable)
        }
        return .count(records.count(where: \.isActive))
    }

    /// The active records a detail page lists for a family, in returned order.
    static func activeInterpretations(
        _ records: [InterpretationRecord]
    ) -> [InterpretationRecord] {
        records.filter { $0.status != "DELETED" }
    }

    static func activePhrases(_ records: [PhraseRecord]) -> [PhraseRecord] {
        records.filter { $0.status == CompanionConstants.status }
    }

    static func activeNotes(_ records: [NoteRecord]) -> [NoteRecord] {
        records.filter(\.isActive)
    }

    /// Maps a read failure to the one cell it belongs to.
    ///
    /// A batch-level failure (`abortsReadPlan`) is deliberately *not* handled
    /// here: it stops the whole run and leaves unfinished cells `未读`, which is
    /// the runner's decision, not a per-cell inability.
    static func cellFailure(_ error: CompanionError) -> QueryCellState? {
        guard !error.abortsReadPlan, error != .cancelled else { return nil }
        return .unavailable(.responseNotSafelyReadable)
    }
}
