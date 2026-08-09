import Foundation

@MainActor
final class CompanionViewModel: ObservableObject {
    @Published var sourceText = "" {
        didSet {
            if sourceText != oldValue { invalidatePreview() }
        }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var preview: PreviewPresentation?
    @Published private(set) var finalSummary = FinalSummary()
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    @Published private(set) var pendingConfirmation: OperationGroup?

    private let credentialSession = CredentialSession()
    private let transportFactory: () -> HTTPTransport
    private let sleeperFactory: () -> RequestSleeper
    private var snapshot: PreviewSnapshot?
    private var activeControl: ExecutionControl?
    private var sessionID: UUID?
    private var armedApproval: ArmedApprovalIntent?

    private struct ArmedApprovalIntent {
        let approval: NativeApproval
        let sessionID: UUID
    }

    init(
        transportFactory: @escaping () -> HTTPTransport = { URLSessionHTTPTransport() },
        sleeperFactory: @escaping () -> RequestSleeper = { ProductionRequestSleeper() }
    ) {
        self.transportFactory = transportFactory
        self.sleeperFactory = sleeperFactory
    }

    func connect(token: inout String) {
        defer { token.removeAll(keepingCapacity: false) }
        do {
            activeControl?.requestCancellation()
            try credentialSession.connect(token: token)
            sessionID = UUID()
            isConnected = true
            errorMessage = nil
            invalidatePreview()
        } catch {
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            invalidatePreview()
            errorMessage = CompanionError.credentialRejected.description
        }
    }

    func disconnect() {
        activeControl?.requestCancellation()
        credentialSession.disconnect()
        sessionID = nil
        isConnected = false
        invalidatePreview()
    }

    func enterBackground() {
        disconnect()
    }

    func previewCurrentInput() async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        let control = ExecutionControl()
        activeControl = control
        defer {
            if activeControl === control { activeControl = nil }
            isBusy = false
        }

        do {
            let document = sourceText
            let batch = try BatchParser.parseDailyInput(document)
            let lease = try credentialSession.makeOperationLease()
            defer { lease.clear() }
            let api = MaimemoTransport(
                transport: transportFactory(),
                credential: lease,
                sleeper: sleeperFactory()
            )
            let built = try await PreflightPlanner(api: api).buildSnapshot(
                entries: batch.entries,
                credentialFingerprint: lease.fingerprint,
                control: control
            )
            guard document == sourceText,
                  credentialSession.fingerprint == lease.fingerprint
            else {
                throw CompanionError.stalePreview
            }
            snapshot = built
            preview = built.presentation
            finalSummary = FinalSummary(
                created: 0,
                updated: 0,
                alreadyMatching: built.presentation.counts.alreadyMatching,
                failed: 0
            )
        } catch let error as CompanionError {
            invalidatePreview()
            errorMessage = error.description
        } catch {
            invalidatePreview()
            errorMessage = CompanionError.responseRejected.description
        }
    }

    func askToExecute(_ group: OperationGroup) {
        invalidateArmedApproval()
        guard let snapshot,
              let sessionID,
              snapshot.items(for: group).isEmpty == false,
              isConnected,
              !isBusy
        else { return }
        do {
            armedApproval = ArmedApprovalIntent(
                approval: try ConfirmationBinding.makeApproval(snapshot: snapshot, group: group),
                sessionID: sessionID
            )
            pendingConfirmation = group
            errorMessage = nil
        } catch let error as CompanionError {
            errorMessage = error.description
        } catch {
            errorMessage = CompanionError.responseRejected.description
        }
    }

    @discardableResult
    func executeConfirmed(_ group: OperationGroup) -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let intent = consumeArmedApproval()
        guard let displayed = snapshot,
              let currentSessionID = sessionID,
              let intent,
              intent.sessionID == currentSessionID,
              intent.approval.group == group
        else {
            errorMessage = CompanionError.approvalRequired.description
            return nil
        }
        do {
            let currentApproval = try ConfirmationBinding.makeApproval(
                snapshot: displayed,
                group: group
            )
            guard intent.approval == currentApproval else {
                errorMessage = CompanionError.stalePreview.description
                return nil
            }
        } catch let error as CompanionError {
            errorMessage = error.description
            return nil
        } catch {
            errorMessage = CompanionError.responseRejected.description
            return nil
        }
        isBusy = true
        errorMessage = nil
        let control = ExecutionControl()
        activeControl = control

        return Task {
            await executeAuthorized(
                group: group,
                displayed: displayed,
                intent: intent,
                control: control
            )
        }
    }

    private func executeAuthorized(
        group: OperationGroup,
        displayed: PreviewSnapshot,
        intent: ArmedApprovalIntent,
        control: ExecutionControl
    ) async {
        do {
            let lease = try credentialSession.makeOperationLease()
            defer { lease.clear() }
            let api = MaimemoTransport(
                transport: transportFactory(),
                credential: lease,
                sleeper: sleeperFactory()
            )
            let result = await WriteExecutor(api: api).execute(
                group: group,
                displayedSnapshot: displayed,
                approval: intent.approval,
                control: control
            )
            if result.stalePreview {
                errorMessage = CompanionError.stalePreview.description
            } else {
                recordExecutionCounts(
                    group: group,
                    displayed: displayed,
                    succeeded: result.succeeded,
                    failed: result.failed
                )
                if result.failed > 0 {
                    errorMessage = CompanionError.uncertainWriteOutcome.description
                }
            }
        } catch let error as CompanionError {
            if control.isCancellationRequested {
                recordExecutionCounts(group: group, displayed: displayed, succeeded: 0, failed: 0)
            } else {
                errorMessage = error.description
            }
        } catch {
            if control.isCancellationRequested {
                recordExecutionCounts(group: group, displayed: displayed, succeeded: 0, failed: 0)
            } else {
                errorMessage = CompanionError.responseRejected.description
            }
        }
        activeControl = nil
        isBusy = false
        invalidatePreview()
    }

    private func recordExecutionCounts(
        group: OperationGroup,
        displayed: PreviewSnapshot,
        succeeded: Int,
        failed: Int
    ) {
        let selectedCount = displayed.items(for: group).count
        let notAttempted = max(0, selectedCount - succeeded - failed)
        if group == .create { finalSummary.created += succeeded }
        if group == .update { finalSummary.updated += succeeded }
        finalSummary.failed += failed
        finalSummary.notAttempted += notAttempted
        finalSummary.stopped = finalSummary.stopped || notAttempted > 0
    }

    func cancelPendingConfirmation() {
        invalidateArmedApproval()
    }

    private func invalidatePreview() {
        snapshot = nil
        preview = nil
        invalidateArmedApproval()
    }

    private func invalidateArmedApproval() {
        armedApproval = nil
        pendingConfirmation = nil
    }

    private func consumeArmedApproval() -> ArmedApprovalIntent? {
        let intent = armedApproval
        invalidateArmedApproval()
        return intent
    }
}
