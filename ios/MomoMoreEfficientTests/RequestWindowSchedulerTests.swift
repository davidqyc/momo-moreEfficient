import XCTest
@testable import MomoMoreEfficient

/// #168: the sequential aggregate-window limiter that replaced the blanket
/// 1.6s read-pacing floor. These tests drive `RequestWindowScheduler` directly
/// with a deterministic, manually-advanced clock — never real time or real
/// sleep — so window-boundary math is exact and fast.
final class RequestWindowSchedulerTests: XCTestCase {

    // MARK: - Documented limits

    func testMaimemoWindowsMatchTheDocumentedProviderLimits() {
        XCTAssertEqual(RequestWindowScheduler.maimemoWindows, [
            .init(limit: 20, duration: 10),
            .init(limit: 40, duration: 60),
            .init(limit: 2_000, duration: 5 * 60 * 60),
        ])
    }

    // MARK: - No artificial floor under normal load

    /// The whole point of #168: ordinary Preview sizes must not pay any
    /// per-request wait at all, unlike the old fixed 1.6s-per-request floor.
    func testNoWaitWellUnderEveryWindow() async {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(now: clock.now)
        for _ in 0..<10 {
            let wait = scheduler.reserveNextSlot().wait
            XCTAssertEqual(wait, 0)
            clock.advance(by: wait)
        }
    }

    /// Representative #168 acceptance fixtures: an 8-item Preview costs 9
    /// requests (1 batch vocabulary query + 8 content reads) and a 15-item
    /// Preview costs 16. Both stay far under the 20/10s ceiling, so neither
    /// should see a single second of artificial wait — a material reduction
    /// from the old ~12.8s / ~24.0s (`1.6 * (requestCount - 1)`) floor.
    func testRepresentative8And15ItemPreviewsPayNoArtificialWait() async {
        for requestCount in [9, 16] {
            let clock = TestClock()
            let scheduler = RequestWindowScheduler(now: clock.now)
            var totalWait: TimeInterval = 0
            for _ in 0..<requestCount {
                let wait = scheduler.reserveNextSlot().wait
                totalWait += wait
                clock.advance(by: wait)
            }
            XCTAssertEqual(totalWait, 0, "\(requestCount) requests")
            let oldFixedFloor = 1.6 * Double(requestCount - 1)
            XCTAssertLessThan(totalWait, oldFixedFloor, "\(requestCount) requests")
        }
    }

    // MARK: - A single window forces a wait once its limit is reached

