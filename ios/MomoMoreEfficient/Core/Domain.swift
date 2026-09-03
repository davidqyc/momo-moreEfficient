import Foundation

enum CompanionConstants {
    static let productionBaseURL = URL(string: "https://open.maimemo.com")!
    static let accountMode = "main"
    static let accountLabel = "主账号"
    static let status = "PUBLISHED"
    /// The provider's documented per-request maximum for the public batch
    /// vocabulary query. It is a transport chunk bound only: #164 removed the
    /// former artificial product-wide total-batch item cap, so a user batch is
    /// bounded by real input/content/write limits instead.
    static let vocabularyQueryChunkSize = 1_000
    static let maxInputBytes = 262_144
    static let maxInterpretationCharacters = 2_000
    static let maxTokenCharacters = 8_192
    static let pacingSeconds = 1.6
    static let writePolicy = "EXACTLY ONE POST PER ITEM / NO RETRY / IMMEDIATE READBACK"
}

/// The one shared interpretation/phrase write preference from Issue #92.
///
/// Tags are non-sensitive local preference data. The canonical catalog is the
/// documented intersection accepted by both write endpoints; no remote state,
/// credential state or History record participates in this preference.
enum WriteTagPreference {
    static let availableTags = [
        "小学", "初中", "高中", "四级", "六级", "专升本", "专四", "专八", "考研", "考博",
        "雅思", "托福", "托业", "新概念", "GRE", "MBA", "BEC", "GMAT", "SAT", "ACT",
        "法学", "医学",
    ]
    static let maximumSelectionCount = 3
    static let userDefaultsKey = "write-tag-preference-v1"

    static func canonicalized(_ tags: [String]) throws -> [String] {
        let selected = Set(tags)
        guard tags.count <= maximumSelectionCount,
              selected.count == tags.count,
              selected.isSubset(of: Set(availableTags))
        else {
            throw CompanionError.inputRejected
        }
        return availableTags.filter(selected.contains)
    }

    static func load(from defaults: UserDefaults) -> [String] {
        guard let stored = defaults.array(forKey: userDefaultsKey) as? [String],
              let canonical = try? canonicalized(stored)
        else {
            return []
        }
        return canonical
    }

    @discardableResult
    static func save(_ tags: [String], to defaults: UserDefaults) throws -> [String] {
        let canonical = try canonicalized(tags)
        defaults.set(canonical, forKey: userDefaultsKey)
        return canonical
    }

    static func compactLabel(_ tags: [String]) -> String {
        tags.isEmpty ? "无" : tags.joined(separator: " · ")
    }
}

enum ContentMode: String, CaseIterable, Equatable, Sendable {
    case interpretation
    case phrase

    var pickerLabel: String { self == .interpretation ? "释义" : "例句" }
    var navigationTitle: String { self == .interpretation ? "释义录入" : "例句录入" }
    var editorAccessibilityLabel: String {
        self == .interpretation ? "批次释义输入" : "批次例句输入"
    }
    var editorHint: String {
        self == .interpretation
            ? "单条格式：单词换行 n. 释义；支持 n. / v. / adj. / adv. / phr. 等词性"
            : "格式：单词 · 英文例句 · 中文翻译 · 来源（可选）"
    }
}

enum CompanionError: String, Error, Codable, Equatable, Sendable, CustomStringConvertible {
    case inputRejected
    case credentialRejected
    case notConnected
    case previewRequired
    case approvalRequired
    case stalePreview
    case blocked
    case cancelled
    case transport
    case authenticationRejected
    case rateLimited
    case serverFailure
    case globalHTTPFailure
    case responseRejected
    case itemResponseRejected
    case uncertainWriteOutcome
    case previewInterrupted
    case credentialStorageUnavailable
    case remainingPhaseChanged

