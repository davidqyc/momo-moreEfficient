import XCTest

/// Real, on-simulator/on-device UI regression for the capture pre-Preview
/// review surface, exercised through the app's real pending-capture pickup
/// path — the same path a Share Extension save relies on.
///
/// `CaptureUITestSeed` (ios/MomoMoreEfficient/Core/CaptureUITestSeed.swift,
/// DEBUG-only) writes a synthetic capture into the real App Group inbox
/// before the app's first scene-active transition; from that point every step
/// — `PendingCaptureInbox.consume()`, `CaptureReviewForegroundGate.activate`,
/// `CaptureReviewStore`, `ContentView` — is unmodified production code. This
/// does not require the App Intents Testing framework (iOS 27.0+ Beta, not
/// present in this toolchain — see `CaptureAppIntentUITests.swift`) and does
/// not touch the system Share Sheet or the Shortcuts editor.
final class CapturePendingReviewUITests: XCTestCase {
    private static let syntheticPayload = "XHN-UI-INTENT-20260903"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testPendingCapture_reachesPrePreviewReviewState_withExactPayload() throws {
        let app = launchApp(seedingPendingCapture: Self.syntheticPayload)

        XCTAssertTrue(app.navigationBars["抓词"].waitForExistence(timeout: 10))

        let status = app.descendants(matching: .any)["captureReviewStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))

        let editor = app.textViews["captureReviewTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, Self.syntheticPayload)
    }

    func testPendingCapture_cancelReturnsToNormalState() throws {
        let app = launchApp(seedingPendingCapture: Self.syntheticPayload)

        let status = app.descendants(matching: .any)["captureReviewStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        let cancelButton = app.buttons["cancelCaptureButton"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()

        XCTAssertFalse(status.waitForExistence(timeout: 2))
        XCTAssertFalse(app.textViews["captureReviewTextEditor"].exists)
    }

    private func launchApp(seedingPendingCapture text: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UITEST_SEED_PENDING_CAPTURE_TEXT"] = text
        app.launch()
        return app
    }
}
