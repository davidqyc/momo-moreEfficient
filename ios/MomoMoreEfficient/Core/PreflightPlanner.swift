import Foundation

struct PreflightPlanner {
    let api: MaimemoTransport

    func buildSnapshot(
        entries: [BatchEntry],
        credentialFingerprint: String,
        control: ExecutionControl? = nil
    ) async throws -> PreviewSnapshot {
        guard !entries.isEmpty, entries.count <= CompanionConstants.maxBatchItems else {
            throw CompanionError.inputRejected
        }

        var planned: [PrivatePreflightItem] = []
        for entry in entries {
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
                            classification: baseline.matchesIntendedState(entry.interpretation)
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

        let rows = planned.map(\.publicRow)
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
            bindingContext: try ConfirmationBinding.makePreviewBindingContext(items: planned),
            items: planned,
            presentation: presentation
        )
    }
}