    var description: String {
        switch self {
        case .inputRejected:
            return "输入格式不符合要求。"
        case .credentialRejected:
            return "Token 输入无效；未连接。"
        case .notConnected:
            return "请先连接墨墨账号。"
        case .previewRequired:
            return "请先预览当前输入。"
        case .approvalRequired:
            return "请从当前预览重新发起原生确认；未发送写请求。"
        case .stalePreview:
            return "预览已失效；未发送写请求，请重新预览。"
        case .blocked:
            return "当前操作包含阻断项；未发送写请求。"
        case .cancelled:
            return "操作已取消；未发送新的写请求。"
        case .transport:
            return "网络请求失败；不会自动重试写入。"
        case .authenticationRejected:
            return "墨墨已拒绝当前 Token；请重新连接。"
        case .rateLimited:
            return "墨墨请求过于频繁；操作已停止，请稍后重试。"
        case .serverFailure:
            return "墨墨服务暂时不可用；操作已停止。"
        case .globalHTTPFailure:
            return "墨墨服务拒绝了本次读取；操作已停止。"
        case .responseRejected:
            return "服务返回无法安全确认；操作已停止。"
        case .itemResponseRejected:
            return "此条记录无法安全确认。"
        case .uncertainWriteOutcome:
            return "写入已发出，但暂时无法确认结果。不要重复执行；稍后重新预览，已经写入的内容会显示为一致。"
        case .previewInterrupted:
            return "预览被系统中断；未写入任何数据，可重新预览。"
        case .credentialStorageUnavailable:
            return "无法安全访问设备上的 Token；请解锁设备后重试。"
        case .remainingPhaseChanged:
            return "后续阶段的服务器状态已变化；该阶段未发送任何写请求，请重新预览。"
        }
    }

    var abortsReadPlan: Bool {
        switch self {
        case .authenticationRejected, .transport, .rateLimited, .serverFailure,
             .globalHTTPFailure, .responseRejected:
            return true
        default:
            return false
        }
    }
}

enum LocalParseState: Equatable, Sendable {
    case empty
    case valid(count: Int, first: String, last: String)
    case invalid

    var message: String? {
        switch self {
        case .empty:
            return nil
        case let .valid(count, first, last):
            return "已识别 \(count) 条 · \(first) → \(last)"
        case .invalid:
            return "无法识别当前输入"
        }
    }

    var isValid: Bool {
        if case .valid = self { return true }
        return false
    }
}

struct BatchEntry: Equatable, Sendable {
    let ordinal: Int
    let spelling: String
    let normalizedSpelling: String
    let interpretation: String
}

enum PreviewClassification: String, Codable, Equatable, Sendable {
    case create = "CREATE"
    case update = "UPDATE"
    case alreadyMatching = "ALREADY_MATCHING"
    case blocked = "BLOCKED"

    var compactLabel: String {
        switch self {
        case .create: return "新建"
        case .update: return "更新"
        case .alreadyMatching: return "一致"
        case .blocked: return "阻断"
        }
    }
}

struct PreviewRow: Codable, Equatable, Identifiable, Sendable {
    let ordinal: Int
    let spelling: String
    let classification: PreviewClassification
    let current: String?
    let proposed: String
    /// Populated only for an UPDATE whose stored tags differ from the intended
    /// selected tags, so tag-only writes are visible without repeating tags on
    /// every row.
    let currentTags: [String]?
    let proposedTags: [String]?
    let reason: String?

    var id: Int { ordinal }

    var canExpand: Bool {
        classification == .create || classification == .update
    }

    var compactBlockedReason: String? {
        guard classification == .blocked else { return nil }
        switch reason {
        case "AMBIGUOUS": return "存在多条自建释义"
        case "VOCABULARY_NOT_FOUND": return "未读取到可用词条目标"
        case "VOCABULARY_MATCH_ANOMALY": return "词条目标匹配异常"
        default: return "其他无法安全读取"
        }
    }
}

struct PreviewRowDetails: Equatable, Sendable {
    let current: String?
    let proposed: String
    let currentTags: [String]?
    let proposedTags: [String]?
}

struct PreviewCounts: Codable, Equatable, Sendable {
    let create: Int
    let update: Int
    let alreadyMatching: Int
    let blocked: Int
}

struct PreviewPresentation: Codable, Equatable, Sendable {
    let rows: [PreviewRow]
    let counts: PreviewCounts
}

enum OperationGroup: String, Codable, Equatable, Sendable {
    case create
    case update
}

