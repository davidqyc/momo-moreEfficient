import Foundation

/// The complete non-secret payload allowed in the Share Extension App Group.
/// No credential, Preview, approval, API response or execution state belongs here.
struct PendingCapture: Codable, Equatable {
    static let currentVersion = 2

    let version: Int
    let text: String
    let sourceURL: URL?
    let sourceTitle: String?
    let capturedAt: Date

    init(
        text: String,
        sourceURL: URL? = nil,
        sourceTitle: String? = nil,
        capturedAt: Date = Date(),
        version: Int = Self.currentVersion
    ) {
        self.version = version
        self.text = text
        self.sourceURL = sourceURL
        self.sourceTitle = sourceTitle
        self.capturedAt = capturedAt
    }

    private enum CodingKeys: String, CodingKey {
        case version
        case text
        case sourceURL
        case sourceTitle
        case capturedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decode(Int.self, forKey: .version)
        guard version == Self.currentVersion else {
            throw PendingCaptureInboxError.unsupportedVersion
        }
        self.version = version
        text = try container.decode(String.self, forKey: .text)
        sourceURL = try container.decodeIfPresent(URL.self, forKey: .sourceURL)
        sourceTitle = try container.decodeIfPresent(String.self, forKey: .sourceTitle)
        capturedAt = try container.decode(Date.self, forKey: .capturedAt)
    }
}

enum PendingCaptureInboxError: Error, Equatable, LocalizedError {
    case appGroupUnavailable
    case emptyText
    case textTooLarge(maximumBytes: Int)
    case sourceURLInvalid
    case sourceTitleInvalid(maximumBytes: Int)
    case fileTooLarge(maximumBytes: Int)
    case unsupportedVersion
    case corruptData
    case interruptedConsumption
    case ioFailure

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "无法访问共享容器；未保存或读取任何内容。"
        case .emptyText:
            return "共享文本为空，请输入内容后再保存。"
        case let .textTooLarge(maximumBytes):
            return "共享文本过大（上限 \(maximumBytes / 1024) KiB）；内容未截断，也未保存。"
        case .sourceURLInvalid:
            return "共享来源网址无效；内容未保存。"
        case let .sourceTitleInvalid(maximumBytes):
            return "共享来源标题过大或包含无效字符（上限 \(maximumBytes) 字节）；内容未保存。"
        case let .fileTooLarge(maximumBytes):
            return "待处理共享内容文件过大（上限 \(maximumBytes / 1024) KiB），已安全阻断。"
        case .unsupportedVersion:
            return "待处理共享内容版本不受支持，已安全阻断。"
        case .corruptData:
            return "待处理共享内容已损坏，已安全阻断。"
        case .interruptedConsumption:
            return "上次读取共享内容时被中断；请移除该内容后重新分享。"
        case .ioFailure:
            return "无法安全读写待处理共享内容；未访问 Token 或墨墨。"
        }
    }
}

/// One bounded, latest-save-wins JSON inbox shared by the app and extension.
///
/// The pending file is atomically replaced on save. Consumption first atomically
/// claims the pending file, installs the decoded value through a synchronous
/// callback, then deletes the claim so a later launch cannot replay it.
struct PendingCaptureInbox {
    static let appGroupIdentifier = "group.com.jiripple.xiaoheiniao.capture"
    static let maximumTextBytes = 64 * 1024
    static let maximumSourceURLBytes = 2 * 1024
    static let maximumSourceTitleBytes = 1024
    static let maximumFileBytes = 72 * 1024

    private static let pendingFileName = "pending-capture-v1.json"
    private static let claimFileName = ".pending-capture-v1.claimed.json"

    let containerURL: URL
    private let fileManager: FileManager

    init(containerURL: URL, fileManager: FileManager = .default) {
        self.containerURL = containerURL
        self.fileManager = fileManager
    }

