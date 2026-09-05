import Foundation

enum ReceiptContentKind: String, Codable, Equatable, Sendable {
    case interpretation
    case phrase

    var displayLabel: String { self == .interpretation ? "释义" : "例句" }
}

struct DiagnosticEnvironment: Codable, Equatable, Sendable {
    let appVersion: String
    let appBuild: String
    let systemVersion: String

    static var current: DiagnosticEnvironment {
        let info = Bundle.main.infoDictionary ?? [:]
        return DiagnosticEnvironment(
            appVersion: info["CFBundleShortVersionString"] as? String ?? "未知",
            appBuild: info["CFBundleVersion"] as? String ?? "未知",
            systemVersion: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }

    static let legacy = DiagnosticEnvironment(
        appVersion: "历史版本未记录",
        appBuild: "历史版本未记录",
        systemVersion: "历史版本未记录"
    )

    var appVersionAndBuild: String { "\(appVersion) (\(appBuild))" }
}

struct ExecutionReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let contentKind: ReceiptContentKind
    let operationGroup: OperationGroup
    let succeeded: Int
    let failed: Int
    let unconfirmed: Int
    let notAttempted: Int
    let stopped: Bool
    let items: [ExecutionReceiptItem]
    let diagnosticEnvironment: DiagnosticEnvironment
    /// The interpretation publication status this run intended to write (#161).
    ///
    /// Optional and backward-compatible on purpose: receipts written before
    /// #161 simply do not carry it, and are never migrated or backfilled. It is
    /// `nil` for phrase receipts, which have no publication selector.
    let interpretationStatus: String?

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        contentKind: ReceiptContentKind = .interpretation,
        operationGroup: OperationGroup,
        selectedSpellings: [String],
        interpretationStatus: String? = nil,
        result: ExecutionSummary,
        diagnosticEnvironment: DiagnosticEnvironment = .current
    ) {
        self.id = id
        self.timestamp = timestamp
        self.contentKind = contentKind
        self.operationGroup = operationGroup
        self.diagnosticEnvironment = diagnosticEnvironment
        self.interpretationStatus = contentKind == .interpretation
            ? interpretationStatus
            : nil
        items = selectedSpellings.enumerated().map { index, spelling in
            ExecutionReceiptItem(
                ordinal: result.results.indices.contains(index)
                    ? result.results[index].diagnostic?.ordinal ?? index + 1
                    : index + 1,
                spelling: spelling,
                finalOutcome: result.results.indices.contains(index)
                    ? result.results[index].outcome
                    : .notAttempted,
                diagnostic: result.results.indices.contains(index)
                    ? result.results[index].diagnostic
                    : nil
            )
        }
        succeeded = items.count { $0.finalOutcome == .confirmed || $0.finalOutcome == .recovered }
        unconfirmed = items.count {
            $0.finalOutcome == .notVerified
                && $0.diagnostic?.postDispatch.wasDispatched == true
        }
        failed = items.count {
            $0.finalOutcome == .notVerified
                && $0.diagnostic?.postDispatch.wasDispatched != true
        }
        notAttempted = items.count { $0.finalOutcome == .notAttempted }
        stopped = result.cancelled || failed > 0 || unconfirmed > 0 || notAttempted > 0
    }

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        selectedSpellings: [String],
        result: PhraseExecutionSummary,
        diagnosticEnvironment: DiagnosticEnvironment = .current
    ) {
        self.id = id
        self.timestamp = timestamp
        contentKind = .phrase
        operationGroup = .create
        self.diagnosticEnvironment = diagnosticEnvironment
        interpretationStatus = nil
        items = selectedSpellings.enumerated().map { index, spelling in
            ExecutionReceiptItem(
                ordinal: result.results.indices.contains(index)
                    ? result.results[index].diagnostic?.ordinal ?? index + 1
                    : index + 1,
                spelling: spelling,
                finalOutcome: result.results.indices.contains(index)
                    ? result.results[index].outcome
                    : .notAttempted,
                diagnostic: result.results.indices.contains(index)
                    ? result.results[index].diagnostic
                    : nil
            )
        }
        succeeded = items.count { $0.finalOutcome == .confirmed || $0.finalOutcome == .recovered }
        unconfirmed = items.count {
            $0.finalOutcome == .notVerified
                && $0.diagnostic?.postDispatch.wasDispatched == true
        }
        failed = items.count {
            $0.finalOutcome == .notVerified
                && $0.diagnostic?.postDispatch.wasDispatched != true
        }
        notAttempted = items.count { $0.finalOutcome == .notAttempted }
        stopped = result.cancelled || result.stalePreview || failed > 0
            || unconfirmed > 0 || notAttempted > 0
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, contentKind, operationGroup
        case succeeded, failed, unconfirmed, notAttempted, stopped, items
        case diagnosticEnvironment
        case interpretationStatus
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        timestamp = try values.decode(Date.self, forKey: .timestamp)
        contentKind = try values.decodeIfPresent(ReceiptContentKind.self, forKey: .contentKind)
            ?? .interpretation
        operationGroup = try values.decode(OperationGroup.self, forKey: .operationGroup)
        succeeded = try values.decode(Int.self, forKey: .succeeded)
        failed = try values.decode(Int.self, forKey: .failed)
        unconfirmed = try values.decodeIfPresent(Int.self, forKey: .unconfirmed) ?? 0
        notAttempted = try values.decode(Int.self, forKey: .notAttempted)
        stopped = try values.decode(Bool.self, forKey: .stopped)
        items = try values.decode([ExecutionReceiptItem].self, forKey: .items)
        diagnosticEnvironment = try values.decodeIfPresent(
            DiagnosticEnvironment.self,
            forKey: .diagnosticEnvironment
        ) ?? .legacy
        // Absent in every pre-#161 archive; absence is not a decode failure and
        // is never backfilled from a current preference.
        interpretationStatus = try values.decodeIfPresent(
            String.self,
            forKey: .interpretationStatus
        )
    }

    /// The user-facing publication value for this receipt, or `nil` when the
    /// receipt predates #161 or is a phrase receipt.
    var publicationLabel: String? {
        guard contentKind == .interpretation,
              let interpretationStatus,
              let status = InterpretationPublicationStatus(providerStatus: interpretationStatus)
        else {
            return nil
        }
        return status.label
    }

    var isFullSuccess: Bool {
        let allItemsVerified = succeeded == items.count && failed == 0
            && unconfirmed == 0 && notAttempted == 0
        switch contentKind {
        case .interpretation:
            // Preserve the pre-#84 interpretation contract: a cancellation flag
            // arriving after every item was verified does not undo completion.
            return allItemsVerified
        case .phrase:
            // Phrase's first UI slice is intentionally stricter: any interrupted
            // run retains the whole draft and must not look ordinarily complete.
            return !stopped && allItemsVerified
        }
    }

    var hasDiagnosticDetails: Bool { items.contains { $0.diagnostic != nil } }

    /// A self-contained bug-report excerpt assembled only from the closed local
    /// diagnostic model. It has no access to credentials, IDs, routes, request
    /// bodies or raw responses, so those values cannot accidentally be exported.
    var sanitizedDiagnosticText: String {
        let formatter = ISO8601DateFormatter()
        var lines = [
            "小黑鸟伴侣诊断",
            "版本：\(diagnosticEnvironment.appVersionAndBuild)",
            "iOS：\(diagnosticEnvironment.systemVersion)",
            "时间：\(formatter.string(from: timestamp))",
            "内容：\(contentKind.displayLabel) [\(contentKind.rawValue)]",
            "操作：\(operationGroup == .create ? "新建" : "更新") [\(operationGroup.rawValue)]",
        ]
        if let publicationLabel, let interpretationStatus {
            lines.append("发布：\(publicationLabel) [\(interpretationStatus)]")
        }

        for (index, item) in items.enumerated() {
            let ordinal = item.ordinal > 0 ? item.ordinal : index + 1
            lines.append("第 \(ordinal) 条：\(item.spelling)")
            lines.append("结果：\(item.outcomeDisplayLabel) [\(item.finalOutcome.rawValue)]")
            guard let diagnostic = item.diagnostic else {
                lines.append("诊断：此历史版本未记录")
                continue
            }
            lines.append(
                "POST：\(diagnostic.postDispatch.displayLabel) [\(diagnostic.postDispatch.diagnosticCode)]"
            )
            lines.append("回读次数：\(diagnostic.readbackAttempts.count)")
            for (attemptIndex, attempt) in diagnostic.readbackAttempts.enumerated() {
                var detail = "回读 \(attemptIndex + 1)：\(attempt.category.displayLabel) [\(attempt.category.rawValue)]"
                if let facts = attempt.phraseFacts {
                    detail += "；有效记录 \(facts.activeRecordCount)；相同英文 \(facts.sameEnglishCount)"
                    if !facts.mismatchKeys.isEmpty {
                        detail += "；不一致字段 "
                            + facts.mismatchKeys.map(\.rawValue).joined(separator: ",")
                    }
                }
                lines.append(detail)
            }
            lines.append(
                "终止错误：\(diagnostic.terminalErrorCategory?.rawValue ?? "无")"
            )
        }
        return lines.joined(separator: "\n")
    }
}

