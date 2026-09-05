import Foundation

/// The three content families batch Query reports on.
enum QueryContentFamily: String, CaseIterable, Equatable, Sendable {
    case interpretation
    case phrase
    case note

    var label: String {
        switch self {
        case .interpretation: return "释义"
        case .phrase: return "例句"
        case .note: return "助记"
        }
    }
}

/// Why something could not be read. Only causes the app can actually prove.
///
/// Nothing here is ever guessed: an unclassifiable failure stays
/// `responseNotSafelyReadable` rather than inventing a more specific story.
enum QueryInabilityReason: String, CaseIterable, Equatable, Sendable {
    /// The shared resolver found no record for this exact spelling.
    case targetNotFound
    /// A record came back but could not be uniquely, safely attributed.
    case targetMatchAnomaly
    /// The content response for this one cell failed the closed decoder.
    case responseNotSafelyReadable

    var label: String {
        switch self {
        case .targetNotFound: return "未找到可读取的词条目标"
        case .targetMatchAnomaly: return "词条目标匹配异常"
        case .responseNotSafelyReadable: return "返回内容无法安全读取"
        }
    }

    init(resolutionFailure: VocabularyResolutionFailure) {
        switch resolutionFailure {
        case .notFound: self = .targetNotFound
        case .matchAnomaly: self = .targetMatchAnomaly
        }
    }
}

/// One cell's truth.
///
/// The frozen numeric grammar: `0` and `1+` are *known numbers*; queued,
/// loading, unread and unavailable are not numbers at all and must never render
/// or filter as `0`.
enum QueryCellState: Equatable, Sendable {
    /// Not started yet in this run.
    case queued
    /// This exact read is in flight.
    case loading
    /// A confirmed count. `0` means "confirmed none", never "unknown".
    case count(Int)
    /// The run stopped before this cell was reached.
    case unread
    /// This cell cannot be read; it is emphatically not a zero.
    case unavailable(QueryInabilityReason)

    var knownCount: Int? {
        if case let .count(value) = self { return value }
        return nil
    }

    var isUnavailable: Bool {
        if case .unavailable = self { return true }
        return false
    }

    var inabilityReason: QueryInabilityReason? {
        if case let .unavailable(reason) = self { return reason }
        return nil
    }

    /// A cell that has reached a truthful terminal state for this run. Those are
    /// never re-read on 继续查阅, and never auto-retried.
    var isTerminal: Bool {
        switch self {
        case .count, .unavailable: return true
        case .queued, .loading, .unread: return false
        }
    }
}

/// The read status dimension the filter exposes.
enum QueryReadStatus: Equatable, Sendable {
    /// Every cell of the row is a known number.
    case normal
    /// At least one cell (or the whole row target) is unavailable.
    case unavailable
    /// Nothing terminal yet, or the run stopped before finishing this row.
    case unread
}

/// One result row: an input, its resolved target, and its three cells.
struct QueryRow: Equatable, Identifiable, Sendable {
    let input: QueryInput
    /// `nil` while unresolved, or when the row target itself is unavailable.
    var vocabularyID: String?
    /// Set when the *whole row* is unreadable (resolver could not give a safe
    /// target). Individual cells then carry the same reason.
    var rowInability: QueryInabilityReason?
    var cells: [QueryContentFamily: QueryCellState]

    var id: Int { input.ordinal }
    var spelling: String { input.spelling }

    init(input: QueryInput) {
        self.input = input
        vocabularyID = nil
        rowInability = nil
        cells = Dictionary(
            uniqueKeysWithValues: QueryContentFamily.allCases.map { ($0, .queued) }
        )
    }

    func cell(_ family: QueryContentFamily) -> QueryCellState {
        cells[family] ?? .queued
    }

    var readStatus: QueryReadStatus {
        if rowInability != nil { return .unavailable }
        let states = QueryContentFamily.allCases.map(cell)
        if states.contains(where: \.isUnavailable) { return .unavailable }
        return states.allSatisfy { $0.knownCount != nil } ? .normal : .unread
    }

    /// Reasons actually present on this row — used to build the filter's
    /// present-only reason list.
    var inabilityReasons: Set<QueryInabilityReason> {
        if let rowInability { return [rowInability] }
        return Set(QueryContentFamily.allCases.compactMap { cell($0).inabilityReason })
    }

    var hasUnfinishedCells: Bool {
        QueryContentFamily.allCases.contains { !cell($0).isTerminal }
    }
}

/// One numeric filter predicate.
enum QueryCountPredicate: String, CaseIterable, Equatable, Sendable {
    case any
    case zero
    case positive

    var label: String {
        switch self {
        case .any: return "不限"
        case .zero: return "0"
        case .positive: return ">0"
        }
    }

    /// Only *known* numbers can satisfy a numeric predicate. An unread, queued,
    /// loading or unavailable cell matches neither `0` nor `>0`.
    func matches(_ state: QueryCellState) -> Bool {
        switch self {
        case .any:
            return true
        case .zero:
            return state.knownCount == 0
        case .positive:
            return (state.knownCount ?? 0) > 0
        }
    }
}

