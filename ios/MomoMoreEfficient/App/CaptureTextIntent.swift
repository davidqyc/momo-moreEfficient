import AppIntents
import Foundation

/// A transport-only Shortcut action. Its complete effect is one exact, in-memory
/// capture handoff; it has no route to credentials, Preview or Maimemo transport.
@available(iOS 26.0, *)
struct CaptureTextIntent: AppIntent {
    static let title: LocalizedStringResource = "在小黑鸟伴侣中检查文本"
    static let description = IntentDescription(
        "把文本带到小黑鸟伴侣中编辑和检查；不会自动预览或写入墨墨。"
    )

    @Parameter(
        title: "捕获文本",
        description: "要在小黑鸟伴侣中检查的原文",
        inputOptions: String.IntentInputOptions(
            capitalizationType: .none,
            multiline: true,
            autocorrect: false,
            smartQuotes: false,
            smartDashes: false
        )
    )
    var text: String

    static var parameterSummary: some ParameterSummary {
        Summary("在小黑鸟伴侣中检查 \(\.$text)")
    }

    /// Deferred mode runs `perform()` in the background and foregrounds the app
    /// near the end. The first synchronous statement below installs the review.
    static let supportedModes: IntentModes = [.foreground(.deferred)]

    @MainActor
    func perform() async throws -> some IntentResult {
        let capturedAt = Date()
        CaptureReviewStore.shared.receive(text, capturedAt: capturedAt)
        return .result()
    }
}