/// A primary action offered by a Preview.
///
/// A single-group Preview keeps the original one-group-per-button layout. A mixed
/// actionable Preview instead offers exactly one action covering the whole
/// displayed plan (#76): the Owner must never have to run CREATE, re-Preview the
/// remainder and confirm UPDATE by hand.
struct ExecutionAction: Equatable, Identifiable, Sendable {
    /// `nil` when this action covers the whole displayed plan.
    let group: OperationGroup?
    let createCount: Int
    let updateCount: Int

    init(group: OperationGroup, count: Int) {
        self.group = group
        createCount = group == .create ? count : 0
        updateCount = group == .update ? count : 0
    }

    /// The single mixed-batch action covering both phases.
    init(createCount: Int, updateCount: Int) {
        group = nil
        self.createCount = createCount
        self.updateCount = updateCount
    }

    var id: String { group?.rawValue ?? "whole-plan" }
    var count: Int { createCount + updateCount }
    var coversWholePlan: Bool { group == nil }

    var title: String {
        guard let group else {
            return "执行 \(count) 条（新建 \(createCount) · 更新 \(updateCount)）"
        }
        return group == .create ? "新建 \(createCount)" : "更新 \(updateCount)"
    }
}

enum WriteOutcome: String, Codable, Equatable, Sendable {
    case confirmed
    case recovered
    case notVerified
    case notAttempted
}

/// A closed classification for failures thrown by `HTTPTransport.send`. It never
/// preserves an arbitrary error description or associated value.
enum PostSendFailureCategory: String, Codable, Equatable, Sendable {
    case transport
    case credential
    case responseRejected
    case cancelled
    case other

    init(error: Error) {
        switch error as? CompanionError {
        case .transport:
            self = .transport
        case .credentialRejected, .credentialStorageUnavailable, .notConnected:
            self = .credential
        case .responseRejected, .itemResponseRejected:
            self = .responseRejected
        case .cancelled:
            self = .cancelled
        default:
            self = .other
        }
    }
}

/// Privacy-safe evidence about whether an item's one permitted POST crossed the
/// dispatch boundary. This deliberately has no request, route, ID or body field.
enum PostDispatchCategory: Codable, Equatable, Sendable {
    case notDispatched
    case clean2xx(status: Int)
    case httpRejected(status: Int)
    case transportFailure(errorCategory: PostSendFailureCategory)

    var displayLabel: String {
        switch self {
        case .notDispatched: return "未发出"
        case let .clean2xx(status), let .httpRejected(status): return "HTTP \(status)"
        case let .transportFailure(category): return "发送失败（\(category.rawValue)）"
        }
    }

    var diagnosticCode: String {
        switch self {
        case .notDispatched: return "notDispatched"
        case .clean2xx: return "clean2xx"
        case .httpRejected: return "httpRejected"
        case let .transportFailure(category):
            return "transportFailure/\(category.rawValue)"
        }
    }

    var wasDispatched: Bool { self != .notDispatched }
}

/// One closed, developer-useful layer for an authenticated readback attempt.
/// Raw responses and arbitrary server values can never enter this enum.
enum ReadbackCategory: String, Codable, Equatable, Sendable {
    case success
    case transportFailure
    case authenticationRejected
    case rateLimited
    case serverFailure
    case otherHTTPRejection
    case responseSchemaRejected
    case targetNotVisible
    case targetAmbiguous
    case intendedStateMismatch

    var displayLabel: String {
        switch self {
        case .success: return "确认成功"
        case .transportFailure: return "网络读取失败"
        case .authenticationRejected: return "Token 被拒绝"
        case .rateLimited: return "请求过于频繁"
        case .serverFailure: return "服务端失败"
        case .otherHTTPRejection: return "其他 HTTP 拒绝"
        case .responseSchemaRejected: return "返回结构无法安全读取"
        case .targetNotVisible: return "目标暂未出现"
        case .targetAmbiguous: return "目标存在歧义"
        case .intendedStateMismatch: return "目标内容不一致"
        }
    }

    /// Only failures that can plausibly be transient are allowed another paced
    /// GET inside phrase CREATE's fixed confirmation window. A 429 stops rather
    /// than adding pressure, while auth/schema/conflict failures are deterministic.
    var isRetryablePhraseConfirmationFailure: Bool {
        switch self {
        case .transportFailure, .serverFailure, .targetNotVisible:
            return true
        default:
            return false
        }
    }