    static func appGroup(fileManager: FileManager = .default) throws -> Self {
        guard let containerURL = fileManager.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) else {
            throw PendingCaptureInboxError.appGroupUnavailable
        }
        return Self(containerURL: containerURL, fileManager: fileManager)
    }

    var pendingFileURL: URL {
        containerURL.appendingPathComponent(Self.pendingFileName, isDirectory: false)
    }

    var claimedFileURL: URL {
        containerURL.appendingPathComponent(Self.claimFileName, isDirectory: false)
    }

    func save(_ capture: PendingCapture) throws {
        do {
            try validate(capture)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(capture)
            guard data.count <= Self.maximumFileBytes else {
                throw PendingCaptureInboxError.fileTooLarge(
                    maximumBytes: Self.maximumFileBytes
                )
            }
            try data.write(to: pendingFileURL, options: [.atomic])
        } catch let error as PendingCaptureInboxError {
            throw error
        } catch {
            throw PendingCaptureInboxError.ioFailure
        }
    }

    func load() throws -> PendingCapture? {
        if fileManager.fileExists(atPath: claimedFileURL.path),
           !fileManager.fileExists(atPath: pendingFileURL.path) {
            throw PendingCaptureInboxError.interruptedConsumption
        }
        guard fileManager.fileExists(atPath: pendingFileURL.path) else { return nil }
        return try loadCapture(at: pendingFileURL)
    }

    /// Returns and installs one valid capture, or leaves invalid data recoverable.
    /// A new extension save that races with consumption writes a fresh pending file
    /// and is never deleted when the already-claimed file is removed.
    @discardableResult
    func consume(install: (PendingCapture) -> Void) throws -> PendingCapture? {
        do {
            if fileManager.fileExists(atPath: claimedFileURL.path) {
                if fileManager.fileExists(atPath: pendingFileURL.path) {
                    // A newer normal save wins over an abandoned old claim.
                    try fileManager.removeItem(at: claimedFileURL)
                } else {
                    throw PendingCaptureInboxError.interruptedConsumption
                }
            }
            guard fileManager.fileExists(atPath: pendingFileURL.path) else { return nil }

            try fileManager.moveItem(at: pendingFileURL, to: claimedFileURL)
            let capture: PendingCapture
            do {
                capture = try loadCapture(at: claimedFileURL)
            } catch {
                // Preserve malformed/oversized data at the ordinary pending path so
                // the app can offer an explicit, credential-free removal action.
                if !fileManager.fileExists(atPath: pendingFileURL.path) {
                    try? fileManager.moveItem(at: claimedFileURL, to: pendingFileURL)
                }
                throw error
            }

            install(capture)
            try fileManager.removeItem(at: claimedFileURL)
            return capture
        } catch let error as PendingCaptureInboxError {
            throw error
        } catch {
            throw PendingCaptureInboxError.ioFailure
        }
    }

    /// Recovery is deliberately local-only: it removes inbox files and performs
    /// no credential restoration, Preview, transport or Maimemo request.
    func removePending() throws {
        do {
            for url in [pendingFileURL, claimedFileURL]
            where fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
        } catch {
            throw PendingCaptureInboxError.ioFailure
        }
    }

    private func loadCapture(at url: URL) throws -> PendingCapture {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            if let size = attributes[.size] as? NSNumber,
               size.intValue > Self.maximumFileBytes {
                throw PendingCaptureInboxError.fileTooLarge(
                    maximumBytes: Self.maximumFileBytes
                )
            }
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard data.count <= Self.maximumFileBytes else {
                throw PendingCaptureInboxError.fileTooLarge(
                    maximumBytes: Self.maximumFileBytes
                )
            }
            let capture: PendingCapture
            do {
                capture = try JSONDecoder().decode(PendingCapture.self, from: data)
            } catch let error as PendingCaptureInboxError {
                throw error
            } catch {
                throw PendingCaptureInboxError.corruptData
            }
            try validate(capture)
            return capture
        } catch let error as PendingCaptureInboxError {
            throw error
        } catch {
            throw PendingCaptureInboxError.ioFailure
        }
    }

    private func validate(_ capture: PendingCapture) throws {
        guard capture.version == PendingCapture.currentVersion else {
            throw PendingCaptureInboxError.unsupportedVersion
        }
        guard !capture.text.isEmpty else {
            throw PendingCaptureInboxError.emptyText
        }
        guard capture.text.utf8.count <= Self.maximumTextBytes else {
            throw PendingCaptureInboxError.textTooLarge(
                maximumBytes: Self.maximumTextBytes
            )
        }
        if let sourceURL = capture.sourceURL {
            guard Self.isCleanSourceURL(sourceURL) else {
                throw PendingCaptureInboxError.sourceURLInvalid
            }
        }
        if let title = capture.sourceTitle {
            guard !title.contains("\0"),
                  title.utf8.count <= Self.maximumSourceTitleBytes
            else {
                throw PendingCaptureInboxError.sourceTitleInvalid(
                    maximumBytes: Self.maximumSourceTitleBytes
                )
            }
        }
    }

    static func isCleanSourceURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil,
              url.user == nil,
              url.password == nil
        else { return false }
        return url.absoluteString.utf8.count <= maximumSourceURLBytes
    }
}
