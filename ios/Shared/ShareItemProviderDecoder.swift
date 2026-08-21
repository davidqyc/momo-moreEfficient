import Foundation
import UniformTypeIdentifiers

struct DecodedSharePayload: Equatable {
    let text: String
    let sourceURL: URL?
    let sourceTitle: String?
}

enum ShareItemProviderDecoderError: Error, Equatable, LocalizedError {
    case missingText
    case ambiguousText
    case unreadableText

    var errorDescription: String? {
        switch self {
        case .missingText:
            return "没有找到可编辑的共享文本。"
        case .ambiguousText:
            return "共享内容包含多段不同文本，无法确定要保存哪一段。"
        case .unreadableText:
            return "无法完整读取共享文本；未保存任何内容。"
        }
    }
}

/// Decodes only values supplied directly by the share payload. It performs no
/// webpage fetch, Safari preprocessing, scraping, history access or enrichment.
struct ShareItemProviderDecoder {
    func decode(_ extensionItems: [NSExtensionItem]) async throws -> DecodedSharePayload {
        var texts: [String] = []
        var sourceURLs: [URL] = []
        var sourceTitles: [String] = []

        for extensionItem in extensionItems {
            if let text = extensionItem.attributedContentText?.string {
                appendUnique(text, to: &texts)
            }
            if let title = cleanTitle(extensionItem.attributedTitle?.string) {
                appendUnique(title, to: &sourceTitles)
            }

            for provider in extensionItem.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                    do {
                        let item = try await loadItem(
                            provider,
                            typeIdentifier: UTType.plainText.identifier
                        )
                        guard let text = decodeText(item) else {
                            throw ShareItemProviderDecoderError.unreadableText
                        }
                        appendUnique(text, to: &texts)
                    } catch let error as ShareItemProviderDecoderError {
                        throw error
                    } catch {
                        throw ShareItemProviderDecoderError.unreadableText
                    }
                }

                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let item = try? await loadItem(
                    provider,
                    typeIdentifier: UTType.url.identifier
                   ),
                   let url = decodeURL(item),
                   PendingCaptureInbox.isCleanSourceURL(url) {
                    appendUnique(url, to: &sourceURLs)
                }
            }
        }

        guard !texts.isEmpty else { throw ShareItemProviderDecoderError.missingText }
        guard texts.count == 1 else { throw ShareItemProviderDecoderError.ambiguousText }

        let sourceURL = sourceURLs.count == 1 ? sourceURLs[0] : nil
        let sourceTitle = sourceURL != nil && sourceTitles.count == 1
            ? sourceTitles[0] : nil
        return DecodedSharePayload(
            text: texts[0],
            sourceURL: sourceURL,
            sourceTitle: sourceTitle
        )
    }

    private func loadItem(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }

    private func decodeText(_ item: NSSecureCoding?) -> String? {
        switch item {
        case let string as String:
            return string
        case let string as NSString:
            return string as String
        case let attributed as NSAttributedString:
            return attributed.string
        case let data as Data:
            return String(data: data, encoding: .utf8)
        default:
            return nil
        }
    }

    private func decodeURL(_ item: NSSecureCoding?) -> URL? {
        switch item {
        case let url as URL:
            return url
        case let url as NSURL:
            return url as URL
        case let string as String:
            return URL(string: string)
        case let string as NSString:
            return URL(string: string as String)
        case let data as Data:
            guard let string = String(data: data, encoding: .utf8) else { return nil }
            return URL(string: string)
        default:
            return nil
        }
    }

    private func cleanTitle(_ title: String?) -> String? {
        guard let title,
              !title.isEmpty,
              !title.contains("\0"),
              title.utf8.count <= PendingCaptureInbox.maximumSourceTitleBytes
        else { return nil }
        return title
    }

    private func appendUnique<T: Equatable>(_ value: T, to values: inout [T]) {
        if !values.contains(value) {
            values.append(value)
        }
    }
}