    init(error: CompanionError) {
        switch error {
        case .transport, .cancelled:
            self = .transportFailure
        case .authenticationRejected:
            self = .authenticationRejected
        case .rateLimited:
            self = .rateLimited
        case .serverFailure:
            self = .serverFailure
        case .globalHTTPFailure:
            self = .otherHTTPRejection
        case .responseRejected, .itemResponseRejected:
            self = .responseSchemaRejected
        default:
            self = .responseSchemaRejected
        }
    }
}

enum PhraseMismatchKey: String, Codable, CaseIterable, Equatable, Sendable {
    case english
    case chinese
    case source
    case status
}

/// Counts and closed mismatch keys from a decoded phrase collection. IDs and
/// record bodies are intentionally absent.
struct PhraseReadbackFacts: Codable, Equatable, Sendable {
    let activeRecordCount: Int
    let sameEnglishCount: Int
    let mismatchKeys: [PhraseMismatchKey]
}

struct ReadbackAttemptDiagnostic: Codable, Equatable, Sendable {
    let category: ReadbackCategory
    let phraseFacts: PhraseReadbackFacts?

    init(category: ReadbackCategory, phraseFacts: PhraseReadbackFacts? = nil) {
        self.category = category
        self.phraseFacts = phraseFacts
    }
}

/// The one shared, intentionally small write diagnostic used by phrase and
/// interpretation executors. Receipt-level data supplies content kind,
/// operation, timestamp and build metadata.
struct WriteAttemptDiagnostic: Codable, Equatable, Sendable {
    let ordinal: Int
    let postDispatch: PostDispatchCategory
    let readbackAttempts: [ReadbackAttemptDiagnostic]
    let terminalErrorCategory: CompanionError?
}

struct ItemExecutionResult: Equatable, Sendable {
    let spelling: String
    let outcome: WriteOutcome
    let diagnostic: WriteAttemptDiagnostic?

    init(
        spelling: String,
        outcome: WriteOutcome,
        diagnostic: WriteAttemptDiagnostic? = nil
    ) {
        self.spelling = spelling
        self.outcome = outcome
        self.diagnostic = diagnostic
    }
}

struct ExecutionSummary: Equatable, Sendable {
    let group: OperationGroup
    let succeeded: Int
    let failed: Int
    let cancelled: Bool
    let stalePreview: Bool
    let results: [ItemExecutionResult]
    let terminalError: CompanionError?

    init(
        group: OperationGroup,
        succeeded: Int,
        failed: Int,
        cancelled: Bool,
        stalePreview: Bool,
        results: [ItemExecutionResult],
        terminalError: CompanionError? = nil
    ) {
        self.group = group
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
        self.stalePreview = stalePreview
        self.results = results
        self.terminalError = terminalError
    }

    static func stale(_ group: OperationGroup) -> ExecutionSummary {
        ExecutionSummary(
            group: group,
            succeeded: 0,
            failed: 0,
            cancelled: false,
            stalePreview: true,
            results: []
        )
    }

    static func globalFailure(_ group: OperationGroup, _ error: CompanionError) -> ExecutionSummary {
        ExecutionSummary(
            group: group,
            succeeded: 0,
            failed: 0,
            cancelled: false,
            stalePreview: false,
            results: [],
            terminalError: error
        )
    }

    /// Every planned item of this phase was written and read back successfully.
    ///
    /// Deliberately strict: a stop always leaves at least one `.notAttempted` or
    /// `.notVerified` behind, and a cancellation flag alone is enough to fail. Only
    /// this may let a later phase begin.
    var isFullSuccess: Bool {
        !stalePreview
            && !cancelled
            && failed == 0
            && !results.isEmpty
            && succeeded == results.count
            && results.allSatisfy { $0.outcome == .confirmed || $0.outcome == .recovered }
    }
}

/// Why a planned phase never started.
enum BatchRunStopReason: String, Equatable, Sendable {
    /// The phase before it did not commit completely.
    case earlierPhaseIncomplete
    /// Its own fresh authenticated preflight no longer matched the approved plan.
    case remainingPhaseChanged
    /// The run was cancelled — ordinarily background time expiring — before the
    /// phase could be revalidated.
    case interrupted
}

