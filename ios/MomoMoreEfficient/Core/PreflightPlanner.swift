import Foundation

struct PreflightPlanner {
    let api: MaimemoTransport

    /// - Parameter status: the intended interpretation publication status.
    ///   Defaults to the legacy shared constant, so pre-#161 callers and the
    ///   default preference produce byte-identical snapshots. It participates in
    ///   classification, so a record differing only in status is an `更新`.
    func buildSnapshot(
        entries: [BatchEntry],
        tags: [String],
        status: String = CompanionConstants.status,
        credentialFingerprint: String,
        control: ExecutionControl? = nil,
        onEntryStarted: (@Sendable (_ entry: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PreviewSnapshot {
        guard !entries.isEmpty,
              (try? WriteTagPreference.canonicalized(tags)) == tags,
              InterpretationPublicationStatus.isDocumentedWriteStatus(status)
        else {
            throw CompanionError.inputRejected
        }

        // One shared batch resolution for the whole plan, before any per-item
        // content read. Outcomes stay aligned to this batch's own entry order.
        let resolution = try await VocabularyTargetResolver(api: api).resolve(
            spellings: entries.map(\.spelling),
            control: control
        )

        var planned: [PrivatePreflightItem] = []
        for (index, entry) in entries.enumerated() {
            // 1-based index of the entry about to be preflighted.
            onEntryStarted?(index + 1, entries.count)
            let outcome = resolution.outcomes[index]
            guard let vocabularyID = outcome.vocabularyID else {
                planned.append(
                    PrivatePreflightItem(
                        entry: entry,
                        classification: .blocked,
                        vocabularyID: nil,
                        baseline: nil,
                        reason: outcome.blockedReason
                    )
                )
                continue
            }
            do {
                let records = try await api.interpretations(
                    vocabularyID: vocabularyID,
                    control: control
                )
                if records.isEmpty {
                    planned.append(
                        PrivatePreflightItem(
                            entry: entry,
                            classification: .create,
                            vocabularyID: vocabularyID,
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
                                tags: tags,
                                status: status
                            )
                                ? .alreadyMatching
                                : .update,
                            vocabularyID: vocabularyID,
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
                tags: tags,
                status: status
            ),
            items: planned,
            presentation: presentation
        )
    }
}
