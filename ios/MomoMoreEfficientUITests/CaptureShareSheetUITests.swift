import XCTest

/// Real, deterministic end-to-end Share regression:
///
/// synthetic text -> real system Share Sheet -> "小黑鸟伴侣" extension row
/// -> real ShareExtension UI -> "保存" -> main app pending capture ->
/// "抓词 · 尚未预览" with the exact payload.
///
/// A #165 bounded XCUIAutomation feasibility probe found this route reliably
/// accessibility-selectable — no coordinates, no fixed row-ordering
/// assumption, no second host app — so it is kept as a repeatable test
/// rather than classified as manual smoke.
///
/// The system Share Sheet is triggered in-process from this app's own key
/// window by `ShareSheetProbe` (ios/MomoMoreEfficient/Core/ShareSheetProbe.swift,
/// DEBUG-only) presenting a real `UIActivityViewController` with synthetic
/// text — the standard way to reach the Share Sheet, not a second app.
///
/// The extension's real display name, from `ShareExtension/Info.plist`
/// `CFBundleDisplayName`, is `小黑鸟伴侣` — that is the row label the system
/// Share Sheet actually shows, not the extension's own in-extension title
/// `保存到小黑鸟伴侣`.
final class CaptureShareSheetUITests: XCTestCase {
    // Dated so a run cannot be satisfied by a capture an earlier run left
    // unconsumed in the real App Group inbox: the exact-payload assertion
    // below must only ever be able to pass on this run's own save.
    private static let syntheticPayload = "XHN-UI-SHARE-PROBE-20260904"

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testShareSheet_selectExtensionSaveReachesPrePreviewReviewState_withExactPayload() throws {
        let app = XCUIApplication()
        app.launchEnvironment["MOMO_UITEST_SHARE_SHEET_PROBE_TEXT"] = Self.syntheticPayload
        app.launch()

        // The system Share Sheet is presented modally over our own app; its
        // elements are queryable through the same XCUIApplication instance
        // — no coordinates, no assumption about row position.
        let extensionRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "小黑鸟伴侣"))
            .firstMatch
        XCTAssertTrue(
            extensionRow.waitForExistence(timeout: 15),
            "Share Sheet extension row for '小黑鸟伴侣' was not accessibility-selectable"
        )
        extensionRow.tap()

        // The extension's own UI runs in a separate process
        // (com.jiripple.xiaoheiniao.ShareExtension) but stays reachable
        // through the same XCUIApplication instance once opened.
        let extensionTitle = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "保存到小黑鸟伴侣"))
            .firstMatch
        XCTAssertTrue(
            extensionTitle.waitForExistence(timeout: 10),
            "Share Extension's own UI was not reachable through the presenting app's XCUIApplication instance"
        )

        let saveButton = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "保存"))
            .firstMatch
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        saveButton.tap()

        // `ShareViewController.saveCapture()` reaches
        // `extensionContext.completeRequest(...)` only after
        // `PendingCaptureInbox.save(...)` returns without throwing; a save
        // failure instead keeps this extension UI on screen with a red status.
        // So the extension actually going away is the observable proof that
        // the real App Group write completed. Assert it before touching app
        // lifecycle, otherwise a missing capture cannot be attributed to
        // either the extension write or the main-app pickup.
        XCTAssertTrue(
            extensionTitle.waitForNonExistence(timeout: 10),
            "Share Extension never completed/dismissed, so PendingCaptureInbox.save did not succeed"
        )

        // A same-app-triggered Share Sheet does not necessarily background
        // our own app the way a real cross-app share (e.g. from Notes)
        // would, so the production scenePhase-driven pickup may not
        // otherwise re-fire. Force the same background/foreground cycle a
        // real cross-app share induces.
        //
        // `XCUIDevice.shared.press(.home)` cannot drive that cycle on the
        // physical iPhone this gate runs on: measured in isolation, with no
        // Share Sheet involved at all, the app still never leaves
        // `.runningForeground` after the press (it does on the Simulator).
        // Activating SpringBoard reaches the very home screen the press was
        // meant to reach, and unlike the press it actually backgrounds us.
        // Assert the app really left the foreground, so a future regression
        // here can never again be mistaken for a lost capture.
        XCUIApplication(bundleIdentifier: "com.apple.springboard").activate()
        let leftForeground = XCTNSPredicateExpectation(
            predicate: NSPredicate { application, _ in
                (application as? XCUIApplication)?.state != .runningForeground
            },
            object: app
        )
        XCTAssertEqual(
            XCTWaiter().wait(for: [leftForeground], timeout: 10),
            .completed,
            "App never left the foreground, so no foreground transition could drive pickup"
        )

        app.activate()
        XCTAssertEqual(app.state, .runningForeground)

        // Back in the main app: the same production pending-capture pickup
        // path `CapturePendingReviewUITests` exercises through the App-Group
        // seed, now reached through the real Share Extension write instead.
        let status = app.descendants(matching: .any)["captureReviewStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))

        let editor = app.textViews["captureReviewTextEditor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        XCTAssertEqual(editor.value as? String, Self.syntheticPayload)

        app.buttons["cancelCaptureButton"].tap()
    }
}
