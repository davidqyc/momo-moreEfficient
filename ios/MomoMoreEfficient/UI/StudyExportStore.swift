import Foundation

/// The whole state machine for the 单词导出 surface (#155).
///
/// Memory-only by design, like `QuerySessionStore`: relaunching starts empty,
/// nothing is persisted, and switching presets simply replaces the one result.
/// There is no history, no filter and no input to preserve.
///
/// What it deliberately does not own: Keychain access, a `CredentialSession`,
/// a scheduler, a transport factory, or any write authority. All of that
/// arrives, per run, through the same narrow read lease the root owner hands
/// to batch Query — the same `.query` provider-operation lane, so study reads
/// and Query reads can never overlap.
@MainActor
final class StudyExportStore: ObservableObject {

    /// A finished run's truthful presentation bundle.
    struct Failure: Equatable {
        let title: String
        let message: String
    }

    @Published private(set) var phase: Phase = .idle
    /// The account identity the current result belongs to. Truth produced
    /// under one identity is never shown under another.
    private(set) var sessionIdentity = AccountIdentity.disconnected

    enum Phase: Equatable {
        /// The preset list; nothing is in flight and no result is held.
        case idle
        case loading(StudyExportPreset)
        case completed(StudyExportPreset, StudyExportOutcome)
        case failed(StudyExportPreset, Failure)
    }

    private var runGeneration = 0
    private var activeControl: ExecutionControl?
    private var activeTask: Task<Void, Never>?
    private var lastDispatchedRunTask: Task<Void, Never>?
    private let dateProvider: () -> Date

    init(dateProvider: @escaping () -> Date = Date.init) {
        self.dateProvider = dateProvider
    }

    /// Awaits the last dispatched run so a headless test can assert terminal
    /// state without polling. Production never calls this.
    func awaitRunCompletion() async {
        await lastDispatchedRunTask?.value
    }

    var isRunning: Bool {
        if case .loading = phase { return true }
        return false
    }

    var activePreset: StudyExportPreset? {
        switch phase {
        case .idle: return nil
        case let .loading(preset): return preset
        case let .completed(preset, _): return preset
        case let .failed(preset, _): return preset
        }
    }

    /// The export payload: exactly one spelling per line, nothing else.
    /// `nil` whenever there is no completed result to copy.
    var copyPayload: String? {
        guard case let .completed(_, outcome) = phase else { return nil }
        return outcome.words.joined(separator: "\n")
    }

    var resultWordCount: Int? {
        guard case let .completed(_, outcome) = phase else { return nil }
        return outcome.words.count
    }

    // MARK: - Account identity

    /// Called with the root owner's current `AccountIdentity` whenever it
    /// changes. Only a real identity change — an explicit successful connect,
    /// replacement or removal — reaches here as a change, and it clears the
    /// account-derived export result. A background suspension, a foreground
    /// restore, a failed candidate and a 401 are not identity changes.
    func handleAccountIdentityChange(to identity: AccountIdentity) {
        guard identity != sessionIdentity else { return }
        stopDispatching()
        phase = .idle
        sessionIdentity = identity
    }

    // MARK: - Stop

    /// `停止` or leaving the page. In-flight reads stop, nothing is retried,
    /// and no partial list is ever presented as a result.
    func stop() {
        guard isRunning else { return }
        stopDispatching()
        phase = .idle
    }

    /// Back to the preset list, discarding the memory-only result. Only
    /// reachable from a finished phase, so no run can be abandoned here.
    func returnToPresetList() {
        guard !isRunning else { return }
        phase = .idle
    }

    private func stopDispatching() {
        activeControl?.requestCancellation()
        activeControl = nil
        activeTask?.cancel()
        activeTask = nil
        runGeneration &+= 1
    }

    // MARK: - Run

    /// Starts one preset. The caller mints the lease first (the same
    /// `beginQueryRead()` read seam Query uses); if this store cannot start,
    /// the lease is finished immediately so the lane is never held.
    func start(_ preset: StudyExportPreset, lease: QueryReadLease) {
        guard !isRunning else {
            lease.finish()
            return
        }
        runGeneration &+= 1
        let generation = runGeneration
        let control = ExecutionControl()
        activeControl = control
        phase = .loading(preset)

        let task = Task { [weak self] in
            await self?.execute(
                generation: generation,
                preset: preset,
                lease: lease,
                control: control
            )
            lease.finish()
        }
        activeTask = task
        lastDispatchedRunTask = task
    }

    private func execute(
        generation: Int,
        preset: StudyExportPreset,
        lease: QueryReadLease,
        control: ExecutionControl
    ) async {
        let runner = StudyExportRunner(api: lease.api)
        do {
            let outcome = try await runner.run(preset, control: control, now: dateProvider())
            guard generation == runGeneration else { return }
            phase = .completed(preset, outcome)
        } catch is CancellationError {
            unwindCancelled(generation: generation)
        } catch let error as CompanionError where error == .cancelled {
            unwindCancelled(generation: generation)
        } catch {
            guard generation == runGeneration else { return }
            if let companionError = error as? CompanionError,
               companionError == .authenticationRejected {
                // A 401 is the root session's credential being rejected, not a
                // study-export fact; report it to the one root owner.
                lease.reportAuthenticationRejection()
            }
            phase = .failed(preset, Self.failureMessage(for: error))
        }
    }

    /// A cancellation that was not the user's own stop (for example the system
    /// reclaiming background time) leaves no run behind: back to the preset
    /// list, with nothing presented as a result. A user stop or an identity
    /// change has already superseded this generation, making it a no-op there.
    private func unwindCancelled(generation: Int) {
        guard generation == runGeneration else { return }
        phase = .idle
    }

    private static func failureMessage(for error: Error) -> Failure {
        if let studyError = error as? StudyExportError {
            switch studyError {
            case let .recordCountMismatch(expected, read):
                return Failure(
                    title: "读取不完整",
                    message: "墨墨报告共 \(expected) 条记录，但分页读取只安全取得 \(read) 条唯一记录。"
                        + "可能是数据正在同步；稍后重试。"
                )
            case .paginationNotAdvancing:
                return Failure(
                    title: "无法证明读取完整",
                    message: "分页边界无法继续前进，当前公开接口不能安全取得全部学习词。"
                        + "这是墨墨公测接口的限制，不会重复读取。"
                )
            case .paginationBoundaryUnavailable:
                return Failure(
                    title: "无法证明读取完整",
                    message: "某一页最后一条记录缺少可用于翻页的下次复习时间，"
                        + "当前公开接口不能继续安全翻页。"
                )
            }
        }
        if let companionError = error as? CompanionError {
            switch companionError {
            case .authenticationRejected:
                return Failure(
                    title: "墨墨拒绝了当前 Token",
                    message: "请在设置中重新连接后再导出。"
                )
            case .rateLimited:
                return Failure(
                    title: "请求过于频繁",
                    message: "墨墨限制了请求频率，请稍后再试。"
                )
            case .transport:
                return Failure(
                    title: "网络请求失败",
                    message: "不会自动重试；请检查网络后重试。"
                )
            case .serverFailure, .globalHTTPFailure:
                return Failure(
                    title: "墨墨服务暂时不可用",
                    message: "请稍后重试。"
                )
            default:
                break
            }
        }
        return Failure(
            title: "读取失败",
            message: "墨墨返回的数据无法安全读取，不会展示可能错误的结果。"
        )
    }
}