enum BatchRunOutcome: Equatable, Sendable {
    /// The whole-plan authorization or the whole-batch preflight did not match.
    /// Nothing was written.
    case stale
    /// Every planned phase ran and produced its own summary.
    case completed
    /// An earlier phase resolved, and the named phase was deliberately not started.
    case stoppedBeforeRemainingPhase(group: OperationGroup, reason: BatchRunStopReason)
    /// A session/global read failed. Phase summaries preserve any already
    /// dispatched write outcome; no later POST is started.
    case globalFailure(CompanionError)
}

/// The result of one Owner-authorized whole-plan run.
///
/// `phases` holds one summary per phase that actually ran, in execution order, so
/// CREATE and UPDATE stay distinguishable in History exactly as they are today.
struct BatchRunResult: Equatable, Sendable {
    let outcome: BatchRunOutcome
    let phases: [ExecutionSummary]

    static let stale = BatchRunResult(outcome: .stale, phases: [])

    var isFullSuccess: Bool {
        outcome == .completed && !phases.isEmpty && phases.allSatisfy(\.isFullSuccess)
    }

    func summary(for group: OperationGroup) -> ExecutionSummary? {
        phases.first { $0.group == group }
    }
}

/// What an authorized execution is doing right now.
///
/// Every value is derived from real executor state — a completed readback, a
/// dispatched item — never from a timer. Only the Owner's own spelling is carried;
/// no identifier, fingerprint, payload or credential material appears here.
///
/// `writing` uses 1-based current-item semantics, so the visible sequence is
/// exactly 1/N, 2/N, … N/N with no compensating arithmetic.
///
/// The execution-time preflight is deliberately *not* one of those sequences.
/// It still reads every approved item over the network before the first POST —
/// that whole-batch gate is the reason no item can be written before a later one
/// is known to have changed — but the Owner sees a single compact `securing`
/// stage instead of a second apparent 1/N pass (#76). Per-item numbers belong to
/// actual writes only.
enum ExecutionStage: Equatable, Sendable {
    case securing
    case writing(group: OperationGroup, item: Int, total: Int, spelling: String)
    case finishing(group: OperationGroup)

    var label: String {
        switch self {
        case .securing:
            return "安全确认中…"
        case let .writing(group, item, total, spelling):
            let verb = group == .create ? "正在新建" : "正在更新"
            return "\(verb) \(item)/\(total) · \(spelling)"
        case .finishing:
            return "正在收尾…"
        }
    }
}

/// Everything the native confirmation must state so that one approval covers the
/// exact displayed plan and nothing else (#76).
struct PendingBatchConfirmation: Equatable, Sendable {
    let createSpellings: [String]
    let updateSpellings: [String]
    /// Short form of the whole-plan binding digest, which commits to the exact
    /// Preview and to both subplans including their proposed content.
    let bindingDigest: String

    var createCount: Int { createSpellings.count }
    var updateCount: Int { updateSpellings.count }
    var totalCount: Int { createCount + updateCount }

    var title: String { "确认执行 \(totalCount) 条？" }

    var actionTitle: String {
        "确认执行 \(totalCount) 条（新建 \(createCount) · 更新 \(updateCount)）"
    }

    var message: String {
        var lines = ["共 \(totalCount) 条 · 新建 \(createCount) · 更新 \(updateCount)"]
        if !createSpellings.isEmpty {
            lines.append("新建：" + createSpellings.joined(separator: "、"))
        }
        if !updateSpellings.isEmpty {
            lines.append("更新：" + updateSpellings.joined(separator: "、"))
        }
        lines.append("授权指纹 \(bindingDigest)")
        lines.append(
            "将重新完整预检；只有与当前预览严格一致时才会按 新建 → 更新 顺序写入。"
                + "每项最多一次 POST，不重试。"
        )
        return lines.joined(separator: "\n")
    }
}

