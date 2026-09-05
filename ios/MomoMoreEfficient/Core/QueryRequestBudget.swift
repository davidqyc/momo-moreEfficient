import Foundation

/// A deterministic estimate of the provider requests one Query run would cost.
///
/// Advisory only (#161 correction 4). This is never a cap: `查阅 N 项` stays
/// enabled at every tier, and the thresholds derive from the real windows the
/// shared `RequestWindowScheduler` already enforces (40 / 60 s, 2000 / 5 h), not
/// from an arbitrary item count.
///
/// A pure function of the parsed input — no clock, no credential, no network.
struct QueryRequestBudget: Equatable, Sendable {
    enum Tier: Equatable, Sendable {
        /// Small enough that a duration hint would be noise.
        case quiet
        /// Worth stating the duration and that stopping is safe.
        case calm
        /// Exceeds the 5-hour allowance; suggest splitting the batch.
        case suggestSplitting
    }

    let uniqueInputCount: Int
    /// `ceil(U / chunk)` read-semantic resolver POSTs.
    let resolverRequests: Int
    /// Upper bound: 释义 + 例句 + 助记 for each safely resolved input.
    let contentRequests: Int

    var estimatedRequests: Int { resolverRequests + contentRequests }

    /// Sustained throughput is bounded by the 40-per-60-seconds window.
    var estimatedMinutes: Int {
        max(1, Int(ceil(Double(estimatedRequests) / 40.0)))
    }

    var tier: Tier {
        if estimatedRequests >= 2_000 { return .suggestSplitting }
        if estimatedRequests > 40 { return .calm }
        return .quiet
    }

    /// Frozen copy from `USER_VISIBLE_COPY_LEDGER.md §5`. The `建议每批 600 项以内`
    /// sentence is advisory wording, not a 600-item limit.
    var advisory: String? {
        switch tier {
        case .quiet:
            return nil
        case .calm:
            return "较大批次：预计约 \(estimatedRequests) 次请求"
                + "（定位 \(resolverRequests) 次 + 每项最多 3 次读取），"
                + "受墨墨频率限制约需 \(estimatedMinutes) 分钟；读取中可随时停止，已读结果保留。"
        case .suggestSplitting:
            return "建议分批：预计约 \(estimatedRequests) 次请求，"
                + "超出墨墨 5 小时内 2000 次的额度，一次读完可能需要等待数小时。"
                + "建议每批 600 项以内；仍可开始，读取中可随时停止。"
        }
    }

    static let contentReadsPerInput = 3

    static func estimate(uniqueInputCount: Int) -> QueryRequestBudget {
        let unique = max(0, uniqueInputCount)
        let chunk = CompanionConstants.vocabularyQueryChunkSize
        return QueryRequestBudget(
            uniqueInputCount: unique,
            resolverRequests: unique == 0
                ? 0
                : Int(ceil(Double(unique) / Double(chunk))),
            contentRequests: unique * contentReadsPerInput
        )
    }

    static func estimate(for parse: QueryInputParse) -> QueryRequestBudget {
        estimate(uniqueInputCount: parse.uniqueCount)
    }
}
