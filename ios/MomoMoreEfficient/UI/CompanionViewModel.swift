import Foundation

@MainActor
final class CompanionViewModel: ObservableObject, CustomDebugStringConvertible {
    @Published var sourceText = "" {
        didSet {
            if sourceText != oldValue {
                storeActiveDraft(sourceText)
                detachInlineExecutionFeedback()
                updateLocalParseState()
                invalidatePreview()
            }
        }
    }
    @Published private(set) var contentMode: ContentMode = .interpretation
    @Published private(set) var isConnected = false
    @Published private(set) var preview: PreviewPresentation?
    @Published private(set) var phrasePreview: PhrasePreviewPresentation?
    @Published private(set) var finalSummary = FinalSummary()
    @Published private(set) var isBusy = false
    @Published private(set) var isPreviewing = false
    @Published private(set) var localParseState: LocalParseState = .empty
    @Published private(set) var expandedRowIDs = Set<Int>()
    @Published private(set) var hasExecutionFeedback = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var pendingConfirmation: OperationGroup?
    @Published private(set) var pendingBatchConfirmation: PendingBatchConfirmation?
    @Published private(set) var pendingPhraseConfirmation: PendingPhraseConfirmation?
    @Published private(set) var isPreviewStale = false
    @Published private(set) var history: [ExecutionReceipt] = []
    @Published private(set) var completionAcknowledgement: String?
    @Published private(set) var historyErrorMessage: String?
    @Published private(set) var isExecuting = false
    @Published private(set) var executionStage: ExecutionStage?
    @Published private(set) var previewProgress: PreviewProgress?
    @Published private(set) var phraseObservationMessage: String?
    @Published private(set) var selectedTags: [String] = []
    @Published private(set) var isValidatingCredential = false
    @Published private(set) var tokenErrorMessage: String?

    private let credentialSession = CredentialSession()
    private let tokenStore: TokenStore
    private let historyStore: HistoryStore
    private let transportFactory: () -> HTTPTransport
    private let credentialValidationTransportFactory: () -> HTTPTransport
    private let sleeperFactory: () -> RequestSleeper
    private let backgroundAssertionFactory: @MainActor () -> BackgroundExecutionAssertion
    private let dateProvider: () -> Date
    private let preferenceDefaults: UserDefaults
    private var snapshot: PreviewSnapshot?
    private var phraseSnapshot: PhrasePreviewSnapshot?
    private var activeControl: ExecutionControl?
    private var sessionID: UUID?
    private var armedApproval: ArmedApprovalIntent?
    private var armedBatchApproval: ArmedBatchApprovalIntent?
    private var armedPhraseApproval: ArmedPhraseApprovalIntent?
    private var interpretationDraft = ""
    private var phraseDraft = ""
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

    /// One native confirmation covering the whole displayed plan (#76). The armed
    /// value is the only authorization the run ever uses; it is consumed once and
    /// is never re-minted, broadened or re-derived on the Owner's behalf.
    private struct ArmedBatchApprovalIntent {
        let approval: BatchPlanApproval
        let sessionID: UUID
    }

    private struct ArmedPhraseApprovalIntent {
        let approval: PhraseCreateApproval
        let sessionID: UUID
    }

    private enum SuspendedSnapshot {
        case interpretation(PreviewSnapshot)
        case phrase(PhrasePreviewSnapshot)

        var credentialFingerprint: String {
            switch self {
            case let .interpretation(snapshot): return snapshot.credentialFingerprint
            case let .phrase(snapshot): return snapshot.credentialFingerprint
            }
        }

        var tags: [String] {
            switch self {
            case let .interpretation(snapshot): return snapshot.bindingContext.tags
            case let .phrase(snapshot): return snapshot.bindingContext.tags
            }
        }
    }

    private struct SuspendedPreview {
        let mode: ContentMode
        let snapshot: SuspendedSnapshot
        /// The exact document the snapshot was built from.
        let document: String
    }

    init(
        tokenStore: TokenStore = KeychainTokenStore(),
        historyStore: HistoryStore = FileHistoryStore(),
        transportFactory: @escaping () -> HTTPTransport = { URLSessionHTTPTransport() },
        credentialValidationTransportFactory: (() -> HTTPTransport)? = nil,
        sleeperFactory: @escaping () -> RequestSleeper = { ProductionRequestSleeper() },
        backgroundAssertionFactory: @escaping @MainActor () -> BackgroundExecutionAssertion
            = { makeDefaultBackgroundExecutionAssertion() },
        dateProvider: @escaping () -> Date = Date.init,
        preferenceDefaults: UserDefaults = .standard
    ) {
        self.tokenStore = tokenStore
        self.historyStore = historyStore
        self.transportFactory = transportFactory
        self.credentialValidationTransportFactory = credentialValidationTransportFactory
            ?? transportFactory
        self.sleeperFactory = sleeperFactory
        self.backgroundAssertionFactory = backgroundAssertionFactory
        self.dateProvider = dateProvider
        self.preferenceDefaults = preferenceDefaults
        selectedTags = WriteTagPreference.load(from: preferenceDefaults)
        restoreHistory()
    }

