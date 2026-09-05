import Foundation

/// The whole state machine for batch Query (#161).
///
/// Scope: **app/process session, above the Query destination.** It is created
/// once at the app root, not as a `@StateObject` on the Query screen, so
/// Home → 批量查阅 within the same process and the same credential identity
/// restores the previous result, filter and scroll position with no network.
/// It is memory-only by design: relaunching the app starts empty, and no Query
/// state is ever persisted.
///
/// What it owns: the input text, the parse, the request budget, the rows and
/// per-cell truth, the run phase, the local filter, the scroll anchor, the
/// modify-flow return flag, and the run generation.
///
/// What it deliberately does not own: Keychain access, a `CredentialSession`, a
/// `RequestWindowScheduler`, a transport factory, or any write authority. All of
/// that arrives, per run, through the narrow `QueryReadLease` the root
/// `CompanionViewModel` hands out.
@MainActor
final class QuerySessionStore: ObservableObject {

    /// A running interrupt the Owner has to answer before leaving or editing.
    enum PendingInterrupt: Equatable {
        case modify
        case back
    }

    // MARK: - Input

    @Published private(set) var inputText = ""
    /// `nil` means the current text is malformed.
    @Published private(set) var parse: QueryInputParse?
    @Published private(set) var budget = QueryRequestBudget.estimate(uniqueInputCount: 0)

    // MARK: - Result

    @Published private(set) var phase: QueryRunPhase = .input
    @Published private(set) var rows: [QueryRow] = []
    @Published private(set) var filter: QueryFilter = .none
    @Published var scrollAnchor: Int?
    @Published private(set) var pendingInterrupt: PendingInterrupt?
    /// Set after a real account identity change until the next successful start.
    @Published private(set) var accountChangedBanner = false
    /// True while `修改` can still return to the untouched previous result.
    @Published private(set) var returnableResult = false

    /// The account identity this result belongs to. Truth produced under one
    /// identity is never shown under another.
    private(set) var sessionIdentity = AccountIdentity.disconnected
    private var details: [String: QueryRowDetail] = [:]

    /// Monotonic run identity. Every state mutation an in-flight read wants to
    /// make is checked against this first, so a late response belonging to a
    /// stopped or superseded run can never touch a newer result.
    private var runGeneration = 0
    private var activeControl: ExecutionControl?
    private var activeTask: Task<Void, Never>?
    /// Set once the resolver stage has completed for the current result, so
    /// 继续查阅 knows whether it must run that atomic stage again.
    private var resolverCompleted = false

    init() {}

    /// Awaits the in-flight run so a headless test can assert terminal state
    /// without polling. Production never calls this: the UI observes `phase`.
    func awaitRunCompletion() async {
        await activeTask?.value
    }

    // MARK: - Derived presentation

    var visibleRows: [QueryRow] { filter.apply(to: rows) }
    var matchCount: Int { visibleRows.count }
    var totalRowCount: Int { rows.count }

    var completedRowCount: Int {
        rows.count { !$0.hasUnfinishedCells }
    }

    var unfinishedRowCount: Int { rows.count - completedRowCount }

    var hasUnfinishedWork: Bool {
        rows.contains { $0.hasUnfinishedCells }
    }

    var canStart: Bool {
        guard let parse, !parse.isEmpty else { return false }
        return !phase.isRunning
    }

    /// `查阅 N 项` counts the rows the Owner typed, not the deduplicated set.
    var startActionCount: Int { parse?.visibleCount ?? 0 }

