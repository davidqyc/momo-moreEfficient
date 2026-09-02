import XCTest

/// The real, out-of-process App Intents Testing lane for `CaptureTextIntent`
/// (ios/MomoMoreEfficient/App/CaptureTextIntent.swift) — the primary
/// deliverable of issue #165.
///
/// `AppIntentsTesting` requires iOS/iPadOS 27.0+ (Beta):
/// https://developer.apple.com/documentation/appintentstesting
///
/// As of this commit the project's installed toolchain is Xcode 26.6 / iOS
/// 26.5 SDK, in which `AppIntentsTesting` does not exist — confirmed by
/// searching the installed SDKs for any matching framework or
/// `.swiftmodule`/`.swiftinterface`, and by finding no "test"-related symbol
/// in `AppIntents.framework`'s own public interface. `#if canImport` compiles
/// this entire file out there, so it adds no risk to the current build and
/// this lane does not run on the current toolchain or on a CI runner using
/// the same stable Xcode.
///
/// The code below is written from Apple's current official code samples
/// ("Testing your App Intents code", fetched 2026-09-03) so the real
/// App-Intent-infrastructure lane activates automatically — with, at most,
/// small API-shape fixes — the moment a toolchain with the iOS 27 SDK builds
/// this target. It has not been compiled or executed anywhere; its exact API
/// shape is unverified until such a toolchain exists.
#if canImport(AppIntentsTesting)
import AppIntentsTesting

@available(iOS 27.0, *)
final class CaptureAppIntentUITests: XCTestCase {
    private let app = XCUIApplication()
    private var definitions: IntentDefinitions!
    private let syntheticPayload = "XHN-UI-INTENT-20260903"

    override func setUp() async throws {
        continueAfterFailure = false
        app.launch()
        definitions = IntentDefinitions(bundleIdentifier: "com.jiripple.xiaoheiniao")
    }

    /// Proves the current capture intent is discoverable by the system the
    /// way Siri/Shortcuts discover it — by string name through
    /// `IntentDefinitions`, not by importing `AppIntents` and constructing
    /// `CaptureTextIntent` directly.
    func testCaptureTextIntent_isDiscoverable() throws {
        _ = definitions.intents["CaptureTextIntent"]
    }

    /// Runs the real, registered `CaptureTextIntent` through the real App
    /// Intents infrastructure — not `CaptureTextIntent().perform()` called
    /// directly as a unit test — with a synthetic "抓词内容" payload, and
    /// asserts the app reaches the same pre-Preview review state
    /// `CapturePendingReviewUITests` observes via the Share-equivalent path.
    /// Stops at the safe cancellation action; never reaches Preview or write.
    func testCaptureTextIntent_deliversSyntheticPayloadToPrePreviewReview() async throws {
        let intent = definitions.intents["CaptureTextIntent"]
        _ = try await intent.makeIntent(text: syntheticPayload).run()

        let status = app.descendants(matching: .any)["captureReviewStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        let editor = app.textViews["captureReviewTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, syntheticPayload)

        app.buttons["cancelCaptureButton"].tap()
        XCTAssertFalse(status.waitForExistence(timeout: 2))
    }
}
#endif