struct ExecutionReceiptItem: Codable, Equatable, Sendable {
    let ordinal: Int
    let spelling: String
    let finalOutcome: WriteOutcome
    let diagnostic: WriteAttemptDiagnostic?

    init(
        ordinal: Int,
        spelling: String,
        finalOutcome: WriteOutcome,
        diagnostic: WriteAttemptDiagnostic? = nil
    ) {
        self.ordinal = ordinal
        self.spelling = spelling
        self.finalOutcome = finalOutcome
        self.diagnostic = diagnostic
    }

    private enum CodingKeys: String, CodingKey {
        case ordinal, spelling, finalOutcome, diagnostic
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        ordinal = try values.decodeIfPresent(Int.self, forKey: .ordinal) ?? 0
        spelling = try values.decode(String.self, forKey: .spelling)
        finalOutcome = try values.decode(WriteOutcome.self, forKey: .finalOutcome)
        diagnostic = try values.decodeIfPresent(
            WriteAttemptDiagnostic.self,
            forKey: .diagnostic
        )
    }

    var outcomeDisplayLabel: String {
        switch finalOutcome {
        case .confirmed: return "已确认"
        case .recovered: return "已恢复确认"
        case .notVerified:
            return diagnostic?.postDispatch.wasDispatched == true ? "未确认" : "失败"
        case .notAttempted: return "未执行"
        }
    }
}

