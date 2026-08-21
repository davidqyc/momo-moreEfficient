import Foundation

final class ExecutionControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellationRequested = false
    private var postInFlight = false

    func requestCancellation() {
        lock.lock()
        cancellationRequested = true
        lock.unlock()
    }

    func allowsPreflightRequest() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cancellationRequested && !postInFlight
    }

    func beginPostIfAllowed() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancellationRequested, !postInFlight else { return false }
        postInFlight = true
        return true
    }

    func allowsInFlightReadback() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return postInFlight
    }

    func finishPostResolution() {
        lock.lock()
        postInFlight = false
        lock.unlock()
    }

    var isCancellationRequested: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancellationRequested
    }
}
struct WriteExecutor {
    let api: MaimemoTransport

    func execute(
        group: OperationGroup,
        displayedSnapshot: PreviewSnapshot,
        approval: NativeApproval,
        control: ExecutionControl,
        progress: ExecutionProgressReporter? = nil
    ) async -> ExecutionSummary {
        do {
            let expectedApproval = try ConfirmationBinding.makeApproval(
                snapshot: displayedSnapshot,
                group: group
            )
            guard approval == expectedApproval else {
                return .stale(group)
            }

            progress?.report(.securing)
            let entries = displayedSnapshot.items.map(\.entry)
            let fresh = try await PreflightPlanner(api: api).buildSnapshot(
                entries: entries,
                tags: displayedSnapshot.bindingContext.tags,
                credentialFingerprint: displayedSnapshot.credentialFingerprint,
                control: control
            )
            guard fresh == displayedSnapshot,
                  try ConfirmationBinding.snapshotIdentity(fresh) == approval.snapshotIdentity
            else {
                return .stale(group)
            }
            let freshPlan = try ConfirmationBinding.makePlan(snapshot: fresh, group: group)
            guard freshPlan.bindingDigest == approval.bindingDigest else {
                return .stale(group)
            }
            return await perform(plan: freshPlan, control: control, progress: progress)
        } catch CompanionError.cancelled {
            return ExecutionSummary(
                group: group,
                succeeded: 0,
                failed: 0,
                cancelled: true,
                stalePreview: false,
                results: []
            )
        } catch let error as CompanionError where error.abortsReadPlan {
            return .globalFailure(group, error)
        } catch {
            return ExecutionSummary(
                group: group,
                succeeded: 0,
                failed: 1,
                cancelled: false,
                stalePreview: false,
                results: []
            )
        }
    }

    /// One Owner-authorized run over the whole displayed plan (#76).
    ///
    /// Deterministic phase order — CREATE, then UPDATE — with the existing safety
    /// unchanged inside each phase: max one POST per item, no POST retry, an
    /// immediate authenticated readback, GET-only recovery for an uncertain POST,
    /// and a stop on the first failure.
    ///
    /// The whole-batch execution-time preflight below is deliberately *not* fused
    /// into the per-item loop. Proving that every approved item still matches
    /// before the first POST is what keeps a late change from being discovered
    /// only after earlier items were already written.
    func executeBatchPlan(
        displayedSnapshot: PreviewSnapshot,
        approval: BatchPlanApproval,
        control: ExecutionControl,
        progress: ExecutionProgressReporter? = nil
    ) async -> BatchRunResult {
        guard let firstGroup = approval.phases.first?.group else { return .stale }

        let fresh: PreviewSnapshot
        do {
            guard approval == (try ConfirmationBinding.makeBatchApproval(snapshot: displayedSnapshot))
            else {
                return .stale
            }

            // Compact by design: the Owner sees one `安全确认中…` stage, never a
            // second apparent 1/N pass, while every item is still re-read.
            progress?.report(.securing)
            fresh = try await PreflightPlanner(api: api).buildSnapshot(
                entries: displayedSnapshot.items.map(\.entry),
                tags: displayedSnapshot.bindingContext.tags,
                credentialFingerprint: displayedSnapshot.credentialFingerprint,
                control: control
            )
            guard fresh == displayedSnapshot,
                  try ConfirmationBinding.snapshotIdentity(fresh) == approval.snapshotIdentity,
                  try ConfirmationBinding.makeBatchApproval(snapshot: fresh) == approval
            else {
                return .stale
            }
        } catch CompanionError.cancelled {
            // Interrupted before the whole-batch gate could pass. Nothing written.
            return BatchRunResult(
                outcome: .stoppedBeforeRemainingPhase(group: firstGroup, reason: .interrupted),
                phases: []
            )
        } catch let error as CompanionError where error.abortsReadPlan {
            return BatchRunResult(outcome: .globalFailure(error), phases: [])
        } catch {
            return .stale
        }

        var summaries: [ExecutionSummary] = []
        for (index, phase) in approval.phases.enumerated() {
            let plan: ConfirmationPlan
            if index == 0 {
                guard let first = firstPhasePlan(phase, in: fresh) else { return .stale }
                plan = first
            } else {
                // A later phase never inherits the earlier approval. It gets its
                // own fresh authenticated preflight, validated against its own
                // portion of the original whole-plan authorization.
                progress?.report(.securing)
                do {
                    guard let revalidated = try await revalidatedPlan(
                        phase,
                        displayedSnapshot: displayedSnapshot,
                        control: control
                    ) else {
                        return BatchRunResult(
                            outcome: .stoppedBeforeRemainingPhase(
                                group: phase.group,
                                reason: control.isCancellationRequested
                                    ? .interrupted
                                    : .remainingPhaseChanged
                            ),
                            phases: summaries
                        )
                    }
                    plan = revalidated
                } catch let error as CompanionError where error.abortsReadPlan {
                    return BatchRunResult(outcome: .globalFailure(error), phases: summaries)
                } catch {
                    return BatchRunResult(
                        outcome: .stoppedBeforeRemainingPhase(
                            group: phase.group,
                            reason: control.isCancellationRequested
                                ? .interrupted
                                : .remainingPhaseChanged
                        ),
                        phases: summaries
                    )
                }
            }

            let summary = await perform(plan: plan, control: control, progress: progress)
            summaries.append(summary)

            if let terminalError = summary.terminalError {
                return BatchRunResult(
                    outcome: .globalFailure(terminalError),
                    phases: summaries
                )
            }

            guard summary.isFullSuccess else {
                let remaining = approval.phases.dropFirst(index + 1).first
                guard let remaining else { break }
                return BatchRunResult(
                    outcome: .stoppedBeforeRemainingPhase(
                        group: remaining.group,
                        reason: .earlierPhaseIncomplete
                    ),
                    phases: summaries
                )
            }
        }
        return BatchRunResult(outcome: .completed, phases: summaries)
    }