    var isMalformedInput: Bool {
        parse == nil && !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Only the inability reasons actually present in this batch may be offered
    /// as filter narrowing.
    var presentInabilityReasons: [QueryInabilityReason] {
        let present = rows.reduce(into: Set<QueryInabilityReason>()) {
            $0.formUnion($1.inabilityReasons)
        }
        return QueryInabilityReason.allCases.filter(present.contains)
    }

    var copyPayload: String {
        visibleRows.map(\.spelling).joined(separator: "\n")
    }

    func detail(forRowID ordinal: Int) -> QueryRowDetail? {
        guard let row = rows.first(where: { $0.id == ordinal }) else { return nil }
        return details[row.input.normalized] ?? QueryRowDetail()
    }

    func row(withID ordinal: Int) -> QueryRow? {
        rows.first { $0.id == ordinal }
    }

    // MARK: - Input editing

    func updateInput(_ text: String) {
        guard text != inputText else { return }
        inputText = text
        reparse()
        // Q-28: the first real edit after 修改 invalidates the old result, which
        // no longer describes the source text.
        if returnableResult {
            returnableResult = false
            discardResult()
        }
    }

    private func reparse() {
        parse = QueryInputParser.parseForDisplay(inputText)
        budget = QueryRequestBudget.estimate(uniqueInputCount: parse?.uniqueCount ?? 0)
    }

    // MARK: - Modify / return (Q-24, Q-27, Q-28)

    /// `修改` on a completed or stopped result: go back to the input phase with
    /// the original text, keeping the result returnable until the first edit.
    func beginModify() {
        guard phase.hasResult, !phase.isRunning else { return }
        returnableResult = true
        phase = .input
    }

    /// `返回结果`: the text was never actually edited, so the exact same result,
    /// filter and scroll position come back with no network.
    func returnToResult() {
        guard returnableResult, !rows.isEmpty else { return }
        returnableResult = false
        phase = restoredPhase()
    }

    private func restoredPhase() -> QueryRunPhase {
        hasUnfinishedWork ? .stopped(lastStopReason ?? .userStopped) : .completed
    }

    private var lastStopReason: QueryStopReason?

    // MARK: - Filtering

    func setFilter(_ newFilter: QueryFilter) {
        let changed = newFilter != filter
        filter = newFilter
        // Q-17: a changed filter returns to the top; an unchanged one keeps the
        // Owner's position.
        if changed { scrollAnchor = nil }
    }

    func resetFilter() {
        setFilter(.none)
    }

    // MARK: - Account identity (Q-37)

    /// Called with the root owner's current `AccountIdentity` whenever it
    /// changes.
    ///
    /// Only a **real** identity change clears account-derived truth: an explicit
    /// successful connect, replacement or removal. A transient background
    /// suspension, a foreground restore of the same Token, a failed candidate,
    /// and a 401 all leave the identity untouched and therefore reach this as a
    /// no-op.
    func handleAccountIdentityChange(to identity: AccountIdentity) {
        guard identity != sessionIdentity else { return }
        let hadResult = phase.hasResult || !rows.isEmpty
        stopDispatching()
        resetAccountDerivedTruth()
        sessionIdentity = identity
        // The banner is only meaningful when there was truth to clear.
        accountChangedBanner = hadResult
    }

    /// Clears everything derived from the account, and **preserves the Owner's
    /// input text** so they can simply run it again under the new identity.
    private func resetAccountDerivedTruth() {
        rows = []
        details = [:]
        filter = .none
        scrollAnchor = nil
        phase = .input
        returnableResult = false
        resolverCompleted = false
        lastStopReason = nil
        pendingInterrupt = nil
        runGeneration &+= 1
    }

    private func discardResult() {
        rows = []
        details = [:]
        filter = .none
        scrollAnchor = nil
        phase = .input
        resolverCompleted = false
        lastStopReason = nil
        runGeneration &+= 1
    }

    // MARK: - Interrupts (Q-25, Q-26, Q-29, Q-30b)

    func requestInterrupt(_ interrupt: PendingInterrupt) {
        guard phase.isRunning else { return }
        pendingInterrupt = interrupt
    }

    /// `继续查阅` on an interrupt dialog: dismiss and keep reading.
    func dismissInterrupt() {
        pendingInterrupt = nil
    }

    /// `停止并修改` / `停止并返回`: stop dispatching, keep completed truth, then
    /// let the caller navigate.
    func resolveInterrupt(_ interrupt: PendingInterrupt) {
        pendingInterrupt = nil
        stop(reason: .userStopped)
        if interrupt == .modify { beginModify() }
    }

    // MARK: - Stop

    /// `停止`. Undispatched reads are cancelled, completed cells stay truthful,
    /// unfinished cells become 未读, and nothing is ever retried automatically.
    func stop(reason: QueryStopReason = .userStopped) {
        guard phase.isRunning else { return }
        stopDispatching()
        markUnfinishedAsUnread()
        lastStopReason = reason
        phase = .stopped(reason)
    }

    private func stopDispatching() {
        activeControl?.requestCancellation()
        activeControl = nil
        activeTask?.cancel()
        activeTask = nil
        // Supersede the run so any response still in flight cannot apply.
        runGeneration &+= 1
    }

    private func markUnfinishedAsUnread() {
        for index in rows.indices {
            for family in QueryContentFamily.allCases where !rows[index].cell(family).isTerminal {
                rows[index].cells[family] = .unread
            }
        }
    }

    // MARK: - Run

    /// `查阅 N 项`: a fresh run over the current input.
    func start(lease: QueryReadLease) {
        guard let parse, !parse.isEmpty, !phase.isRunning else {
            lease.finish()
            return
        }
        accountChangedBanner = false
        returnableResult = false
        sessionIdentity.fingerprint = lease.credentialFingerprint
        details = [:]
        filter = .none
        scrollAnchor = nil
        lastStopReason = nil
        resolverCompleted = false
        rows = parse.inputs.map(QueryRow.init)
        run(lease: lease, resumingOnly: false)
    }

    /// `继续查阅 · 其余 M 项`: reads only what never reached a truthful terminal
    /// state. Completed cells are never re-read, and an already-unavailable cell
    /// is never auto-retried.
    func resume(lease: QueryReadLease) {
        guard phase.hasResult, !phase.isRunning, hasUnfinishedWork,
              lease.credentialFingerprint == sessionIdentity.fingerprint
        else {
            lease.finish()
            return
        }
        accountChangedBanner = false
        lastStopReason = nil
        run(lease: lease, resumingOnly: true)
    }

    private func run(lease: QueryReadLease, resumingOnly: Bool) {
        runGeneration &+= 1
        let generation = runGeneration
        let control = ExecutionControl()
        activeControl = control
        phase = resolverCompleted ? .reading : .resolving

        activeTask = Task { [weak self] in
            await self?.execute(
                generation: generation,
                lease: lease,
                control: control,
                resumingOnly: resumingOnly
            )
            lease.finish()
        }
    }

    /// The sequential, row-major read loop. Exactly one request is in flight at
    /// a time; there is no concurrency anywhere in Query.
    private func execute(
        generation: Int,
        lease: QueryReadLease,
        control: ExecutionControl,
        resumingOnly: Bool
    ) async {
        let runner = QueryReadRunner(api: lease.api)

        // 1. Resolver stage — atomic. Skipped only when it already completed for
        //    this result; otherwise an explicit continue runs it again in full.
        if !resolverCompleted {
            let spellings = uniqueSpellingsInRowOrder()
            do {
                let resolution = try await runner.resolve(
                    spellings: spellings,
                    control: control
                )
                guard isCurrent(generation) else { return }
                applyResolution(resolution, requested: spellings)
                resolverCompleted = true
                phase = .reading
            } catch let error as CompanionError where error.abortsReadPlan {
                guard isCurrent(generation) else { return }
                finishWithGlobalFailure(error)
                return
            } catch {
                // Cancelled, or interrupted before the stage completed: no
                // durable resolver truth, so nothing is recorded.
                return
            }
        } else if isCurrent(generation) {
            phase = .reading
        }

        // 2. Content reads — row-major, one atomic cell at a time.
        for normalized in uniqueNormalizedInRowOrder() {
            guard isCurrent(generation), !control.isCancellationRequested else { return }
            guard let vocabularyID = vocabularyID(forNormalized: normalized) else { continue }

            for family in QueryContentFamily.allCases {
                guard isCurrent(generation), !control.isCancellationRequested else { return }
                // A cell that already reached a truthful terminal state is never
                // re-read, and an unavailable one never auto-retries.
                guard !cellIsTerminal(normalized: normalized, family: family) else { continue }

                setCell(.loading, normalized: normalized, family: family)
                do {
                    let outcome = try await runner.readCell(
                        family,
                        vocabularyID: vocabularyID,
                        control: control
                    )
                    guard isCurrent(generation) else { return }
                    setCell(outcome.state, normalized: normalized, family: family)
                    mergeDetail(outcome.detail, family: family, normalized: normalized)
                } catch let error as CompanionError where error.abortsReadPlan {
                    guard isCurrent(generation) else { return }
                    // The cell that was mid-flight goes back to unfinished, not
                    // to a wrong value.
                    setCell(.queued, normalized: normalized, family: family)
                    finishWithGlobalFailure(error)
                    return
                } catch {
                    guard isCurrent(generation) else { return }
                    setCell(.queued, normalized: normalized, family: family)
                    return
                }
            }
        }

        guard isCurrent(generation) else { return }
        activeControl = nil
        phase = .completed
    }

    // MARK: - Run helpers

    private func isCurrent(_ generation: Int) -> Bool { generation == runGeneration }

    private func finishWithGlobalFailure(_ error: CompanionError) {
        activeControl?.requestCancellation()
        activeControl = nil
        markUnfinishedAsUnread()
        let reason = QueryStopReason.globalFailure(error)
        lastStopReason = reason
        phase = .stopped(reason)
        runGeneration &+= 1
    }

    private func uniqueSpellingsInRowOrder() -> [String] {
        var seen = Set<String>()
        return rows.compactMap { row in
            seen.insert(row.input.normalized).inserted ? row.input.spelling : nil
        }
    }

    private func uniqueNormalizedInRowOrder() -> [String] {
        var seen = Set<String>()
        return rows.compactMap { row in
            seen.insert(row.input.normalized).inserted ? row.input.normalized : nil
        }
    }

    private func applyResolution(
        _ resolution: VocabularyResolution,
        requested: [String]
    ) {
        var outcomeByNormalized: [String: VocabularyTargetOutcome] = [:]
        for (index, spelling) in requested.enumerated()
        where resolution.outcomes.indices.contains(index) {
            outcomeByNormalized[BatchParser.normalizeSpelling(spelling)] =
                resolution.outcomes[index]
        }
        for index in rows.indices {
            guard let outcome = outcomeByNormalized[rows[index].input.normalized] else {
                continue
            }
            switch outcome {
            case let .resolved(vocabularyID):
                rows[index].vocabularyID = vocabularyID
                rows[index].rowInability = nil
            case let .blocked(failure):
                // A whole-row inability: every cell carries the same reason, and
                // none of them is a zero.
                let reason = QueryInabilityReason(resolutionFailure: failure)
                rows[index].vocabularyID = nil
                rows[index].rowInability = reason
                for family in QueryContentFamily.allCases {
                    rows[index].cells[family] = .unavailable(reason)
                }
            }
        }
    }

    private func vocabularyID(forNormalized normalized: String) -> String? {
        rows.first { $0.input.normalized == normalized }?.vocabularyID
    }

    private func cellIsTerminal(normalized: String, family: QueryContentFamily) -> Bool {
        rows.first { $0.input.normalized == normalized }?.cell(family).isTerminal ?? true
    }

    /// Applies one cell result to **every** visible row naming that word, so a
    /// duplicated input costs one read and still shows the same truth twice.
    private func setCell(
        _ state: QueryCellState,
        normalized: String,
        family: QueryContentFamily
    ) {
        for index in rows.indices where rows[index].input.normalized == normalized {
            rows[index].cells[family] = state
        }
    }

    /// Records the already-returned objects for exactly the family that was
    /// just read, so a confirmed zero empties that section rather than leaving
    /// stale content behind it.
    private func mergeDetail(
        _ detail: QueryRowDetail,
        family: QueryContentFamily,
        normalized: String
    ) {
        var existing = details[normalized] ?? QueryRowDetail()
        switch family {
        case .interpretation: existing.interpretations = detail.interpretations
        case .phrase: existing.phrases = detail.phrases
        case .note: existing.notes = detail.notes
        }
        details[normalized] = existing
    }
}