/// The one native destructive confirmation for a phrase CREATE plan. It carries
/// only Owner-safe presentation data; exact content and write authority remain in
/// the separately armed `PhraseCreateApproval`.
struct PendingPhraseConfirmation: Equatable, Sendable {
    let spellings: [String]
    let bindingDigest: String

    var count: Int { spellings.count }
    var title: String { "确认新建 \(count) 条例句？" }
    var actionTitle: String { "确认新建 \(count) 条例句" }
    var message: String {
        [
            "共 \(count) 条：" + spellings.joined(separator: "、"),
            "授权指纹 \(bindingDigest)",
            "将先执行一次新的完整鉴权预检；只有与当前预览严格一致才会写入。每项最多一次 POST，不重试。",
        ].joined(separator: "\n")
    }
}

/// Read progress of an ordinary Preview, using the same 1-based current-entry
/// semantics as `ExecutionStage`. Carries no credential or identifier material.
struct PreviewProgress: Equatable, Sendable {
    let entry: Int
    let total: Int

    var label: String { "正在预览 \(entry)/\(total)" }
}

/// A `Sendable` sink the executor can report through without knowing about the UI.
struct ExecutionProgressReporter: Sendable {
    private let handler: @Sendable (ExecutionStage) -> Void

    init(_ handler: @escaping @Sendable (ExecutionStage) -> Void) {
        self.handler = handler
    }

    func report(_ stage: ExecutionStage) { handler(stage) }
}

struct FinalSummary: Equatable, Sendable {
    var created = 0
    var updated = 0
    var alreadyMatching = 0
    var failed = 0
    var unconfirmed = 0
    var notAttempted = 0
    var stopped = false

    var completedWrites: Int { created + updated }

    var stoppedMessage: String? {
        guard stopped else { return nil }
        return "执行已停止：已完成 \(completedWrites) 条，其余 \(notAttempted) 条未执行。"
    }
}

struct VocabularyRecord: Equatable, Sendable {
    let id: String
    let spelling: String
}

struct InterpretationRecord: Equatable, Sendable {
    let id: String
    let interpretation: String
    let tags: [String]
    let status: String

    func matchesIntendedState(_ proposed: String, tags intendedTags: [String]) -> Bool {
        interpretation == proposed
            && tags.count == intendedTags.count
            && Set(tags).count == intendedTags.count
            && Set(tags) == Set(intendedTags)
            && status == CompanionConstants.status
    }
}

struct PrivatePreflightItem: Equatable, Sendable {
    let entry: BatchEntry
    let classification: PreviewClassification
    let vocabularyID: String?
    let baseline: InterpretationRecord?
    let reason: String?

    func publicRow(tags intendedTags: [String]) -> PreviewRow {
        let tagsDiffer = classification == .update
            && baseline.map {
                $0.tags.count != intendedTags.count || Set($0.tags) != Set(intendedTags)
            } == true
        return PreviewRow(
            ordinal: entry.ordinal,
            spelling: entry.spelling,
            classification: classification,
            current: baseline?.interpretation,
            proposed: entry.interpretation,
            currentTags: tagsDiffer ? baseline?.tags : nil,
            proposedTags: tagsDiffer ? intendedTags : nil,
            reason: reason
        )
    }
}

struct PreviewBindingContext: Equatable, Sendable {
    let host: String
    let createPath: String
    let updatePath: String
    let tags: [String]
    let status: String
    let createBatchDigest: String?
    let updateBatchDigest: String?
}

struct PreviewSnapshot: Equatable, Sendable {
    let sourceIdentity: String
    let credentialFingerprint: String
    let accountMode: String
    let bindingContext: PreviewBindingContext
    let items: [PrivatePreflightItem]
    let presentation: PreviewPresentation

    func items(for group: OperationGroup) -> [PrivatePreflightItem] {
        let desired: PreviewClassification = group == .create ? .create : .update
        return items.filter { $0.classification == desired }
    }
}

func isSafeIdentifier(_ value: String) -> Bool {
    !value.isEmpty
        && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
}

func containsDisallowedControlCharacter(_ value: String, allowingNewline: Bool) -> Bool {
    value.unicodeScalars.contains { scalar in
        if allowingNewline && scalar.value == 10 { return false }
        return scalar.value < 32 || scalar.value == 127
    }
}
