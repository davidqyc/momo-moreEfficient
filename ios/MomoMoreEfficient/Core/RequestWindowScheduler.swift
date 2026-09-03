import Foundation

/// Enforces Maimemo's documented aggregate request-frequency windows without a
/// fixed per-request delay (#168). Reads, the read-semantic vocabulary-query
/// POST, and mutating writes all draw from the same ledger and stay strictly
/// sequential: the caller sends the next request immediately unless a real
/// window would otherwise be exceeded, in which case this reports exactly how
/// long to wait for a slot to free up.
///
/// Elapsed time comes from `ContinuousClock`, never from `Date`/civil time.
/// `ContinuousClock` always increments and keeps advancing while the system is
/// asleep, whereas the system/civil clock can be changed independently of real
/// elapsed time (a user edit, an NTP correction, a time-zone or DST change —
/// which is exactly why Foundation publishes system-clock-change
/// notifications). A forward civil-time jump must never age a dispatch entry
/// out of a provider window before the real 10s / 60s / 5h has elapsed, so the
/// ledger measures the only quantity the provider limits actually care about:
/// monotonic elapsed time.
///
/// State is a single in-memory dispatch log bounded by the longest configured
/// window (5 hours for the current Maimemo limits); nothing is persisted to
/// disk, so it starts empty on every process launch and needs no dedicated
/// persistence subsystem for the long window.
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
        /// A monotonic dispatch instant, not a civil timestamp.
        var instant: ContinuousClock.Instant
    }

    private let windows: [Window]
    private let now: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    private var entries: [Entry] = []

    /// - Parameter now: the monotonic elapsed-time source. Production uses
    ///   `ContinuousClock.now`; tests inject a manually-advanced instant so
    ///   window math stays deterministic and never touches real time.
    init(
        windows: [Window] = RequestWindowScheduler.maimemoWindows,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.windows = windows
        self.now = now
    }

    /// Reserves the next sequential dispatch slot and returns how long
    /// (seconds, `>= 0`) the caller must wait before actually sending the
    /// request, plus a ticket standing for that reservation.
    ///
    /// The ledger entry starts at the *predicted* dispatch instant
    /// (`now() + wait`) purely so a second `reserveNextSlot()` call made
    /// before this one resolves still sees a conservative answer. A
    /// predicted instant is not dispatch truth, though: real sleep can overrun
    /// it, and a wait can be aborted before ever dispatching. The caller
    /// MUST resolve the ticket once the outcome is known:
    /// - `confirmDispatch(_:)` right before the request actually goes out,
    ///   so the ledger reflects reality even under oversleep;
    /// - `cancelReservation(_:)` if it never dispatches, so no phantom entry
    ///   survives to block a later request.
    func reserveNextSlot() -> (wait: TimeInterval, ticket: ReservationTicket) {
        lock.lock()
        defer { lock.unlock() }
        let currentInstant = now()
        prune(before: currentInstant)
        let wait = requiredWait(at: currentInstant)
        let id = UUID()
        entries.append(Entry(id: id, instant: currentInstant.advanced(by: .seconds(wait))))
        return (wait, ReservationTicket(id: id))
    }

    /// Reconciles a reservation to the moment its request is actually about
    /// to dispatch. Takes the later of the predicted and actual instant, so a
    /// sleep that resumed on schedule (or a test double that never really
    /// delays) keeps the predicted spacing, while a real overshoot can only
    /// push the ledger to be *more* conservative, never less. A no-op if the
    /// ticket was already resolved.
    func confirmDispatch(_ ticket: ReservationTicket) {
        lock.lock()
        defer { lock.unlock() }
        guard let index = entries.firstIndex(where: { $0.id == ticket.id }) else { return }
        entries[index].instant = max(entries[index].instant, now())
    }

    /// Removes a reservation that never turned into an actual dispatch (an
    /// aborted wait, or a caller that decided not to send after all), so it
    /// cannot count as phantom usage against any window.
    func cancelReservation(_ ticket: ReservationTicket) {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll { $0.id == ticket.id }
    }

    private func prune(before referenceInstant: ContinuousClock.Instant) {
        guard let longestDuration = windows.map(\.duration).max() else { return }
        let cutoff = referenceInstant.advanced(by: .seconds(-longestDuration))
        entries.removeAll { $0.instant <= cutoff }
    }

    /// Standard sliding-window-log computation, taken over every configured
    /// window: once a window already holds `limit` entries, a new slot only
    /// opens once enough of the oldest ones age past `duration` of monotonic
    /// elapsed time.
    ///
    /// The boundary is strictly exclusive (`>`, not `>=`) so an entry exactly
    /// `duration` old has fully left the window; a caller that waits exactly the
    /// returned amount and asks again immediately must see that slot as free,
    /// not require an extra instant on top.
    private func requiredWait(at currentInstant: ContinuousClock.Instant) -> TimeInterval {
        windows.reduce(0) { longestWait, window in
            let windowStart = currentInstant.advanced(by: .seconds(-window.duration))
            let withinWindow = entries.map(\.instant).filter { $0 > windowStart }.sorted()
            guard withinWindow.count >= window.limit else { return longestWait }
            let freeingInstant = withinWindow[withinWindow.count - window.limit]
            let readyAt = freeingInstant.advanced(by: .seconds(window.duration))
            return max(longestWait, Self.seconds(currentInstant.duration(to: readyAt)))
        }
    }

    private static func seconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
    }
}
