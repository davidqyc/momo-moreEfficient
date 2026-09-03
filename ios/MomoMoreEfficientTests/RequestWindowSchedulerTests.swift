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

        var dispatchTimes: [Date] = []
        for _ in 0..<80 {
            let wait = scheduler.reserveNextSlot().wait
            clock.advance(by: wait)
            dispatchTimes.append(clock.now())
        }

        for window in windows {
            for dispatchTime in dispatchTimes {
                let windowStart = dispatchTime.addingTimeInterval(-window.duration)
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
}
