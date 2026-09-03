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
            let wait = scheduler.reserveNextSlot()
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
                let wait = scheduler.reserveNextSlot()
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
            let wait = scheduler.reserveNextSlot()
            XCTAssertEqual(wait, 0)
            clock.advance(by: wait)
        }

        let fourthWait = scheduler.reserveNextSlot()
        XCTAssertEqual(fourthWait, 10, accuracy: 0.0001)
        clock.advance(by: fourthWait)

        // Waiting exactly the reported amount frees the oldest slot again.
        let fifthWait = scheduler.reserveNextSlot()
        XCTAssertEqual(fifthWait, 0, accuracy: 0.0001)
    }

    func testWaitingLessThanReportedStillBlocksTheNextRequest() async {
        let clock = TestClock()
        let scheduler = RequestWindowScheduler(
            windows: [.init(limit: 1, duration: 10)],
            now: clock.now
        )
        let firstWait = scheduler.reserveNextSlot()
        XCTAssertEqual(firstWait, 0)

        clock.advance(by: 4)
        let secondWait = scheduler.reserveNextSlot()
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
            let wait = scheduler.reserveNextSlot()
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
            let wait = scheduler.reserveNextSlot()
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
            let wait = scheduler.reserveNextSlot()
            XCTAssertEqual(wait, 0)
            clock.advance(by: wait)
        }
        let sixthWait = scheduler.reserveNextSlot()
        XCTAssertEqual(sixthWait, 5 * 60 * 60, accuracy: 0.0001)
    }
}
