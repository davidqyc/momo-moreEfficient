import Foundation

enum CompanionConstants {
    static let productionBaseURL = URL(string: "https://open.maimemo.com")!
    static let accountMode = "main"
    static let accountLabel = "主账号"
    static let tags = ["MBA", "BEC", "GMAT"]
    static let status = "PUBLISHED"
    static let maxBatchItems = 30
    static let maxInputBytes = 262_144
    static let maxInterpretationCharacters = 2_000
    static let maxTokenCharacters = 8_192
    static let pacingSeconds = 1.6
    static let writePolicy = "EXACTLY ONE POST PER ITEM / NO RETRY / IMMEDIATE READBACK"
}

enum CompanionError: String, Error, Equatable, CustomStringConvertible {
    case inputRejected
    case credentialRejected
    case notConnected
    case previewRequired
    case stalePreview
    case blocked
    case cancelled
    case transport
    case responseRejected
    case uncertainWriteOutcome

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
        }
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
}

struct PreviewRow: Codable, Equatable, Identifiable, Sendable {
    let ordinal: Int
    let spelling: String
    let classification: PreviewClassification
    let current: String?
    let proposed: String
    let reason: String?

    var id: Int { ordinal }
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

enum OperationGroup: String, Equatable, Sendable {
    case create
    case update
}

enum WriteOutcome: String, Equatable, Sendable {
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
}

struct FinalSummary: Equatable, Sendable {
    var created = 0
    var updated = 0
    var alreadyMatching = 0
    var failed = 0
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
