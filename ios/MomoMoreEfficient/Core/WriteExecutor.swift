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

            let entries = displayedSnapshot.items.map(\.entry)
            progress?.report(.preflight(group: group, completed: 0, total: entries.count))
            let fresh = try await PreflightPlanner(api: api).buildSnapshot(
                entries: entries,
                credentialFingerprint: displayedSnapshot.credentialFingerprint,
                control: control,
                onEntryResolved: { completed, total in
                    progress?.report(
                        .preflight(group: group, completed: completed, total: total)
                    )
                }
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

    private func perform(
        plan: ConfirmationPlan,
        control: ExecutionControl,
        progress: ExecutionProgressReporter?
    ) async -> ExecutionSummary {
        var results: [ItemExecutionResult] = []
        var succeeded = 0
        var failed = 0

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
                let body = try ConfirmationBinding.requestData(item, group: plan.group)
                let dispatch = await api.post(route: route, body: body, control: control)
                guard dispatch != .notDispatched else {
                    results.append(
                        ItemExecutionResult(spelling: item.spelling, outcome: .notAttempted)
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
                } catch {
                    control.finishPostResolution()
                    failed += 1
                    results.append(
                        ItemExecutionResult(spelling: item.spelling, outcome: .notVerified)
                    )
                    break
                }
                control.finishPostResolution()

                guard records.count == 1,
                      records[0].matchesIntendedState(item.interpretation),
                      plan.group != .update || records[0].id == item.baseline?.id
                else {
                    failed += 1
                    results.append(
                        ItemExecutionResult(spelling: item.spelling, outcome: .notVerified)
                    )
                    break
                }
                succeeded += 1
                results.append(
                    ItemExecutionResult(
                        spelling: item.spelling,
                        outcome: dispatch == .clean ? .confirmed : .recovered
                    )
                )
            } catch {
                if control.allowsInFlightReadback() { control.finishPostResolution() }
                failed += 1
                results.append(ItemExecutionResult(spelling: item.spelling, outcome: .notVerified))
                break
            }
        }

        return ExecutionSummary(
            group: plan.group,
            succeeded: succeeded,
            failed: failed,
            cancelled: control.isCancellationRequested,
            stalePreview: false,
            results: results
        )
    }
}
