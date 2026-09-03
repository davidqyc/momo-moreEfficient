import Foundation

/// Enforces Maimemo's documented aggregate request-frequency windows without a
/// fixed per-request delay (#168). Reads, the read-semantic vocabulary-query
/// POST, and mutating writes all draw from the same ledger and stay strictly
/// sequential: the caller sends the next request immediately unless a real
/// window would otherwise be exceeded, in which case this reports exactly how
/// long to wait for a slot to free up.
///
/// State is a single in-memory dispatch-timestamp log bounded by the longest
/// configured window (5 hours for the current Maimemo limits); nothing is
/// persisted to disk, so it starts empty on every process launch and needs no
/// dedicated persistence subsystem for the long window.
///
/// A plain lock-protected class, not an actor, matching `ExecutionControl`'s
/// existing pattern for state shared across a `@MainActor` caller and the
/// non-isolated `MaimemoTransport`/`RequestSleeper` call chain: `pace()` must
/// call this synchronously from within its own wait loop, and an actor hop
/// here forced a MainActor-vs-executor ordering the caller does not control.
final class RequestWindowScheduler: @unchecked Sendable {
    struct Window: Equatable, Sendable {
        let limit: Int
        let duration: TimeInterval
    }

    /// Maimemo's current documented aggregate limits for the vocabulary
    /// service (Issue #168): 20 requests / 10 seconds, 40 / 60 seconds, and
    /// 2000 / 5 hours.
    static let maimemoWindows: [Window] = [
        Window(limit: 20, duration: 10),
        Window(limit: 40, duration: 60),
        Window(limit: 2_000, duration: 5 * 60 * 60),
    ]

    private let windows: [Window]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var dispatchTimestamps: [Date] = []

    init(
        windows: [Window] = RequestWindowScheduler.maimemoWindows,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.windows = windows
        self.now = now
    }

    /// Reserves the next sequential dispatch slot and returns how long
    /// (seconds, `>= 0`) the caller must wait before actually sending the
    /// request. The reservation is recorded immediately at the predicted
    /// dispatch time (`now() + wait`), so a caller that has not yet performed
    /// the wait still gets a correct answer from the next call.
    func reserveNextSlot() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        let currentTime = now()
        prune(before: currentTime)
        let wait = requiredWait(at: currentTime)
        dispatchTimestamps.append(currentTime.addingTimeInterval(wait))
        return wait
    }

    private func prune(before referenceTime: Date) {
        guard let longestDuration = windows.map(\.duration).max() else { return }
        let cutoff = referenceTime.addingTimeInterval(-longestDuration)
        dispatchTimestamps.removeAll { $0 <= cutoff }
    }

    /// Standard sliding-window-log computation, taken over every configured
    /// window: once a window already holds `limit` timestamps, a new slot only
    /// opens once enough of the oldest ones age past `duration`.
    ///
    /// The boundary is strictly exclusive (`>`, not `>=`) so a timestamp exactly
    /// `duration` old has fully left the window; a caller that waits exactly the
    /// returned amount and asks again immediately must see that slot as free,
    /// not require an extra instant on top.
    private func requiredWait(at currentTime: Date) -> TimeInterval {
        windows.reduce(0) { longestWait, window in
            let windowStart = currentTime.addingTimeInterval(-window.duration)
            let withinWindow = dispatchTimestamps.filter { $0 > windowStart }.sorted()
            guard withinWindow.count >= window.limit else { return longestWait }
            let freeingTimestamp = withinWindow[withinWindow.count - window.limit]
            let readyAt = freeingTimestamp.addingTimeInterval(window.duration)
            return max(longestWait, readyAt.timeIntervalSince(currentTime))
        }
    }
}
