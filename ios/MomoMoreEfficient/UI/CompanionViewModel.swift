import Foundation

@MainActor
final class CompanionViewModel: ObservableObject, CustomDebugStringConvertible {
    @Published var sourceText = "" {
        didSet {
            if sourceText != oldValue {
                updateLocalParseState()
                invalidatePreview()
            }
        }
    }
    @Published private(set) var isConnected = false
    @Published private(set) var preview: PreviewPresentation?
    @Published private(set) var finalSummary = FinalSummary()
    @Published private(set) var isBusy = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var localParseState: LocalParseState = .empty
    @Published private(set) var expandedRowIDs = Set<Int>()
    @Published private(set) var hasExecutionFeedback = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingConfirmation: OperationGroup?

    private let credentialSession = CredentialSession()
    private let tokenStore: TokenStore
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
        tokenStore: TokenStore = KeychainTokenStore(),
        transportFactory: @escaping () -> HTTPTransport = { URLSessionHTTPTransport() },
        sleeperFactory: @escaping () -> RequestSleeper = { ProductionRequestSleeper() }
    ) {
        self.tokenStore = tokenStore
        self.transportFactory = transportFactory
        self.sleeperFactory = sleeperFactory
        restoreCredentialIfAvailable()
    }

    func connect(token: inout String) {
        var candidate = token
        token.removeAll(keepingCapacity: false)
        defer { candidate.removeAll(keepingCapacity: false) }
        clearTransientCredential()
        do {
            try credentialSession.connect(token: candidate)
            try tokenStore.saveToken(candidate)
            sessionID = UUID()
            isConnected = true
            errorMessage = nil
        } catch let error as CompanionError {
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            errorMessage = error.description
        } catch {
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            errorMessage = CompanionError.credentialStorageUnavailable.description
        }
    }

    func removeToken() {
        guard !isBusy else { return }
        activeControl?.requestCancellation()
        invalidatePreview()
        do {
            try tokenStore.deleteToken()
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            errorMessage = nil
        } catch {
            errorMessage = CompanionError.credentialStorageUnavailable.description
        }
    }

    func enterBackground() {
        clearTransientCredential()
    }

    func enterForeground() {
        restoreCredentialIfAvailable()
    }

    func previewCurrentInput() async {
        guard !isBusy else { return }
        isBusy = true
        isPreviewing = true
        errorMessage = nil
        let control = ExecutionControl()
        activeControl = control
        defer {
            if activeControl === control { activeControl = nil }
            isPreviewing = false
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
            expandedRowIDs.removeAll()
            hasExecutionFeedback = false
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
        hasExecutionFeedback = true
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

    var isShowingEditor: Bool { preview == nil }

    var previewHeader: String? {
        guard let rows = preview?.rows,
              let first = rows.first?.spelling,
              let last = rows.last?.spelling
        else { return nil }
        return "\(rows.count) 条释义 · \(first) → \(last)"
    }

    var executionActions: [ExecutionAction] {
        guard let counts = preview?.counts else { return [] }
        return [
            ExecutionAction(group: .create, count: counts.create),
            ExecutionAction(group: .update, count: counts.update),
        ]
    }

    func editInput() {
        invalidatePreview()
    }

    func toggleDetails(for row: PreviewRow) {
        guard row.canExpand else { return }
        if expandedRowIDs.contains(row.id) {
            expandedRowIDs.remove(row.id)
        } else {
            expandedRowIDs.insert(row.id)
        }
    }

    func details(for row: PreviewRow) -> PreviewRowDetails? {
        guard row.canExpand, expandedRowIDs.contains(row.id) else { return nil }
        return PreviewRowDetails(current: row.current, proposed: row.proposed)
    }

    private func invalidatePreview() {
        snapshot = nil
        preview = nil
        expandedRowIDs.removeAll()
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

    private func updateLocalParseState() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localParseState = .empty
            return
        }
        do {
            let entries = try BatchParser.parseDailyInput(sourceText).entries
            guard let first = entries.first?.spelling,
                  let last = entries.last?.spelling
            else {
                localParseState = .invalid
                return
            }
            localParseState = .valid(count: entries.count, first: first, last: last)
        } catch {
            localParseState = .invalid
        }
    }

    private func clearTransientCredential() {
        activeControl?.requestCancellation()
        credentialSession.disconnect()
        sessionID = nil
        isConnected = false
        invalidatePreview()
    }

    private func restoreCredentialIfAvailable() {
        guard !credentialSession.isConnected else { return }
        do {
            guard var token = try tokenStore.loadToken() else {
                isConnected = false
                return
            }
            defer { token.removeAll(keepingCapacity: false) }
            try credentialSession.connect(token: token)
            sessionID = UUID()
            isConnected = true
            errorMessage = nil
        } catch let error as CompanionError {
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            errorMessage = error.description
        } catch {
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            errorMessage = CompanionError.credentialStorageUnavailable.description
        }
    }

    nonisolated var debugDescription: String { "CompanionViewModel(<redacted credential>)" }
}
