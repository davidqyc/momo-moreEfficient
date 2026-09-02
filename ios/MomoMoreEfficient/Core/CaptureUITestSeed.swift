import Foundation

/// A DEBUG-only UI-test seam for `MomoMoreEfficientUITests`.
///
/// It writes exactly the same non-secret pending capture that a real Share
/// Extension save produces, through the same `PendingCaptureInbox` production
/// code and the same App Group entitlement the app already holds. A UI test
/// can then drive the app's real pending-capture pickup path — the same path
/// a Share save relies on — without XCUIAutomation ever touching the system
/// Share Sheet, the Shortcuts editor, or a second App Group member.
///
/// This can only ever produce the existing pre-Preview review state: it has
/// no route to Preview, credentials or Maimemo write, and it does not exist
/// in a Release build.
enum CaptureUITestSeed {
    static let environmentKey = "MOMO_UITEST_SEED_PENDING_CAPTURE_TEXT"

    static func installIfRequested() {
        #if DEBUG
        guard let text = ProcessInfo.processInfo.environment[environmentKey],
              !text.isEmpty
        else { return }
        // A UI test asserts on the resulting app state, so a failure here
        // simply leaves no pending capture rather than risking a bad write.
        try? PendingCaptureInbox.appGroup().save(
            PendingCapture(text: text, capturedAt: Date())
        )
        #endif
    }
}
