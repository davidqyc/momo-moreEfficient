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

    /// An opaque handle for one reserved-but-unresolved slot, returned by
    /// `reserveNextSlot()`. The caller must resolve it exactly once, with
    /// either `confirmDispatch(_:)` or `cancelReservation(_:)` — see both.
    struct ReservationTicket: Sendable {
        fileprivate let id: UUID
    }

    /// Maimemo's current documented aggregate limits for the vocabulary
    /// service (Issue #168): 20 requests / 10 seconds, 40 / 60 seconds, and
    /// 2000 / 5 hours.
    static let maimemoWindows: [Window] = [
        Window(limit: 20, duration: 10),
        Window(limit: 40, duration: 60),
        Window(limit: 2_000, duration: 5 * 60 * 60),
    ]

    private struct Entry {
        let id: UUID
        var timestamp: Date
    }

    private let windows: [Window]
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [Entry] = []

    init(
        windows: [Window] = RequestWindowScheduler.maimemoWindows,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.windows = windows
        self.now = now
    }

    /// Reserves the next sequential dispatch slot and returns how long
    /// (seconds, `>= 0`) the caller must wait before actually sending the
    /// request, plus a ticket standing for that reservation.
    ///
    /// The ledger entry starts at the *predicted* dispatch time
    /// (`now() + wait`) purely so a second `reserveNextSlot()` call made
    /// before this one resolves still sees a conservative answer. A
    /// predicted time is not dispatch truth, though: real sleep can overrun
    /// it, and a wait can be aborted before ever dispatching. The caller
    /// MUST resolve the ticket once the outcome is known:
    /// - `confirmDispatch(_:)` right before the request actually goes out,
    ///   so the ledger reflects reality even under oversleep;
    /// - `cancelReservation(_:)` if it never dispatches, so no phantom entry
    ///   survives to block a later request.
    func reserveNextSlot() -> (wait: TimeInterval, ticket: ReservationTicket) {
        lock.lock()
        defer { lock.unlock() }
        let currentTime = now()
        prune(before: currentTime)
        let wait = requiredWait(at: currentTime)
        let id = UUID()
        entries.append(Entry(id: id, timestamp: currentTime.addingTimeInterval(wait)))
        return (wait, ReservationTicket(id: id))
    }

    /// Reconciles a reservation to the moment its request is actually about
    /// to dispatch. Takes the later of the predicted and actual time, so a
    /// sleep that resumed on schedule (or a test double that never really
    /// delays) keeps the predicted spacing, while a real overshoot can only
    /// push the ledger to be *more* conservative, never less. A no-op if the
    /// ticket was already resolved.
    func confirmDispatch(_ ticket: ReservationTicket) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == ticket.id }) else { return }
        entries[index].timestamp = max(entries[index].timestamp, now())
    }

    /// Removes a reservation that never turned into an actual dispatch (an
    /// aborted wait, or a caller that decided not to send after all), so it
    /// cannot count as phantom usage against any window.
    func cancelReservation(_ ticket: ReservationTicket) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.id == ticket.id }
    }

    private func prune(before referenceTime: Date) {
        guard let longestDuration = windows.map(\.duration).max() else { return }
        let cutoff = referenceTime.addingTimeInterval(-longestDuration)
        entries.removeAll { $0.timestamp <= cutoff }
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
            let withinWindow = entries.map(\.timestamp).filter { $0 > windowStart }.sorted()
            guard withinWindow.count >= window.limit else { return longestWait }
            let freeingTimestamp = withinWindow[withinWindow.count - window.limit]
            let readyAt = freeingTimestamp.addingTimeInterval(window.duration)
            return max(longestWait, readyAt.timeIntervalSince(currentTime))
        }
    }
}