    /// Validates a candidate independently. The active session and Keychain value
    /// are untouched until the documented authenticated GET succeeds.
    func connect(token: String) async -> Bool {
        guard !isBusy, !isValidatingCredential else { return false }
        var normalized = InMemoryCredential.normalize(token)
        defer { normalized.removeAll(keepingCapacity: false) }
        isValidatingCredential = true
        tokenErrorMessage = nil
        defer {
            isValidatingCredential = false
            if owesBackgroundTeardown {
                owesBackgroundTeardown = false
                clearTransientCredential(preservingPreviewPresentation: true)
            }
        }

        do {
            let candidate = try InMemoryCredential(token: normalized)
            do {
                try await validateCredential(candidate)
                try tokenStore.saveToken(normalized)
            } catch {
                candidate.clear()
                throw error
            }
            credentialSession.replace(with: candidate)
            sessionID = UUID()
            isConnected = true
            invalidatePreview()
            errorMessage = nil
            tokenErrorMessage = nil
            return true
        } catch let error as CompanionError {
            tokenErrorMessage = credentialCandidateMessage(for: error)
        } catch {
            tokenErrorMessage = CompanionError.credentialStorageUnavailable.description
        }
        return false
    }

    func clearTokenError() {
        guard !isValidatingCredential else { return }
        tokenErrorMessage = nil
    }