enum QueryReadStatusPredicate: String, CaseIterable, Equatable, Sendable {
    case any
    case normal
    case unavailable
    case unread

    var label: String {
        switch self {
        case .any: return "不限"
        case .normal: return "正常"
        case .unavailable: return "无法读取"
        case .unread: return "未读"
        }
    }

    func matches(_ status: QueryReadStatus) -> Bool {
        switch self {
        case .any: return true
        case .normal: return status == .normal
        case .unavailable: return status == .unavailable
        case .unread: return status == .unread
        }
    }
}

/// The local, network-free result filter.
///
/// Dimensions combine with AND. Filtering never sends a request and never
/// changes stored truth — it is a predicate over what is already known.
struct QueryFilter: Equatable, Sendable {
    var interpretation: QueryCountPredicate = .any
    var phrase: QueryCountPredicate = .any
    var note: QueryCountPredicate = .any
    var readStatus: QueryReadStatusPredicate = .any
    /// Narrowing within `读取状态 = 无法读取`. Empty means "any reason".
    var inabilityReasons: Set<QueryInabilityReason> = []

    static let none = QueryFilter()

    var isActive: Bool { self != Self.none }

    func predicate(for family: QueryContentFamily) -> QueryCountPredicate {
        switch family {
        case .interpretation: return interpretation
        case .phrase: return phrase
        case .note: return note
        }
    }

    mutating func setPredicate(_ predicate: QueryCountPredicate, for family: QueryContentFamily) {
        switch family {
        case .interpretation: interpretation = predicate
        case .phrase: phrase = predicate
        case .note: note = predicate
        }
    }

    func matches(_ row: QueryRow) -> Bool {
        guard QueryContentFamily.allCases.allSatisfy({
            predicate(for: $0).matches(row.cell($0))
        }) else {
            return false
        }
        guard readStatus.matches(row.readStatus) else { return false }
        guard readStatus == .unavailable, !inabilityReasons.isEmpty else { return true }
        return !row.inabilityReasons.isDisjoint(with: inabilityReasons)
    }

    func apply(to rows: [QueryRow]) -> [QueryRow] {
        isActive ? rows.filter(matches) : rows
    }

    /// Human-readable chips for the active dimensions, in a stable order.
    var activeChipLabels: [String] {
        var labels: [String] = []
        for family in QueryContentFamily.allCases {
            let predicate = predicate(for: family)
            guard predicate != .any else { continue }
            labels.append("\(family.label) \(predicate == .zero ? "= 0" : "> 0")")
        }
        if readStatus != .any {
            labels.append("读取状态 \(readStatus.label)")
        }
        return labels
    }
}

/// Why a run stopped without completing.
enum QueryStopReason: Equatable, Sendable {
    /// The Owner pressed 停止, or left/modified while running.
    case userStopped
    /// A batch-level provider failure (`CompanionError.abortsReadPlan`).
    case globalFailure(CompanionError)

    /// The frozen banner title for this stop.
    var bannerTitle: String {
        switch self {
        case .userStopped:
            return "已停止"
        case let .globalFailure(error):
            switch error {
            case .authenticationRejected: return "已停止 · 墨墨拒绝了当前 Token"
            case .transport: return "已停止 · 网络请求失败"
            case .rateLimited: return "已停止 · 请求过于频繁"
            default: return "已停止 · 服务返回无法安全确认"
            }
        }
    }

    /// The frozen banner body. `read` / `remaining` are row counts.
    func bannerBody(read: Int, remaining: Int) -> String? {
        guard case let .globalFailure(error) = self else { return nil }
        switch error {
        case .authenticationRejected:
            return "已读取的 \(read) 项保持不变，其余 \(remaining) 项显示为「未读」。"
                + "在设置中重新连接后需重新查阅。"
        case .transport:
            return "不会自动重试。已读取的 \(read) 项保持，其余 \(remaining) 项为「未读」。"
        case .rateLimited:
            return "墨墨限制了请求频率，请稍后再继续。"
                + "已读取的 \(read) 项保持，其余 \(remaining) 项为「未读」。"
        default:
            return "墨墨服务暂时不可用，或返回结构无法安全读取。"
                + "已读取的 \(read) 项保持，其余 \(remaining) 项为「未读」。"
        }
    }

    var requiresReconnect: Bool {
        if case .globalFailure(.authenticationRejected) = self { return true }
        return false
    }
}

/// What a Query run is doing right now.
enum QueryRunPhase: Equatable, Sendable {
    /// Editing the input; no result authority is being produced.
    case input
    /// The atomic resolver stage.
    case resolving
    /// Sequential row-major content reads.
    case reading
    /// Every planned cell reached a terminal state.
    case completed
    /// Stopped with truthful partial results preserved.
    case stopped(QueryStopReason)

    var isRunning: Bool {
        switch self {
        case .resolving, .reading: return true
        case .input, .completed, .stopped: return false
        }
    }

    var hasResult: Bool {
        switch self {
        case .input: return false
        case .resolving, .reading, .completed, .stopped: return true
        }
    }
}
