import Foundation

enum CompanionConstants {
    static let productionBaseURL = URL(string: "https://open.maimemo.com")!
    static let accountMode = "main"
    static let accountLabel = "主账号"
    static let tags = ["MBA", "BEC", "GMAT"]
    static let status = "PUBLISHED"
    static let maxActivePhrasesPerVocabulary = 5
    static let maxBatchItems = 30
    static let maxInputBytes = 262_144
    static let maxInterpretationCharacters = 2_000
    static let maxTokenCharacters = 8_192
    static let pacingSeconds = 1.6
    static let writePolicy = "EXACTLY ONE POST PER ITEM / NO RETRY / IMMEDIATE READBACK"
}

enum ContentMode: String, CaseIterable, Equatable, Sendable {
    case interpretation
    case phrase

    var pickerLabel: String { self == .interpretation ? "释义" : "例句" }
    var navigationTitle: String { self == .interpretation ? "释义录入" : "例句录入" }
    var editorAccessibilityLabel: String {
        self == .interpretation ? "批次释义输入" : "批次例句输入"
    }
}

enum CompanionError: String, Error, Equatable, CustomStringConvertible {
    case inputRejected
    case credentialRejected
    case notConnected
    case previewRequired
    case approvalRequired
    case stalePreview
    case blocked
    case cancelled
    case transport
    case responseRejected
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
            return "请先连接主账号。"
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
        case .responseRejected:
            return "服务返回无法安全确认；操作已停止。"
        case .uncertainWriteOutcome:
            return "写入结果无法确认；不要重试，操作已停止。"
        case .previewInterrupted:
            return "预览被系统中断；未写入任何数据，可重新预览。"
        case .credentialStorageUnavailable:
            return "无法安全访问设备上的 Token；请解锁设备后重试。"
        case .remainingPhaseChanged:
            return "后续阶段的服务器状态已变化；该阶段未发送任何写请求，请重新预览。"
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
    let reason: String?

    var id: Int { ordinal }

    var canExpand: Bool {
        classification == .create || classification == .update
    }

    var compactBlockedReason: String? {
        guard classification == .blocked else { return nil }
        return reason == "AMBIGUOUS" ? "存在多条自建释义" : "无法安全读取"
    }
}

struct PreviewRowDetails: Equatable, Sendable {
    let current: String?
    let proposed: String
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

struct ItemExecutionResult: Equatable, Sendable {
    let spelling: String
    let outcome: WriteOutcome
}

struct ExecutionSummary: Equatable, Sendable {
    let group: OperationGroup
    let succeeded: Int
    let failed: Int
    let cancelled: Bool
    let stalePreview: Bool
    let results: [ItemExecutionResult]

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

/// The one native destructive confirmation for a phrase write. It carries only
/// Owner-safe presentation data; raw target identity and exact authority remain
/// in the separately armed approval.
struct PendingPhraseConfirmation: Equatable, Sendable {
    let operationGroup: OperationGroup
    let spellings: [String]
    let bindingDigest: String
    let replacementComparison: PhraseReplacementComparison?

    var count: Int { spellings.count }
    var title: String {
        operationGroup == .create ? "确认新建 \(count) 条例句？" : "确认替换这 1 条例句？"
    }
    var actionTitle: String {
        operationGroup == .create ? "确认新建 \(count) 条例句" : "替换这 1 条例句"
    }
    var message: String {
        var lines = [
            "共 \(count) 条：" + spellings.joined(separator: "、"),
            "授权指纹 \(bindingDigest)",
            "将先执行一次新的完整鉴权预检；只有与当前预览严格一致才会写入。每项最多一次 POST，不重试。",
        ]
        if let replacementComparison {
            lines.insert(
                "CURRENT：\(replacementComparison.current.english) / "
                    + "\(replacementComparison.current.chinese) / "
                    + replacementComparison.current.source,
                at: 1
            )
            lines.insert(
                "PROPOSED：\(replacementComparison.proposed.english) / "
                    + "\(replacementComparison.proposed.chinese) / "
                    + replacementComparison.proposed.source,
                at: 2
            )
        }
        return lines.joined(separator: "\n")
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

    func matchesIntendedState(_ proposed: String) -> Bool {
        interpretation == proposed
            && tags.count == CompanionConstants.tags.count
            && Set(tags) == Set(CompanionConstants.tags)
            && status == CompanionConstants.status
    }
}

struct PrivatePreflightItem: Equatable, Sendable {
    let entry: BatchEntry
    let classification: PreviewClassification
    let vocabularyID: String?
    let baseline: InterpretationRecord?
    let reason: String?

    var publicRow: PreviewRow {
        PreviewRow(
            ordinal: entry.ordinal,
            spelling: entry.spelling,
            classification: classification,
            current: baseline?.interpretation,
            proposed: entry.interpretation,
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
