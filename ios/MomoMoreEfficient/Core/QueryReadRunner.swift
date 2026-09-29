import Foundation

/// The already-returned objects one row's detail page renders.
///
/// Populated as each cell completes, from the very same response that produced
/// the count. Opening a detail therefore performs no new provider request.
struct QueryRowDetail: Equatable, Sendable {
    var interpretations: [InterpretationRecord] = []
    var phrases: [PhraseRecord] = []
    var notes: [NoteRecord] = []
}

/// One content cell's outcome: the cell truth plus whatever safe records
/// produced it.
struct QueryCellOutcome: Equatable, Sendable {
    let state: QueryCellState
    let detail: QueryRowDetail
}

/// The provider half of batch Query.
///
/// Deliberately thin: it resolves targets with the one shared #164 resolver and
/// reads one content family at a time through the existing authenticated
/// transport and shared #168 scheduler. It holds no state, makes no policy
/// decisions about stopping or resuming, and has no mutation route — every
/// sequencing decision belongs to `QuerySessionStore`.
struct QueryReadRunner {
    let api: MaimemoTransport

    /// The resolver stage, which is **atomic**: the shared resolver only returns
    /// after its whole requested resolution stage, so a run stopped part-way
    /// through it has no durable resolver truth and an explicit 继续查阅 simply
    /// runs this stage again.
    func resolve(
        spellings: [String],
        control: ExecutionControl
    ) async throws -> VocabularyResolution {
        try await VocabularyTargetResolver(api: api).resolve(
            spellings: spellings,
            control: control
        )
    }

    /// One atomic content cell read.
    ///
    /// Throws only for failures that stop the whole batch
    /// (`CompanionError.abortsReadPlan`) or a cancellation. Anything else is a
    /// per-cell inability, so the rest of the row stays truthful.
    func readCell(
        _ family: QueryContentFamily,
        vocabularyID: String,
        control: ExecutionControl
    ) async throws -> QueryCellOutcome {
        do {
            switch family {
            case .interpretation:
                let records = try await api.interpretations(
                    vocabularyID: vocabularyID,
                    control: control
                )
                return QueryCellOutcome(
                    state: QueryProjection.interpretationCell(records),
                    detail: QueryRowDetail(
                        interpretations: QueryProjection.activeInterpretations(records)
                    )
                )
            case .phrase:
                let records = try await api.phrases(
                    vocabularyID: vocabularyID,
                    control: control
                )
                return QueryCellOutcome(
                    state: QueryProjection.phraseCell(records),
                    detail: QueryRowDetail(phrases: QueryProjection.activePhrases(records))
                )
            case .note:
                let records = try await api.notes(
                    vocabularyID: vocabularyID,
                    control: control
                )
                return QueryCellOutcome(
                    state: QueryProjection.noteCell(records),
                    detail: QueryRowDetail(notes: QueryProjection.activeNotes(records))
                )
            }
        } catch let error as CompanionError {
            guard let cellState = QueryProjection.cellFailure(error) else { throw error }
            return QueryCellOutcome(state: cellState, detail: QueryRowDetail())
        }
    }
}