    private func firstPhasePlan(
        _ phase: BatchPlanApproval.Phase,
        in fresh: PreviewSnapshot
    ) -> ConfirmationPlan? {
        guard let plan = try? ConfirmationBinding.makePlan(snapshot: fresh, group: phase.group),
              matches(plan, phase, credentialFingerprint: fresh.credentialFingerprint)
        else {
            return nil
        }
        return plan
    }

    /// Fresh authenticated GET-only preflight of the remaining subset, admitted
    /// only when it reproduces this phase's approved binding exactly.
    ///
    /// Anything else — a changed baseline, a new interpretation, an ambiguous
    /// vocabulary, a read failure, an interruption — returns `nil` and stops the
    /// run before a single POST of this phase.
    private func revalidatedPlan(
        _ phase: BatchPlanApproval.Phase,
        displayedSnapshot: PreviewSnapshot,
        control: ExecutionControl
    ) async throws -> ConfirmationPlan? {
        let entries = displayedSnapshot.items(for: phase.group).map(\.entry)
        guard !entries.isEmpty else { return nil }
        let fresh = try await PreflightPlanner(api: api).buildSnapshot(
            entries: entries,
            tags: displayedSnapshot.bindingContext.tags,
            credentialFingerprint: displayedSnapshot.credentialFingerprint,
            control: control
        )
        guard let plan = try? ConfirmationBinding.makePlan(
            snapshot: fresh,
            group: phase.group
        ), matches(plan, phase, credentialFingerprint: fresh.credentialFingerprint) else {
            return nil
        }
        return plan
    }

    private func matches(
        _ plan: ConfirmationPlan,
        _ phase: BatchPlanApproval.Phase,
        credentialFingerprint: String
    ) -> Bool {
        plan.group == phase.group
            && plan.items.count == phase.itemCount
            && plan.batchDigest == phase.batchDigest
            && plan.bindingDigest == phase.bindingDigest
            && plan.credentialFingerprint == credentialFingerprint
    }

