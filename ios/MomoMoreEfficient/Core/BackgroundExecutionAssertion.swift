import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// A finite, OS-sanctioned window in which an already-authorized write batch may
/// keep running after the app stops being frontmost.
///
/// The assertion is taken while the app is still in the foreground, at the moment
/// the Owner completes the native confirmation, and released as soon as the batch
/// resolves. `onExpiration` is the system telling us the window is closing: it must
/// stop further work, never start any.
///
/// This is deliberately the only background mechanism used. See `docs/` and the
/// pull request for #75 for why `BGContinuedProcessingTask` is not adopted here.
@MainActor
protocol BackgroundExecutionAssertion: AnyObject {
    /// Takes the assertion. Calling twice without an intervening `end()` is a no-op.
    /// - Parameter onExpiration: invoked when the system is about to reclaim the app.
    ///   It may run on any thread and must only request cancellation.
    func begin(reason: String, onExpiration: @escaping @Sendable () -> Void)

    /// Releases the assertion. Safe to call when nothing is held.
    func end()
}

#if canImport(UIKit)
/// `UIApplication.beginBackgroundTask(withName:expirationHandler:)`.
///
/// Available since iOS 4 and therefore usable at the project's iOS 18.0 deployment
/// target without a version gate. The system grants a short, unspecified amount of
/// time; the amount is deliberately not relied upon anywhere. Expiry is handled by
/// the same cancellation path as any other interruption.
@MainActor
final class UIApplicationBackgroundExecutionAssertion: BackgroundExecutionAssertion {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    func begin(reason: String, onExpiration: @escaping @Sendable () -> Void) {
        guard identifier == .invalid else { return }
        identifier = UIApplication.shared.beginBackgroundTask(withName: reason) { [weak self] in
            // Last chance before the system suspends us: stop dispatching. This
            // never retries, never resumes and never starts a new request.
            onExpiration()
            MainActor.assumeIsolated { self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        UIApplication.shared.endBackgroundTask(identifier)
        identifier = .invalid
    }
}
#endif

/// Used where UIKit is unavailable. Holding no assertion is always safe: the batch
/// simply gets whatever time the platform already gives it, and any interruption
/// still resolves through the ordinary cancellation path.
@MainActor
final class UnsupportedBackgroundExecutionAssertion: BackgroundExecutionAssertion {
    func begin(reason: String, onExpiration: @escaping @Sendable () -> Void) {}
    func end() {}
}

@MainActor
func makeDefaultBackgroundExecutionAssertion() -> BackgroundExecutionAssertion {
    #if canImport(UIKit)
    return UIApplicationBackgroundExecutionAssertion()
    #else
    return UnsupportedBackgroundExecutionAssertion()
    #endif
}