    func testShortestWindowForcesWaitOnceItsLimitIsReached() async {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 3, duration: 10)],
            now: clock.now
        )
        for _ in 0..<3 {
            let wait = scheduler.reserveNextSlot().wait
            XCTAssertEqual(wait, 0)
            clock.advance(by: wait)
        }

        let fourthWait = scheduler.reserveNextSlot().wait
        XCTAssertEqual(fourthWait, 10, accuracy: 0.0001)
        clock.advance(by: fourthWait)

        // Waiting exactly the reported amount frees the oldest slot again.
        let fifthWait = scheduler.reserveNextSlot().wait
        XCTAssertEqual(fifthWait, 0, accuracy: 0.0001)
    }

    func testWaitingLessThanReportedStillBlocksTheNextRequest() async {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 1, duration: 10)],
            now: clock.now
        )
        let firstWait = scheduler.reserveNextSlot().wait
        XCTAssertEqual(firstWait, 0)

        clock.advance(by: 4)
        let secondWait = scheduler.reserveNextSlot().wait
        XCTAssertEqual(secondWait, 6, accuracy: 0.0001, "10s window, only 4s elapsed")
    }

    // MARK: - Multiple windows are enforced simultaneously

    /// A short window can clear repeatedly while a longer window still binds,
    /// exactly the 10s-vs-60s relationship the real Maimemo limits have.
    func testLongerWindowBindsAcrossRepeatedShortWindowCycles() async {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(
            windows: [
                .init(limit: 2, duration: 10),
                .init(limit: 5, duration: 100),
            ],
            now: clock.now
        )
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            let wait = scheduler.reserveNextSlot().wait
            waits.append(wait)
            clock.advance(by: wait)
        }

        // Requests 1-2 are free. Request 3 waits out the 10s short window.
        // By request 6, five requests already sit inside the still-open 100s
        // window, so the short window keeps clearing every cycle but the
        // long window now forces a wait bigger than the short window's own
        // 10s ceiling could ever produce on its own.
        XCTAssertEqual(waits[0], 0)
        XCTAssertEqual(waits[1], 0)
        XCTAssertGreaterThan(waits[2], 0, "short window should bind here")
        XCTAssertLessThanOrEqual(waits[2], 10, "still bounded by the short window")
        XCTAssertGreaterThan(waits[5], 10, "long window must now dominate")
    }

    // MARK: - No burst ever exceeds a configured window (black-box invariant)

    /// Drives a longer, mixed-pace sequence of reservations — with the caller
    /// always honoring the reported wait, exactly like real `pace()` usage —
    /// then independently re-scans the full recorded timestamp log and checks
    /// that no window ever saw more than its documented limit inside any of
    /// its own `duration`-length trailing intervals. This does not trust the
    /// scheduler's own bookkeeping; it re-derives compliance from the raw
    /// timestamps it produced.
    func testNoWindowEverExceedsItsDocumentedCountUnderContinuousLoad() async {
        let clock = TestClock()
        let windows: [RequestWindowScheduler.Window] = [
            .init(limit: 5, duration: 10),
            .init(limit: 12, duration: 60),
        ]
        let scheduler = RequestWindowScheduler(windows: windows, now: clock.now)

        var dispatchTimes: [ContinuousClock.Instant] = []
        for _ in 0..<80 {
            let wait = scheduler.reserveNextSlot().wait
            clock.advance(by: wait)
            dispatchTimes.append(clock.now())
        }

        for window in windows {
            for dispatchTime in dispatchTimes {
                let windowStart = dispatchTime.advanced(by: .seconds(-window.duration))
                let countInWindow = dispatchTimes.filter { $0 > windowStart && $0 <= dispatchTime }.count
                XCTAssertLessThanOrEqual(
                    countInWindow,
                    window.limit,
                    "window limit=\(window.limit) duration=\(window.duration) violated at \(dispatchTime)"
                )
            }
        }
    }

    // MARK: - The real 5-hour / 2000-request ceiling

    func testLongWindowForcesWaitAfterDocumentedRequestCeiling() async {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 5, duration: 5 * 60 * 60)],
            now: clock.now
        )
        for _ in 0..<5 {
            let wait = scheduler.reserveNextSlot().wait
            XCTAssertEqual(wait, 0)
            clock.advance(by: wait)
        }
        let sixthWait = scheduler.reserveNextSlot().wait
        XCTAssertEqual(sixthWait, 5 * 60 * 60, accuracy: 0.0001)
    }

    // MARK: - Actual dispatch reconciliation (#168 repair)

    /// A real sleep can overshoot its predicted wake time (scheduling jitter,
    /// background suspension, etc). The ledger must reconcile to the ACTUAL
    /// dispatch time once it is known, or a later request could be judged
    /// ready too early — less conservative than the real elapsed time demands.
    func testConfirmDispatchReconcilesToActualTimeNotThePredictedOne() {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 1, duration: 10)],
            now: clock.now
        )
        let first = scheduler.reserveNextSlot()
        XCTAssertEqual(first.wait, 0)

        // The real dispatch happens 3s later than predicted (an oversleep).
        clock.advance(by: 3)
        scheduler.confirmDispatch(first.ticket)

        // A ledger that kept the predicted t=0 timestamp would think the
        // window clears again at t=10 — only 7s away from here (t=3).
        // Reconciled to the real t=3 dispatch, the next slot is not free
        // until t=13: a full 10s away from now, not 7s.
        let second = scheduler.reserveNextSlot()
        XCTAssertEqual(second.wait, 10, accuracy: 0.0001)
    }

    /// A wait that is aborted before the request actually dispatches must not
    /// leave a phantom entry counted against any window.
    func testCancelledReservationLeavesNoPhantomDispatchedTimestamp() {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 1, duration: 10)],
            now: clock.now
        )
        let first = scheduler.reserveNextSlot()
        XCTAssertEqual(first.wait, 0)

        // A second reservation is forced to wait out the first's window...
        let second = scheduler.reserveNextSlot()
        XCTAssertEqual(second.wait, 10, accuracy: 0.0001)
        // ...but it is aborted mid-wait and never actually dispatches, so it
        // must not occupy the window's only slot.
        scheduler.cancelReservation(second.ticket)

        // If the cancelled reservation had survived, its predicted (but
        // never-reached) t=10 slot would now be the "most recent" entry in
        // this limit-1 window, forcing a stacked ~20s wait. With it removed,
        // the window is governed only by the first, real dispatch.
        let third = scheduler.reserveNextSlot()
        XCTAssertEqual(
            third.wait, 10, accuracy: 0.0001,
            "a cancelled reservation must not double-count against the window"
        )
    }

    // MARK: - Monotonic clock authority (#168 repair)

    /// The provider's windows measure real elapsed time, so the ledger must be
    /// aged by a monotonic clock. The civil/system clock can be moved
    /// independently of elapsed time (a user edit, an NTP correction, a
    /// time-zone/DST adjustment), and a forward jump past a window's duration
    /// must not release a slot: only 1s of real time has passed here, so the
    /// 10s window still owes 9s no matter what the system clock now reads.
    ///
    /// This is exactly what the earlier `Date`-based ledger got wrong. Wired to
    /// the same device, it would have read `civilNow()`, seen the single
    /// dispatch entry as 5 hours old, pruned it, and returned a wait of 0 —
    /// dispatching a second request 1 real second after the first, inside a
    /// window that only permits one.
    func testForwardSystemClockJumpDoesNotReleaseAWindowSlotEarly() {
        let device = JumpingSystemClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 1, duration: 10)],
            now: device.monotonicNow
        )
        let civilStart = device.civilNow()

        let first = scheduler.reserveNextSlot()
        XCTAssertEqual(first.wait, 0)
        scheduler.confirmDispatch(first.ticket)

        // One second of real elapsed time...
        device.advanceRealTime(by: 1)
        // ...but the system clock is set five hours forward.
        device.jumpSystemClock(by: 5 * 60 * 60)
        XCTAssertGreaterThan(
            device.civilNow().timeIntervalSince(civilStart), 10,
            "the scenario must jump civil time clear past the 10s window"
        )

        let second = scheduler.reserveNextSlot()
        XCTAssertEqual(
            second.wait, 9, accuracy: 0.0001,
            "only 1s of real time elapsed, so the 10s window still owes 9s"
        )
    }

    /// The mirror case: a backward civil-clock correction must not stretch a
    /// window either. Real elapsed time already cleared it, so the next slot
    /// is free regardless of what the system clock now reads.
    func testBackwardSystemClockJumpDoesNotExtendAWindow() {
        let device = JumpingSystemClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 1, duration: 10)],
            now: device.monotonicNow
        )

        let first = scheduler.reserveNextSlot()
        XCTAssertEqual(first.wait, 0)
        scheduler.confirmDispatch(first.ticket)

        device.advanceRealTime(by: 10)
        device.jumpSystemClock(by: -5 * 60 * 60)

        XCTAssertEqual(scheduler.reserveNextSlot().wait, 0, accuracy: 0.0001)
    }
}

/// A device whose civil/system clock can be changed independently of real
/// elapsed time. `monotonicNow` is the `ContinuousClock` reading production
/// consumes; `civilNow` is what a `Date`-based ledger would have consumed, kept
/// alongside only so a test can state the jump it is simulating.
private final class JumpingSystemClock: @unchecked Sendable {
    private let lock = NSLock()
    private var monotonic = ContinuousClock.now
    private var civil = Date(timeIntervalSince1970: 1_700_000_000)

    func monotonicNow() -> ContinuousClock.Instant {
        lock.lock()
        defer { lock.unlock() }
        return monotonic
    }

    func civilNow() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return civil
    }

    /// Real time passing: both clocks advance together.
    func advanceRealTime(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        monotonic = monotonic.advanced(by: .seconds(seconds))
        civil = civil.addingTimeInterval(seconds)
    }

    /// The system clock being set: civil time moves, elapsed time does not.
    func jumpSystemClock(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        civil = civil.addingTimeInterval(seconds)
    }
}
