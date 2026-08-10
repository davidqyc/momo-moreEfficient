import Foundation

@MainActor
final class CompanionViewModel: ObservableObject, CustomDebugStringConvertible {
    @Published var sourceText = "" {
        didSet {
            if sourceText != oldValue {
                detachInlineExecutionFeedback()
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
    @Published private(set) var isPreviewStale = false
    @Published private(set) var history: [ExecutionReceipt] = []
    @Published private(set) var completionAcknowledgement: String?
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var isExecuting = false
    @Published private(set) var executionStage: ExecutionStage?
    @Published private(set) var previewProgress: PreviewProgress?

    private let credentialSession = CredentialSession()
    private let tokenStore: TokenStore
    private let historyStore: HistoryStore
    private let transportFactory: () -> HTTPTransport
    private let sleeperFactory: () -> RequestSleeper
    private let backgroundAssertionFactory: @MainActor () -> BackgroundExecutionAssertion
    private let dateProvider: () -> Date
    private var snapshot: PreviewSnapshot?
    private var activeControl: ExecutionControl?
    private var sessionID: UUID?
    private var armedApproval: ArmedApprovalIntent?
    /// Set when the app left the foreground while an authorized batch or an active
    /// Preview was running. The transient credential teardown is owed but
    /// deliberately postponed until that work resolves, so that scene changes
    /// cannot disturb it.
    private var owesBackgroundTeardown = false
    /// A Preview that finished while the app was away and whose transient
    /// credential was then torn down. It is deliberately NOT executable in this
    /// state; `enterForeground()` revalidates it before restoring it.
    private var suspendedPreview: SuspendedPreview?

    private struct ArmedApprovalIntent {
        let approval: NativeApproval
        let sessionID: UUID
    }

    private struct SuspendedPreview {
        let snapshot: PreviewSnapshot
        /// The exact document the snapshot was built from.
        let document: String
    }

    init(
        tokenStore: TokenStore = KeychainTokenStore(),
        historyStore: HistoryStore = FileHistoryStore(),
        transportFactory: @escaping () -> HTTPTransport = { URLSessionHTTPTransport() },
        sleeperFactory: @escaping () -> RequestSleeper = { ProductionRequestSleeper() },
        backgroundAssertionFactory: @escaping @MainActor () -> BackgroundExecutionAssertion
            = { makeDefaultBackgroundExecutionAssertion() },
        dateProvider: @escaping () -> Date = Date.init
    ) {
        self.tokenStore = tokenStore
        self.historyStore = historyStore
        self.transportFactory = transportFactory
        self.sleeperFactory = sleeperFactory
        self.backgroundAssertionFactory = backgroundAssertionFactory
        self.dateProvider = dateProvider
        restoreHistory()
        restoreCredentialIfAvailable()
    }

    func connect(token: inout String) {
        var candidate = token
        token.removeAll(keepingCapacity: false)
        defer { candidate.removeAll(keepingCapacity: false) }
        clearTransientCredential(preservingPreviewPresentation: false)
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

    /// `.inactive` or `.background`.
    ///
    /// Before execution starts this keeps the existing stale-Preview safety: the
    /// transient credential is dropped and the executable Preview is invalidated.
    ///
    /// Once an authorized batch has actually started — or a read-only Preview is
    /// already part-way through its reads — a scene change is NOT an instruction
    /// to cancel. App switching and call interruptions leave that work alone; only
    /// the system reclaiming our background assertion stops it, through the
    /// ordinary cancellation path.
    func enterBackground() {
        guard !isExecuting, !isPreviewing else {
            owesBackgroundTeardown = true
            return
        }
        clearTransientCredential(preservingPreviewPresentation: true)
    }

    func enterForeground() {
        owesBackgroundTeardown = false
        restoreCredentialIfAvailable()
        restoreSuspendedPreviewIfStillValid()
    }

    /// A Preview that completed during a short interruption is usable again only
    /// if the document it was built from is still the current one and the restored
    /// credential is the very same one that produced it. Anything else drops it,
    /// leaving the presentation read-only exactly as a stale Preview would be.
    ///
    /// This restores read state only. No approval is persisted or revived, and
    /// execution still performs its own fresh authenticated preflight before any
    /// POST.
    private func restoreSuspendedPreviewIfStillValid() {
        guard let suspended = suspendedPreview else { return }
        suspendedPreview = nil
        guard !isBusy,
              isConnected,
              suspended.document == sourceText,
              let fingerprint = credentialSession.fingerprint,
              fingerprint == suspended.snapshot.credentialFingerprint
        else { return }
        snapshot = suspended.snapshot
        preview = suspended.snapshot.presentation
        isPreviewStale = false
    }

    func previewCurrentInput() async {
        guard !isBusy else { return }
        let preserveStalePresentationOnFailure = isPreviewStale && preview != nil
        isBusy = true
        isPreviewing = true
        errorMessage = nil
        previewProgress = nil
        let control = ExecutionControl()
        activeControl = control

        // Preview is a user-initiated read. Taken while still frontmost, it lets an
        // ordinary app switch or call interruption pass without discarding reads
        // that already completed. Expiry stops it cleanly; nothing is ever written.
        let assertion = backgroundAssertionFactory()
        assertion.begin(reason: "momo-interpretation-preview") {
            control.requestCancellation()
        }
        defer {
            assertion.end()
            if activeControl === control { activeControl = nil }
            isPreviewing = false
            isBusy = false
            previewProgress = nil
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
                control: control,
                onEntryStarted: { [weak self] entry, total in
                    Task { @MainActor [weak self] in
                        guard let self, self.isPreviewing else { return }
                        self.previewProgress = PreviewProgress(entry: entry, total: total)
                    }
                }
            )
            // Unchanged: the teardown owed to a background transition is postponed
            // until this function returns, so the session is still the one that
            // produced the lease and this check keeps its original strength.
            guard document == sourceText,
                  credentialSession.fingerprint == lease.fingerprint
            else {
                throw CompanionError.stalePreview
            }
            snapshot = built
            preview = built.presentation
            isPreviewStale = false
            expandedRowIDs.removeAll()
            hasExecutionFeedback = false
            finalSummary = FinalSummary(
                created: 0,
                updated: 0,
                alreadyMatching: built.presentation.counts.alreadyMatching,
                failed: 0
            )
        } catch let error as CompanionError {
            invalidatePreviewAfterRefreshFailure(
                preservingStalePresentation: preserveStalePresentationOnFailure
            )
            errorMessage = control.isCancellationRequested
                ? CompanionError.previewInterrupted.description
                : error.description
        } catch {
            invalidatePreviewAfterRefreshFailure(
                preservingStalePresentation: preserveStalePresentationOnFailure
            )
            errorMessage = CompanionError.responseRejected.description
        }

        settleBackgroundTeardownOwedByPreview(document: sourceText)
    }

    /// Runs the transient-credential teardown that a background transition asked
    /// for while this Preview was still reading.
    ///
    /// Token hygiene is unchanged — the credential is dropped exactly as it would
    /// have been at the moment of the transition. What is preserved is the *read*
    /// result, held aside as non-executable until `enterForeground()` revalidates
    /// it, so a short interruption does not force the Owner to re-read every item.
    private func settleBackgroundTeardownOwedByPreview(document: String) {
        guard owesBackgroundTeardown else { return }
        owesBackgroundTeardown = false
        let completed = snapshot
        clearTransientCredential(preservingPreviewPresentation: true)
        guard let completed else { return }
        suspendedPreview = SuspendedPreview(snapshot: completed, document: document)
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
        isExecuting = true
        // Visible immediately, before the first await, so the UI never sits in an
        // unexplained disabled state.
        executionStage = .preflight(group: group, entry: 1, total: displayed.items.count)
        errorMessage = nil
        historyErrorMessage = nil
        let control = ExecutionControl()
        activeControl = control

        // Taken while we are still frontmost, which is the only time UIKit allows it.
        let assertion = backgroundAssertionFactory()
        assertion.begin(reason: "momo-interpretation-write-batch") {
            // Expiry means fail closed: stop dispatching further items. It never
            // retries, never resumes and never issues a second POST for an item.
            control.requestCancellation()
        }

        return Task {
            await executeAuthorized(
                group: group,
                displayed: displayed,
                intent: intent,
                control: control,
                assertion: assertion
            )
        }
    }

    private func executeAuthorized(
        group: OperationGroup,
        displayed: PreviewSnapshot,
        intent: ArmedApprovalIntent,
        control: ExecutionControl,
        assertion: BackgroundExecutionAssertion
    ) async {
        var completedReceipt: ExecutionReceipt?
        let progress = ExecutionProgressReporter { [weak self] stage in
            Task { @MainActor [weak self] in
                // A report that lands after the batch resolved must not resurrect
                // a progress label on a finished run.
                guard let self, self.isExecuting else { return }
                self.executionStage = stage
            }
        }
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
                control: control,
                progress: progress
            )
            if result.stalePreview {
                errorMessage = CompanionError.stalePreview.description
            } else {
                completedReceipt = recordExecution(
                    group: group,
                    displayed: displayed,
                    result: result
                )
                if result.failed > 0 {
                    errorMessage = CompanionError.uncertainWriteOutcome.description
                }
            }
        } catch let error as CompanionError {
            if control.isCancellationRequested {
                completedReceipt = recordExecution(
                    group: group,
                    displayed: displayed,
                    result: cancelledSummary(for: group)
                )
            } else {
                errorMessage = error.description
            }
        } catch {
            if control.isCancellationRequested {
                completedReceipt = recordExecution(
                    group: group,
                    displayed: displayed,
                    result: cancelledSummary(for: group)
                )
            } else {
                errorMessage = CompanionError.responseRejected.description
            }
        }
        assertion.end()
        activeControl = nil
        isBusy = false
        isExecuting = false
        executionStage = nil
        invalidatePreview()
        if let completedReceipt, completedReceipt.isFullSuccess {
            let localHistoryError = historyErrorMessage
            sourceText = remainingSourceDocument(
                afterCompleting: group,
                in: displayed
            )
            completionAcknowledgement = acknowledgement(for: completedReceipt)
            historyErrorMessage = localHistoryError
        }
        // The scene change we postponed while the batch was authorized and running.
        if owesBackgroundTeardown {
            owesBackgroundTeardown = false
            clearTransientCredential(preservingPreviewPresentation: true)
        }
    }

    @discardableResult
    private func recordExecution(
        group: OperationGroup,
        displayed: PreviewSnapshot,
        result: ExecutionSummary
    ) -> ExecutionReceipt {
        let selectedSpellings = displayed.items(for: group).map { $0.entry.spelling }
        let receipt = ExecutionReceipt(
            timestamp: dateProvider(),
            operationGroup: group,
            selectedSpellings: selectedSpellings,
            result: result
        )
        history.insert(receipt, at: 0)
        do {
            try historyStore.saveReceipts(history)
        } catch {
            historyErrorMessage = "历史记录保存失败"
        }

        if receipt.isFullSuccess {
            hasExecutionFeedback = false
            finalSummary = FinalSummary()
        } else {
            hasExecutionFeedback = true
            finalSummary = FinalSummary(
                created: group == .create ? receipt.succeeded : 0,
                updated: group == .update ? receipt.succeeded : 0,
                alreadyMatching: 0,
                failed: receipt.failed,
                notAttempted: receipt.notAttempted,
                stopped: receipt.stopped
            )
        }
        return receipt
    }

    private func cancelledSummary(for group: OperationGroup) -> ExecutionSummary {
        ExecutionSummary(
            group: group,
            succeeded: 0,
            failed: 0,
            cancelled: true,
            stalePreview: false,
            results: []
        )
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

    /// Non-nil only while a Preview is reading.
    var previewProgressLabel: String? {
        guard isPreviewing else { return nil }
        return previewProgress?.label
    }

    /// Non-nil only while an authorized batch is running.
    var executionProgressLabel: String? {
        guard isExecuting else { return nil }
        return executionStage?.label
    }

    var executionActions: [ExecutionAction] {
        guard let snapshot,
              preview != nil,
              !isPreviewStale,
              isConnected
        else { return [] }
        let counts = snapshot.presentation.counts
        return [
            ExecutionAction(group: .create, count: counts.create),
            ExecutionAction(group: .update, count: counts.update),
        ]
    }

    func editInput() {
        invalidatePreview()
    }

    func clearHistory() {
        do {
            try historyStore.clearReceipts()
            history.removeAll()
            historyErrorMessage = nil
        } catch {
            historyErrorMessage = "历史记录清空失败"
        }
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
        preview = nil
        expandedRowIDs.removeAll()
        invalidateExecutionAuthorization()
    }

    private func invalidateExecutionAuthorization() {
        snapshot = nil
        // A source edit, token change or explicit invalidation also discards any
        // Preview held aside across an interruption.
        suspendedPreview = nil
        isPreviewStale = preview != nil
        invalidateArmedApproval()
    }

    private func invalidatePreviewAfterRefreshFailure(preservingStalePresentation: Bool) {
        if preservingStalePresentation, preview != nil {
            invalidateExecutionAuthorization()
        } else {
            invalidatePreview()
        }
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

    private func detachInlineExecutionFeedback() {
        completionAcknowledgement = nil
        hasExecutionFeedback = false
        finalSummary = FinalSummary()
        historyErrorMessage = nil
        errorMessage = nil
    }

    private func acknowledgement(for receipt: ExecutionReceipt) -> String {
        let verb = receipt.operationGroup == .create ? "已新建" : "已更新"
        guard receipt.items.count == 1, let spelling = receipt.items.first?.spelling else {
            return "\(verb) \(receipt.succeeded) 条"
        }
        return "\(verb) 1 条 · \(spelling)"
    }

    private func remainingSourceDocument(
        afterCompleting completedGroup: OperationGroup,
        in displayed: PreviewSnapshot
    ) -> String {
        let remainingGroup: OperationGroup = completedGroup == .create ? .update : .create
        let remainingEntries = displayed.items(for: remainingGroup).map(\.entry)
        return BatchParser.canonicalDocument(for: remainingEntries)
    }

    private func restoreHistory() {
        do {
            history = try historyStore.loadReceipts().sorted { $0.timestamp > $1.timestamp }
        } catch {
            history = []
            historyErrorMessage = "历史记录读取失败"
        }
    }

    private func clearTransientCredential(preservingPreviewPresentation: Bool) {
        activeControl?.requestCancellation()
        credentialSession.disconnect()
        sessionID = nil
        isConnected = false
        if preservingPreviewPresentation {
            invalidateExecutionAuthorization()
        } else {
            invalidatePreview()
        }
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

    var hasExecutablePreview: Bool { snapshot != nil }
}
