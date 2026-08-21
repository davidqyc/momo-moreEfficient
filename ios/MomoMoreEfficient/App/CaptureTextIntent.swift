import AppIntents

/// A transport-only Shortcut action. Its complete effect is one exact, in-memory
/// capture handoff; it has no route to credentials, Preview or Maimemo transport.
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

    /// `supportedModes` is Apple's current foreground-execution API. Deferred
    /// foregrounding lets this zero-I/O handoff land before the review UI appears.
    @available(iOS 26.0, *)
    static let supportedModes: IntentModes = [.foreground(.deferred)]

    /// The app still deploys to iOS 18. This availability-isolated compatibility
    /// witness is invisible from iOS 26 onward, where `supportedModes` is used.
    @available(iOS, introduced: 18.0, obsoleted: 26.0)
    static var openAppWhenRun: Bool { true }

    @MainActor
    func perform() async throws -> some IntentResult {
        CaptureReviewStore.shared.receive(text)
        return .result()
    }
}
