#if DEBUG
import UIKit

/// A DEBUG-only UI-test seam for `MomoMoreEfficientUITests`.
///
/// A #165 bounded XCUIAutomation feasibility probe found this app's real
/// Share Extension row reliably accessibility-selectable in the live system
/// Share Sheet (no coordinates, no second host app), so this seam is kept —
/// see `MomoMoreEfficientUITests/CaptureShareSheetUITests.swift`.
///
/// It presents the real system `UIActivityViewController` from this app's own
/// key window with synthetic text — the standard, in-process way to reach the
/// Share Sheet, not a second app. The entire declaration is compiled out of
/// Release builds, not just its body.
enum ShareSheetProbe {
    static let environmentKey = "MOMO_UITEST_SHARE_SHEET_PROBE_TEXT"

    @MainActor
    static func presentIfRequested() async {
        guard let text = ProcessInfo.processInfo.environment[environmentKey],
              !text.isEmpty
        else { return }

        for _ in 0..<20 {
            if let root = keyWindowRootViewController(), root.presentedViewController == nil {
                let activityVC = UIActivityViewController(activityItems: [text], applicationActivities: nil)
                root.present(activityVC, animated: true)
                return
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    @MainActor
    private static func keyWindowRootViewController() -> UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }
}
#endif