    private func perform(
        plan: ConfirmationPlan,
        control: ExecutionControl,
        progress: ExecutionProgressReporter?
    ) async -> ExecutionSummary {
        var results: [ItemExecutionResult] = []
        var succeeded = 0
        var failed = 0
        var terminalError: CompanionError?

        defer { progress?.report(.finishing(group: plan.group)) }

        for (index, item) in plan.items.enumerated() {
            if control.isCancellationRequested {
                results.append(ItemExecutionResult(spelling: item.spelling, outcome: .notAttempted))
                break
            }
            progress?.report(
                .writing(
                    group: plan.group,
                    item: index + 1,
                    total: plan.items.count,
                    spelling: item.spelling
                )
            )
            do {
                let route: InterpretationRoute
                switch plan.group {
                case .create:
                    route = .createInterpretation
                case .update:
                    guard let recordID = item.baseline?.id else {
                        throw CompanionError.blocked
                    }
                    route = .updateInterpretation(recordID: recordID)
                }
                let body = try ConfirmationBinding.requestData(
                    item,
                    group: plan.group,
                    tags: plan.tags
                )
                let dispatch = await api.post(route: route, body: body, control: control)
                guard dispatch != .notDispatched else {
                    results.append(
                        ItemExecutionResult(
                            spelling: item.spelling,
                            outcome: .notAttempted,
                            diagnostic: WriteAttemptDiagnostic(
                                ordinal: item.ordinal,
                                postDispatch: .notDispatched,
                                readbackAttempts: [],
                                terminalErrorCategory: nil
                            )
                        )
                    )
                    break
                }

                let records: [InterpretationRecord]
                do {
                    records = try await api.interpretations(
                        vocabularyID: item.vocabularyID,
                        control: control,
                        readback: true
                    )
                } catch let error as CompanionError where error == .authenticationRejected {
                    control.finishPostResolution()
                    failed += 1
                    terminalError = error
                    results.append(
                        ItemExecutionResult(
                            spelling: item.spelling,
                            outcome: .notVerified,
                            diagnostic: WriteAttemptDiagnostic(
                                ordinal: item.ordinal,
                                postDispatch: dispatch.diagnosticCategory,
                                readbackAttempts: [ReadbackAttemptDiagnostic(
                                    category: ReadbackCategory(error: error)
                                )],
                                terminalErrorCategory: error
                            )
                        )
                    )
                    break
                } catch let error as CompanionError {
                    control.finishPostResolution()
                    failed += 1
                    results.append(
                        ItemExecutionResult(
                            spelling: item.spelling,
                            outcome: .notVerified,
                            diagnostic: WriteAttemptDiagnostic(
                                ordinal: item.ordinal,
                                postDispatch: dispatch.diagnosticCategory,
                                readbackAttempts: [ReadbackAttemptDiagnostic(
                                    category: ReadbackCategory(error: error)
                                )],
                                terminalErrorCategory: error
                            )
                        )
                    )
                    break
                } catch {
                    control.finishPostResolution()
                    failed += 1
                    results.append(
                        ItemExecutionResult(
                            spelling: item.spelling,
                            outcome: .notVerified,
                            diagnostic: WriteAttemptDiagnostic(
                                ordinal: item.ordinal,
                                postDispatch: dispatch.diagnosticCategory,
                                readbackAttempts: [ReadbackAttemptDiagnostic(
                                    category: .responseSchemaRejected
                                )],
                                terminalErrorCategory: .responseRejected
                            )
                        )
                    )
                    break
                }
                control.finishPostResolution()

                let readbackCategory: ReadbackCategory
                if records.isEmpty {
                    readbackCategory = .targetNotVisible
                } else if records.count > 1 {
                    readbackCategory = .targetAmbiguous
                } else if records[0].matchesIntendedState(
                    item.interpretation,
                    tags: plan.tags
                ), plan.group != .update || records[0].id == item.baseline?.id {
                    readbackCategory = .success
                } else {
                    readbackCategory = .intendedStateMismatch
                }
                let diagnostic = WriteAttemptDiagnostic(
                    ordinal: item.ordinal,
                    postDispatch: dispatch.diagnosticCategory,
                    readbackAttempts: [ReadbackAttemptDiagnostic(category: readbackCategory)],
                    terminalErrorCategory: nil
                )

                guard readbackCategory == .success else {
                    failed += 1
                    results.append(
                        ItemExecutionResult(
                            spelling: item.spelling,
                            outcome: .notVerified,
                            diagnostic: diagnostic
                        )
                    )
                    break
                }
                succeeded += 1
                results.append(
                    ItemExecutionResult(
                        spelling: item.spelling,
                        outcome: dispatch == .clean ? .confirmed : .recovered,
                        diagnostic: diagnostic
                    )
                )
            } catch {
                if control.allowsInFlightReadback() { control.finishPostResolution() }
                failed += 1
                results.append(
                    ItemExecutionResult(
                        spelling: item.spelling,
                        outcome: .notVerified,
                        diagnostic: WriteAttemptDiagnostic(
                            ordinal: item.ordinal,
                            postDispatch: .notDispatched,
                            readbackAttempts: [],
                            terminalErrorCategory: error as? CompanionError
                                ?? .responseRejected
                        )
                    )
                )
                break
            }
        }

        return ExecutionSummary(
            group: plan.group,
            succeeded: succeeded,
            failed: failed,
            cancelled: control.isCancellationRequested,
            stalePreview: false,
            results: results,
            terminalError: terminalError
        )
    }
}
