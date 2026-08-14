import Foundation

struct PreflightPlanner {
    let api: MaimemoTransport

    func buildSnapshot(
        entries: [BatchEntry],
        tags: [String],
        credentialFingerprint: String,
        control: ExecutionControl? = nil,
        onEntryStarted: (@Sendable (_ entry: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PreviewSnapshot {
        guard !entries.isEmpty,
              entries.count <= CompanionConstants.maxBatchItems,
              (try? WriteTagPreference.canonicalized(tags)) == tags
        else {
            throw CompanionError.inputRejected
        }

        var planned: [PrivatePreflightItem] = []
        for (index, entry) in entries.enumerated() {
            // 1-based index of the entry about to be preflighted.
            onEntryStarted?(index + 1, entries.count)
            do {
                let vocabulary = try await api.vocabulary(
                    spelling: entry.spelling,
                    control: control
                )
                let records = try await api.interpretations(
                    vocabularyID: vocabulary.id,
                    control: control
                )
                if records.isEmpty {
                    planned.append(
                        PrivatePreflightItem(
                            entry: entry,
                            classification: .create,
                            vocabularyID: vocabulary.id,
                            baseline: nil,
                            reason: nil
                        )
                    )
                } else if records.count == 1 {
                    let baseline = records[0]
                    planned.append(
                        PrivatePreflightItem(
                            entry: entry,
                            classification: baseline.matchesIntendedState(
                                entry.interpretation,
                                tags: tags
                            )
                                ? .alreadyMatching
                                : .update,
                            vocabularyID: vocabulary.id,
                            baseline: baseline,
                            reason: nil
                        )
                    )
                } else {
                    planned.append(
                        PrivatePreflightItem(
                            entry: entry,
                            classification: .blocked,
                            vocabularyID: nil,
                            baseline: nil,
                            reason: "AMBIGUOUS"
                        )
                    )
                }
            } catch CompanionError.cancelled {
                throw CompanionError.cancelled
            } catch let error as CompanionError where error.abortsReadPlan {
                throw error
            } catch {
                planned.append(
                    PrivatePreflightItem(
                        entry: entry,
                        classification: .blocked,
                        vocabularyID: nil,
                        baseline: nil,
                        reason: "READ_FAILED"
                    )
                )
            }
        }

        let rows = planned.map { $0.publicRow(tags: tags) }
        let presentation = PreviewPresentation(
            rows: rows,
            counts: PreviewCounts(
                create: rows.filter { $0.classification == .create }.count,
                update: rows.filter { $0.classification == .update }.count,
                alreadyMatching: rows.filter { $0.classification == .alreadyMatching }.count,
                blocked: rows.filter { $0.classification == .blocked }.count
            )
        )
        return PreviewSnapshot(
            sourceIdentity: try ConfirmationBinding.sourceIdentity(entries),
            credentialFingerprint: credentialFingerprint,
            accountMode: CompanionConstants.accountMode,
            bindingContext: try ConfirmationBinding.makePreviewBindingContext(
                items: planned,
                tags: tags
            ),
            items: planned,
            presentation: presentation
        )
    }
}