protocol HistoryStore {
    func loadReceipts() throws -> [ExecutionReceipt]
    func saveReceipts(_ receipts: [ExecutionReceipt]) throws
    func clearReceipts() throws
}

final class FileHistoryStore: HistoryStore {
    private struct Archive: Codable {
        let version: Int
        let receipts: [ExecutionReceipt]
    }

    private enum StoreError: Error {
        case unsupportedVersion
    }

    private static let archiveVersion = 1
    private static let directoryName = "com.davidqyc.momoMoreEfficient"
    private static let fileName = "history-v1.json"

    private let fileManager: FileManager
    private let applicationSupportOverride: URL?

    init(
        fileManager: FileManager = .default,
        applicationSupportDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        applicationSupportOverride = applicationSupportDirectory
    }

    func loadReceipts() throws -> [ExecutionReceipt] {
        let fileURL = try historyFileURL(createDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive = try decoder.decode(Archive.self, from: Data(contentsOf: fileURL))
        guard archive.version == Self.archiveVersion else { throw StoreError.unsupportedVersion }
        return archive.receipts.sorted { $0.timestamp > $1.timestamp }
    }

    func saveReceipts(_ receipts: [ExecutionReceipt]) throws {
        let fileURL = try historyFileURL(createDirectory: true)
        let archive = Archive(version: Self.archiveVersion, receipts: receipts)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(archive).write(to: fileURL, options: .atomic)
        excludeFromBackup(fileURL)
    }

    func clearReceipts() throws {
        let fileURL = try historyFileURL(createDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    private func historyFileURL(createDirectory: Bool) throws -> URL {
        let applicationSupport = try applicationSupportOverride
            ?? fileManager.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: createDirectory
            )
        let directory = applicationSupport.appendingPathComponent(
            Self.directoryName,
            isDirectory: true
        )
        if createDirectory {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            excludeFromBackup(directory)
        }
        return directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    private func excludeFromBackup(_ url: URL) {
        var mutableURL = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? mutableURL.setResourceValues(values)
    }
}
