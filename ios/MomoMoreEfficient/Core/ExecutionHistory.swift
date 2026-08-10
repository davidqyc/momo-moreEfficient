import Foundation

struct ExecutionReceipt: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let timestamp: Date
    let operationGroup: OperationGroup
    let succeeded: Int
    let failed: Int
    let notAttempted: Int
    let stopped: Bool
    let items: [ExecutionReceiptItem]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        operationGroup: OperationGroup,
        selectedSpellings: [String],
        result: ExecutionSummary
    ) {
        self.id = id
        self.timestamp = timestamp
        self.operationGroup = operationGroup
        items = selectedSpellings.enumerated().map { index, spelling in
            ExecutionReceiptItem(
                spelling: spelling,
                finalOutcome: result.results.indices.contains(index)
                    ? result.results[index].outcome
                    : .notAttempted
            )
        }
        succeeded = items.count { $0.finalOutcome == .confirmed || $0.finalOutcome == .recovered }
        failed = items.count { $0.finalOutcome == .notVerified }
        notAttempted = items.count { $0.finalOutcome == .notAttempted }
        stopped = result.cancelled || notAttempted > 0
    }

    var isFullSuccess: Bool {
        succeeded == items.count && failed == 0 && notAttempted == 0
    }
}

struct ExecutionReceiptItem: Codable, Equatable, Sendable {
    let spelling: String
    let finalOutcome: WriteOutcome
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
