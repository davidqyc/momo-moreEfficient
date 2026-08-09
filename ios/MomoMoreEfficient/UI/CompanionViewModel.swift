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
    @Published var pendingConfirmation: OperationGroup?

    private let credentialSession = CredentialSession()
    private let transportFactory: () -> HTTPTransport
    private let sleeperFactory: () -> RequestSleeper
    private var snapshot: PreviewSnapshot?
    private var activeControl: ExecutionControl?

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
            isConnected = true
            errorMessage = nil
            invalidatePreview()
        } catch {
            credentialSession.disconnect()
            isConnected = false
            invalidatePreview()
            errorMessage = CompanionError.credentialRejected.description
        }
    }

    func disconnect() {
        activeControl?.requestCancellation()
        credentialSession.disconnect()
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
        guard snapshot?.items(for: group).isEmpty == false, isConnected, !isBusy else { return }
        pendingConfirmation = group
    }

    func executeConfirmed(_ group: OperationGroup) async {
        pendingConfirmation = nil
        guard !isBusy else { return }
        guard let displayed = snapshot else {
            errorMessage = CompanionError.previewRequired.description
            return
        }
        isBusy = true
        errorMessage = nil
        let control = ExecutionControl()
        activeControl = control

        do {
            let approval = try ConfirmationBinding.makeApproval(
                snapshot: displayed,
                group: group
            )
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
                approval: approval,
                control: control
            )
            if result.stalePreview {
                errorMessage = CompanionError.stalePreview.description
            } else if result.cancelled && result.succeeded == 0 && result.failed == 0 {
                errorMessage = CompanionError.cancelled.description
            } else {
                if group == .create { finalSummary.created += result.succeeded }
                if group == .update { finalSummary.updated += result.succeeded }
                finalSummary.failed += result.failed
                if result.failed > 0 {
                    errorMessage = CompanionError.uncertainWriteOutcome.description
                }
            }
        } catch let error as CompanionError {
            errorMessage = error.description
        } catch {
            errorMessage = CompanionError.responseRejected.description
        }
        activeControl = nil
        isBusy = false
        invalidatePreview()
    }

    func cancelPendingConfirmation() {
        pendingConfirmation = nil
    }

    private func invalidatePreview() {
        snapshot = nil
        preview = nil
        pendingConfirmation = nil
    }
}