    #if DEBUG
    /// Existing XCTest setup for write/preview invariants that are unrelated to
    /// onboarding. New credential tests must use `connect(token:)` and the fake
    /// authenticated GET; this helper is not reachable from the product UI.
    func installVerifiedCredentialForTesting(token: inout String) {
        var candidate = InMemoryCredential.normalize(token)
        token.removeAll(keepingCapacity: false)
        defer { candidate.removeAll(keepingCapacity: false) }
        do {
            try credentialSession.connect(token: candidate)
            try tokenStore.saveToken(candidate)
            sessionID = UUID()
            isConnected = true
            errorMessage = nil
            invalidatePreview()
        } catch let error as CompanionError {
            errorMessage = error.description
        } catch {
            errorMessage = CompanionError.credentialStorageUnavailable.description
        }
    }
    #endif

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
        guard !isExecuting, !isPreviewing, !isValidatingCredential else {
            owesBackgroundTeardown = true
            return
        }
        clearTransientCredential(preservingPreviewPresentation: true)
    }

    func enterForeground() async {
        owesBackgroundTeardown = false
        await restoreCredentialIfAvailable()
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
              suspended.mode == contentMode,
              suspended.document == sourceText,
              suspended.snapshot.tags == selectedTags,
              let fingerprint = credentialSession.fingerprint,
              fingerprint == suspended.snapshot.credentialFingerprint
        else { return }
        switch suspended.snapshot {
        case let .interpretation(restored):
            guard contentMode == .interpretation else { return }
            snapshot = restored
            preview = restored.presentation
        case let .phrase(restored):
            guard contentMode == .phrase else { return }
            phraseSnapshot = restored
            phrasePreview = restored.presentation
        }
        isPreviewStale = false
    }

    func previewCurrentInput() async {
        guard !isBusy else { return }
        let mode = contentMode
        let preserveStalePresentationOnFailure = isPreviewStale && activePreviewExists
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
        assertion.begin(reason: mode == .interpretation
            ? "momo-interpretation-preview"
            : "momo-phrase-preview") {
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
            let tags = selectedTags
            let lease = try credentialSession.makeOperationLease()
            defer { lease.clear() }
            let api = MaimemoTransport(
                transport: transportFactory(),
                credential: lease,
                sleeper: sleeperFactory()
            )
            let progress: @Sendable (Int, Int) -> Void = { [weak self] entry, total in
                Task { @MainActor [weak self] in
                    guard let self, self.isPreviewing else { return }
                    self.previewProgress = PreviewProgress(entry: entry, total: total)
                }
            }
            if mode == .interpretation {
                let batch = try BatchParser.parseDailyInput(document)
                let built = try await PreflightPlanner(api: api).buildSnapshot(
                    entries: batch.entries,
                    tags: tags,
                    credentialFingerprint: lease.fingerprint,
                    control: control,
                    onEntryStarted: progress
                )
                snapshot = built
                preview = built.presentation
                phraseSnapshot = nil
                phrasePreview = nil
                finalSummary = FinalSummary(
                    created: 0,
                    updated: 0,
                    alreadyMatching: built.presentation.counts.alreadyMatching,
                    failed: 0
                )
            } else {
                let entries = try PhraseBatchParser.parse(document)
                let built = try await PhrasePreflightPlanner(api: api).buildSnapshot(
                    entries: entries,
                    tags: tags,
                    credentialFingerprint: lease.fingerprint,
                    control: control,
                    onEntryStarted: progress
                )
                phraseSnapshot = built
                phrasePreview = built.presentation
                snapshot = nil
                preview = nil
                finalSummary = FinalSummary(
                    created: 0,
                    updated: 0,
                    alreadyMatching: built.alreadyMatchingCount,
                    failed: 0
                )
            }
            // Unchanged: the teardown owed to a background transition is postponed
            // until this function returns, so the session is still the one that
            // produced the lease and this check keeps its original strength.
            guard mode == contentMode,
                  document == sourceText,
                  tags == selectedTags,
                  credentialSession.fingerprint == lease.fingerprint
            else {
                throw CompanionError.stalePreview
            }
            isPreviewStale = false
            expandedRowIDs.removeAll()
            hasExecutionFeedback = false
        } catch let error as CompanionError {
            invalidatePreviewAfterRefreshFailure(
                preservingStalePresentation: preserveStalePresentationOnFailure
            )
            handleSessionFailure(error)
            errorMessage = control.isCancellationRequested
                ? CompanionError.previewInterrupted.description
                : error.description
        } catch {
            invalidatePreviewAfterRefreshFailure(
                preservingStalePresentation: preserveStalePresentationOnFailure
            )
            errorMessage = CompanionError.responseRejected.description
        }

        settleBackgroundTeardownOwedByPreview(mode: mode, document: sourceText)
    }

    /// Runs the transient-credential teardown that a background transition asked
    /// for while this Preview was still reading.
    ///
    /// Token hygiene is unchanged — the credential is dropped exactly as it would
    /// have been at the moment of the transition. What is preserved is the *read*
    /// result, held aside as non-executable until `enterForeground()` revalidates
    /// it, so a short interruption does not force the Owner to re-read every item.
    private func settleBackgroundTeardownOwedByPreview(mode: ContentMode, document: String) {
        guard owesBackgroundTeardown else { return }
        owesBackgroundTeardown = false
        let completed: SuspendedSnapshot? = switch mode {
        case .interpretation: snapshot.map(SuspendedSnapshot.interpretation)
        case .phrase: phraseSnapshot.map(SuspendedSnapshot.phrase)
        }
        clearTransientCredential(preservingPreviewPresentation: true)
        guard let completed else { return }
        suspendedPreview = SuspendedPreview(mode: mode, snapshot: completed, document: document)
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

    /// Arms the single whole-plan approval a mixed batch is executed with (#76).
    ///
    /// Exactly one native confirmation is prepared here. Nothing later mints a
    /// second one, and nothing reuses the CREATE portion as UPDATE permission:
    /// the armed value records each phase's own binding digest, and each phase is
    /// admitted only by reproducing its own digest from a fresh authenticated read.
    func askToExecuteWholePlan() {
        invalidateArmedApproval()
        guard let snapshot,
              let sessionID,
              isConnected,
              !isBusy
        else { return }
        do {
            let plan = try ConfirmationBinding.makeBatchPlan(snapshot: snapshot)
            armedBatchApproval = ArmedBatchApprovalIntent(
                approval: try ConfirmationBinding.makeBatchApproval(snapshot: snapshot),
                sessionID: sessionID
            )
            pendingBatchConfirmation = PendingBatchConfirmation(
                createSpellings: plan.plan(for: .create)?.items.map(\.spelling) ?? [],
                updateSpellings: plan.plan(for: .update)?.items.map(\.spelling) ?? [],
                bindingDigest: plan.bindingDigest
            )
            errorMessage = nil
        } catch let error as CompanionError {
            errorMessage = error.description
        } catch {
            errorMessage = CompanionError.responseRejected.description
        }
    }

    func askToExecutePhrase() {
        invalidateArmedApproval()
        guard contentMode == .phrase,
              let phraseSnapshot,
              let sessionID,
              phraseSnapshot.createCount > 0,
              phraseSnapshot.blockedCount == 0,
              isConnected,
              !isBusy,
              !isPreviewStale
        else { return }
        do {
            let plan = try PhraseCreateBinding.makePlan(snapshot: phraseSnapshot)
            armedPhraseApproval = ArmedPhraseApprovalIntent(
                approval: try PhraseCreateBinding.makeApproval(snapshot: phraseSnapshot),
                sessionID: sessionID
            )
            pendingPhraseConfirmation = PendingPhraseConfirmation(
                spellings: plan.items.map(\.entry.spelling),
                bindingDigest: plan.bindingDigest
            )
            errorMessage = nil
        } catch let error as CompanionError {
            errorMessage = error.description
        } catch {
            errorMessage = CompanionError.responseRejected.description
        }
    }

    @discardableResult
    func executeConfirmedPhrase() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let intent = consumeArmedPhraseApproval()
        guard contentMode == .phrase,
              let displayed = phraseSnapshot,
              let currentSessionID = sessionID,
              let intent,
              intent.sessionID == currentSessionID
        else {
            errorMessage = CompanionError.approvalRequired.description
            return nil
        }
        do {
            guard intent.approval == (try PhraseCreateBinding.makeApproval(snapshot: displayed))
            else {
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
        executionStage = .securing
        errorMessage = nil
        historyErrorMessage = nil
        phraseObservationMessage = nil
        let control = ExecutionControl()
        activeControl = control
        let assertion = backgroundAssertionFactory()
        assertion.begin(reason: "momo-phrase-create-batch") {
            control.requestCancellation()
        }
        return Task {
            await executeAuthorizedPhrase(
                displayed: displayed,
                intent: intent,
                control: control,
                assertion: assertion
            )
        }
    }

    private func executeAuthorizedPhrase(
        displayed: PhrasePreviewSnapshot,
        intent: ArmedPhraseApprovalIntent,
        control: ExecutionControl,
        assertion: BackgroundExecutionAssertion
    ) async {
        var receipt: ExecutionReceipt?
        var observations: [PhraseObservation] = []
        var fullySucceeded = false
        let progress = ExecutionProgressReporter { [weak self] stage in
            Task { @MainActor [weak self] in
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
            let result = await PhraseWriteExecutor(api: api).execute(
                displayedSnapshot: displayed,
                approval: intent.approval,
                control: control,
                progress: progress
            )
            if let terminalError = result.terminalError {
                if !result.results.isEmpty {
                    receipt = appendPhraseReceipt(displayed: displayed, result: result)
                }
                handleSessionFailure(terminalError)
                errorMessage = terminalError.description
            } else if result.stalePreview {
                errorMessage = CompanionError.stalePreview.description
            } else {
                receipt = appendPhraseReceipt(displayed: displayed, result: result)
                observations = result.results.flatMap(\.observations)
                fullySucceeded = result.isFullSuccess
                if result.failed > 0 {
                    errorMessage = CompanionError.uncertainWriteOutcome.description
                } else if result.cancelled {
                    errorMessage = CompanionError.cancelled.description
                }
            }
        } catch let error as CompanionError {
            errorMessage = error.description
        } catch {
            errorMessage = CompanionError.responseRejected.description
        }

        assertion.end()
        activeControl = nil
        isBusy = false
        isExecuting = false
        executionStage = nil
        invalidatePreview()

        if let receipt, fullySucceeded {
            let localHistoryError = historyErrorMessage
            sourceText = ""
            completionAcknowledgement = "已完成 \(receipt.succeeded) 条例句 · 新建 \(receipt.succeeded)"
            phraseObservationMessage = phraseObservationSummary(observations)
            historyErrorMessage = localHistoryError
        } else if let receipt {
            hasExecutionFeedback = true
            finalSummary = FinalSummary(
                created: receipt.succeeded,
                updated: 0,
                alreadyMatching: 0,
                failed: receipt.failed,
                notAttempted: receipt.notAttempted,
                stopped: true
            )
        }

        if owesBackgroundTeardown {
            owesBackgroundTeardown = false
            clearTransientCredential(preservingPreviewPresentation: true)
        }
    }

    /// Runs the whole approved plan: CREATE phase, then UPDATE phase, with no
    /// second user gesture between them.
    @discardableResult
    func executeConfirmedWholePlan() -> Task<Void, Never>? {
        guard !isBusy else { return nil }
        let intent = consumeArmedBatchApproval()
        guard let displayed = snapshot,
              let currentSessionID = sessionID,
              let intent,
              intent.sessionID == currentSessionID
        else {
            errorMessage = CompanionError.approvalRequired.description
            return nil
        }
        do {
            guard intent.approval
                == (try ConfirmationBinding.makeBatchApproval(snapshot: displayed))
            else {
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
        // Visible immediately, before the first await. The whole-batch preflight
        // that follows is a real network pass over every approved item; it is only
        // its *presentation* that is collapsed to one compact stage.
        executionStage = .securing
        errorMessage = nil
        historyErrorMessage = nil
        let control = ExecutionControl()
        activeControl = control

        // One finite assertion for the whole orchestration. The UPDATE phase does
        // not lose protection merely because CREATE handed over to it.
        let assertion = backgroundAssertionFactory()
        assertion.begin(reason: "momo-interpretation-write-plan") {
            control.requestCancellation()
        }

        return Task {
            await executeAuthorizedPlan(
                displayed: displayed,
                intent: intent,
                control: control,
                assertion: assertion
            )
        }
    }

    private func executeAuthorizedPlan(
        displayed: PreviewSnapshot,
        intent: ArmedBatchApprovalIntent,
        control: ExecutionControl,
        assertion: BackgroundExecutionAssertion
    ) async {
        var receipts: [ExecutionReceipt] = []
        var fullySucceeded = false
        let progress = ExecutionProgressReporter { [weak self] stage in
            Task { @MainActor [weak self] in
                guard let self, self.isExecuting else { return }
                self.executionStage = stage
            }
        }
        do {
            let lease = try credentialSession.makeOperationLease()
            defer { lease.clear() }
            // One transport for the whole run, so pacing carries across phases.
            let api = MaimemoTransport(
                transport: transportFactory(),
                credential: lease,
                sleeper: sleeperFactory()
            )
            let result = await WriteExecutor(api: api).executeBatchPlan(
                displayedSnapshot: displayed,
                approval: intent.approval,
                control: control,
                progress: progress
            )
            if case let .globalFailure(terminalError) = result.outcome {
                if !result.phases.isEmpty {
                    receipts = recordBatchExecution(
                        displayed: displayed,
                        plannedPhases: intent.approval.phases.map(\.group),
                        result: result
                    )
                }
                handleSessionFailure(terminalError)
                errorMessage = terminalError.description
            } else if result.outcome == .stale {
                errorMessage = CompanionError.stalePreview.description
            } else {
                receipts = recordBatchExecution(
                    displayed: displayed,
                    plannedPhases: intent.approval.phases.map(\.group),
                    result: result
                )
                fullySucceeded = result.isFullSuccess
                errorMessage = batchErrorMessage(for: result)
            }
        } catch let error as CompanionError {
            if control.isCancellationRequested, let first = intent.approval.phases.first {
                receipts = recordBatchExecution(
                    displayed: displayed,
                    plannedPhases: intent.approval.phases.map(\.group),
                    result: BatchRunResult(
                        outcome: .stoppedBeforeRemainingPhase(
                            group: first.group,
                            reason: .interrupted
                        ),
                        phases: []
                    )
                )
            } else {
                errorMessage = error.description
            }
        } catch {
            errorMessage = CompanionError.responseRejected.description
        }
        assertion.end()
        activeControl = nil
        isBusy = false
        isExecuting = false
        executionStage = nil
        invalidatePreview()
        if !receipts.isEmpty,
           let document = recoverableSourceDocument(
               after: receipts,
               plannedPhases: intent.approval.phases.map(\.group),
               in: displayed,
               fullySucceeded: fullySucceeded
           ) {
            // Replacing the draft detaches the inline feedback, which is right for
            // a fresh start but must not erase the outcome of the run that just
            // produced this remainder.
            let carried = (
                historyError: historyErrorMessage,
                error: errorMessage,
                hasFeedback: hasExecutionFeedback,
                summary: finalSummary
            )
            sourceText = document
            historyErrorMessage = carried.historyError
            errorMessage = carried.error
            hasExecutionFeedback = carried.hasFeedback
            finalSummary = carried.summary
        }
        if fullySucceeded, !receipts.isEmpty {
            completionAcknowledgement = acknowledgement(forBatch: receipts)
        }
        if owesBackgroundTeardown {
            owesBackgroundTeardown = false
            clearTransientCredential(preservingPreviewPresentation: true)
        }
    }

    /// Receipts stay per phase, so CREATE and UPDATE remain distinguishable in
    /// History even though the Owner initiated one run. A phase that never
    /// started gets no receipt at all — there is never a fake success.
    private func recordBatchExecution(
        displayed: PreviewSnapshot,
        plannedPhases: [OperationGroup],
        result: BatchRunResult
    ) -> [ExecutionReceipt] {
        var receipts = result.phases.map {
            appendReceipt(group: $0.group, displayed: displayed, result: $0)
        }
        if case let .stoppedBeforeRemainingPhase(group, reason) = result.outcome,
           reason == .interrupted,
           result.phases.isEmpty {
            // Interrupted before the first phase could start: the existing
            // all-items-not-attempted receipt, unchanged.
            receipts = [
                appendReceipt(
                    group: group,
                    displayed: displayed,
                    result: cancelledSummary(for: group)
                ),
            ]
        }

        let created = receipts.first { $0.operationGroup == .create }?.succeeded ?? 0
        let updated = receipts.first { $0.operationGroup == .update }?.succeeded ?? 0
        let attempted = Set(receipts.map(\.operationGroup))
        let neverStarted = plannedPhases
            .filter { !attempted.contains($0) }
            .reduce(0) { $0 + displayed.items(for: $1).count }
        let fullySucceeded = result.isFullSuccess && neverStarted == 0

        if fullySucceeded {
            hasExecutionFeedback = false
            finalSummary = FinalSummary()
        } else {
            hasExecutionFeedback = true
            finalSummary = FinalSummary(
                created: created,
                updated: updated,
                alreadyMatching: 0,
                failed: receipts.reduce(0) { $0 + $1.failed },
                notAttempted: receipts.reduce(0) { $0 + $1.notAttempted } + neverStarted,
                stopped: true
            )
        }
        return receipts
    }

    private func batchErrorMessage(for result: BatchRunResult) -> String? {
        if case let .globalFailure(error) = result.outcome { return error.description }
        if case let .stoppedBeforeRemainingPhase(_, reason) = result.outcome {
            switch reason {
            case .remainingPhaseChanged:
                return CompanionError.remainingPhaseChanged.description
            case .interrupted:
                return result.phases.isEmpty ? nil : CompanionError.cancelled.description
            case .earlierPhaseIncomplete:
                break
            }
        }
        return result.phases.contains { $0.failed > 0 }
            ? CompanionError.uncertainWriteOutcome.description
            : nil
    }

    /// What may safely be left in the editor for a later, freshly previewed
    /// attempt.
    ///
    /// `nil` leaves the draft exactly as the Owner typed it. Trimming happens only
    /// where an earlier phase committed completely, so nothing that might still be
    /// pending is ever dropped.
    private func recoverableSourceDocument(
        after receipts: [ExecutionReceipt],
        plannedPhases: [OperationGroup],
        in displayed: PreviewSnapshot,
        fullySucceeded: Bool
    ) -> String? {
        let blocked = displayed.items
            .filter { $0.classification == .blocked }
            .map(\.entry)
        if fullySucceeded {
            return BatchParser.canonicalDocument(for: blocked)
        }
        let firstIncomplete = plannedPhases.firstIndex { group in
            receipts.first { $0.operationGroup == group }?.isFullSuccess != true
        }
        guard let firstIncomplete, firstIncomplete > 0 else { return nil }
        let remaining = (
            plannedPhases[firstIncomplete...]
                .flatMap { displayed.items(for: $0).map(\.entry) }
                + blocked
        )
            .sorted { $0.ordinal < $1.ordinal }
        return BatchParser.canonicalDocument(for: remaining)
    }

    private func acknowledgement(forBatch receipts: [ExecutionReceipt]) -> String {
        guard receipts.count > 1 else {
            return receipts.first.map { acknowledgement(for: $0) } ?? ""
        }
        let created = receipts.first { $0.operationGroup == .create }?.succeeded ?? 0
        let updated = receipts.first { $0.operationGroup == .update }?.succeeded ?? 0
        return "已完成 \(created + updated) 条 · 新建 \(created) · 更新 \(updated)"
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
        executionStage = .securing
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
            if let terminalError = result.terminalError {
                if !result.results.isEmpty {
                    completedReceipt = recordExecution(
                        group: group,
                        displayed: displayed,
                        result: result
                    )
                }
                handleSessionFailure(terminalError)
                errorMessage = terminalError.description
            } else if result.stalePreview {
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
    private func appendReceipt(
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
        return receipt
    }

    @discardableResult
    private func appendPhraseReceipt(
        displayed: PhrasePreviewSnapshot,
        result: PhraseExecutionSummary
    ) -> ExecutionReceipt {
        let selectedSpellings = displayed.items
            .filter { $0.classification == .create }
            .map(\.entry.spelling)
        let receipt = ExecutionReceipt(
            timestamp: dateProvider(),
            selectedSpellings: selectedSpellings,
            result: result
        )
        history.insert(receipt, at: 0)
        do {
            try historyStore.saveReceipts(history)
        } catch {
            historyErrorMessage = "历史记录保存失败"
        }
        return receipt
    }

    @discardableResult
    private func recordExecution(
        group: OperationGroup,
        displayed: PreviewSnapshot,
        result: ExecutionSummary
    ) -> ExecutionReceipt {
        let receipt = appendReceipt(group: group, displayed: displayed, result: result)
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

    var isShowingEditor: Bool {
        contentMode == .interpretation ? preview == nil : phrasePreview == nil
    }

    var canSwitchMode: Bool { !isBusy }

    func selectMode(_ mode: ContentMode) {
        guard canSwitchMode, mode != contentMode else { return }
        invalidatePreview()
        detachInlineExecutionFeedback()
        contentMode = mode
        sourceText = mode == .interpretation ? interpretationDraft : phraseDraft
        updateLocalParseState()
    }

    var availableWriteTags: [String] { WriteTagPreference.availableTags }

    var selectedTagsSummary: String {
        "标签：" + WriteTagPreference.compactLabel(selectedTags)
    }

    func isTagSelected(_ tag: String) -> Bool { selectedTags.contains(tag) }

    func canToggleTag(_ tag: String) -> Bool {
        WriteTagPreference.availableTags.contains(tag)
            && (isTagSelected(tag)
                || selectedTags.count < WriteTagPreference.maximumSelectionCount)
    }

    func toggleTag(_ tag: String) {
        guard !isBusy, WriteTagPreference.availableTags.contains(tag) else { return }
        var proposed = selectedTags
        if let index = proposed.firstIndex(of: tag) {
            proposed.remove(at: index)
        } else {
            guard proposed.count < WriteTagPreference.maximumSelectionCount else { return }
            proposed.append(tag)
        }
        do {
            let saved = try WriteTagPreference.save(proposed, to: preferenceDefaults)
            guard saved != selectedTags else { return }
            selectedTags = saved
            detachInlineExecutionFeedback()
            invalidatePreview()
        } catch {
            errorMessage = CompanionError.inputRejected.description
        }
    }

    var previewHeader: String? {
        if contentMode == .phrase {
            guard let rows = phrasePreview?.rows,
                  let first = rows.first?.spelling,
                  let last = rows.last?.spelling
            else { return nil }
            return "\(rows.count) 条例句 · \(first) → \(last)"
        }
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
        guard contentMode == .interpretation else { return [] }
        guard let snapshot,
              preview != nil,
              !isPreviewStale,
              isConnected
        else { return [] }
        let counts = snapshot.presentation.counts
        // A mixed actionable batch offers exactly one primary action covering the
        // whole displayed plan (#76). Single-group batches keep the original
        // controls unchanged and gain no extra step.
        if counts.create > 0, counts.update > 0 {
            return [ExecutionAction(createCount: counts.create, updateCount: counts.update)]
        }
        return [
            ExecutionAction(group: .create, count: counts.create),
            ExecutionAction(group: .update, count: counts.update),
        ]
    }

    var canExecutePhrase: Bool {
        guard contentMode == .phrase,
              let phraseSnapshot,
              phrasePreview != nil,
              !isPreviewStale,
              isConnected,
              !isBusy
        else { return false }
        return phraseSnapshot.createCount > 0 && phraseSnapshot.blockedCount == 0
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

    func toggleDetails(for row: PhrasePreviewRow) {
        if expandedRowIDs.contains(row.id) {
            expandedRowIDs.remove(row.id)
        } else {
            expandedRowIDs.insert(row.id)
        }
    }

    func details(for row: PreviewRow) -> PreviewRowDetails? {
        guard row.canExpand, expandedRowIDs.contains(row.id) else { return nil }
        return PreviewRowDetails(
            current: row.current,
            proposed: row.proposed,
            currentTags: row.currentTags,
            proposedTags: row.proposedTags
        )
    }

    private func invalidatePreview() {
        preview = nil
        phrasePreview = nil
        expandedRowIDs.removeAll()
        invalidateExecutionAuthorization()
    }

    private func invalidateExecutionAuthorization() {
        snapshot = nil
        phraseSnapshot = nil
        // A source edit, token change or explicit invalidation also discards any
        // Preview held aside across an interruption.
        suspendedPreview = nil
        isPreviewStale = activePreviewExists
        invalidateArmedApproval()
    }

    private func invalidatePreviewAfterRefreshFailure(preservingStalePresentation: Bool) {
        if preservingStalePresentation, activePreviewExists {
            invalidateExecutionAuthorization()
        } else {
            invalidatePreview()
        }
    }

    private func invalidateArmedApproval() {
        armedApproval = nil
        pendingConfirmation = nil
        armedBatchApproval = nil
        pendingBatchConfirmation = nil
        armedPhraseApproval = nil
        pendingPhraseConfirmation = nil
    }

    private func consumeArmedApproval() -> ArmedApprovalIntent? {
        let intent = armedApproval
        invalidateArmedApproval()
        return intent
    }

    private func consumeArmedBatchApproval() -> ArmedBatchApprovalIntent? {
        let intent = armedBatchApproval
        invalidateArmedApproval()
        return intent
    }

    private func consumeArmedPhraseApproval() -> ArmedPhraseApprovalIntent? {
        let intent = armedPhraseApproval
        invalidateArmedApproval()
        return intent
    }

    private func updateLocalParseState() {
        guard !sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            localParseState = .empty
            return
        }
        do {
            let spellings: [String]
            switch contentMode {
            case .interpretation:
                spellings = try BatchParser.parseDailyInput(sourceText).entries.map(\.spelling)
            case .phrase:
                spellings = try PhraseBatchParser.parse(sourceText).map(\.spelling)
            }
            guard let first = spellings.first,
                  let last = spellings.last
            else {
                localParseState = .invalid
                return
            }
            localParseState = .valid(count: spellings.count, first: first, last: last)
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
        phraseObservationMessage = nil
    }

    private func storeActiveDraft(_ document: String) {
        switch contentMode {
        case .interpretation: interpretationDraft = document
        case .phrase: phraseDraft = document
        }
    }

    private var activePreviewExists: Bool {
        contentMode == .interpretation ? preview != nil : phrasePreview != nil
    }

    private func phraseObservationSummary(_ observations: [PhraseObservation]) -> String? {
        guard !observations.isEmpty else { return nil }
        let unique = Set(observations.map(\.rawValue))
        // Stable and deviation-first within each observation family. Emitting
        // every distinct closed observation prevents one successful item from
        // hiding another item's missing or differing tags/highlight.
        let ordered: [(PhraseObservation, String)] = [
            (.tagsDiffer, "标签与请求不同"),
            (.tagsMissing, "标签未返回"),
            (.tagsMatchRequested, "标签已匹配"),
            (.highlightOtherReviewedRange, "英文高亮为其他已审阅范围"),
            (.highlightMissing, "英文高亮未返回"),
            (.highlightEmpty, "英文高亮为空"),
            (.highlightExactTarget, "英文高亮准确"),
            (.chineseRangeUnavailable, "中文范围在 documented API 中不可用"),
        ]
        let parts = ordered.compactMap { observation, label in
            unique.contains(observation.rawValue) ? label : nil
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        let remainingEntries = (
            displayed.items(for: remainingGroup).map(\.entry)
                + displayed.items.filter { $0.classification == .blocked }.map(\.entry)
        ).sorted { $0.ordinal < $1.ordinal }
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

    private func restoreCredentialIfAvailable() async {
        guard !credentialSession.isConnected, !isValidatingCredential else { return }
        isValidatingCredential = true
        defer { isValidatingCredential = false }
        do {
            guard var token = try tokenStore.loadToken() else {
                isConnected = false
                return
            }
            defer { token.removeAll(keepingCapacity: false) }
            let candidate = try InMemoryCredential(token: token)
            do {
                try await validateCredential(candidate)
            } catch {
                candidate.clear()
                throw error
            }
            credentialSession.replace(with: candidate)
            sessionID = UUID()
            isConnected = true
            if tokenErrorMessage == nil { errorMessage = nil }
        } catch let error as CompanionError {
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            if tokenErrorMessage == nil { errorMessage = error.description }
        } catch {
            credentialSession.disconnect()
            sessionID = nil
            isConnected = false
            if tokenErrorMessage == nil {
                errorMessage = CompanionError.credentialStorageUnavailable.description
            }
        }
    }

    private func validateCredential(_ candidate: InMemoryCredential) async throws {
        let lease = try candidate.makeOperationLease()
        defer { lease.clear() }
        let api = MaimemoTransport(
            transport: credentialValidationTransportFactory(),
            credential: lease,
            sleeper: sleeperFactory()
        )
        try await api.validateCredential()
    }

    private func credentialCandidateMessage(for error: CompanionError) -> String {
        switch error {
        case .credentialRejected:
            return "Token 格式无效；请检查后重试。"
        case .authenticationRejected:
            return "这个 Token 未通过墨墨验证；未保存，请检查后重试。"
        case .transport:
            return "无法连接墨墨验证 Token；请检查网络后重试。"
        case .rateLimited:
            return "墨墨请求过于频繁，暂时无法验证 Token；请稍后重试。"
        case .serverFailure, .globalHTTPFailure, .responseRejected:
            return "墨墨暂时无法安全验证 Token；候选 Token 未保存。"
        default:
            return error.description
        }
    }

    private func handleSessionFailure(_ error: CompanionError) {
        guard error == .authenticationRejected else { return }
        credentialSession.disconnect()
        sessionID = nil
        isConnected = false
        invalidateExecutionAuthorization()
    }

    nonisolated var debugDescription: String { "CompanionViewModel(<redacted credential>)" }

    var hasExecutablePreview: Bool {
        contentMode == .interpretation ? snapshot != nil : phraseSnapshot != nil
    }
}
