import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The headless batch-Query state machine (#161 matrix Q-06 … Q-37, D-01 … D-05).
///
/// Grouped by behavior rather than one test per Design transition ID: the IDs
/// are acceptance coordinates, not a test architecture. Everything here runs
/// against a fake transport; no test touches a real credential or Maimemo.
@MainActor
final class QuerySessionStoreTests: XCTestCase {

    // MARK: - Q-06 → Q-08: a normal run

    func testRunResolvesThenReadsEachFamilyRowMajorAndReportsCounts() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")

        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["alpha", "beta"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([phraseRecordPayload("P1", english: "an alpha")]),
            notesResponse([note("N1", "记忆 a")]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        XCTAssertEqual(store.phase, .completed)
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertEqual(store.rows[0].cell(.interpretation), .count(1))
        XCTAssertEqual(store.rows[0].cell(.phrase), .count(1))
        XCTAssertEqual(store.rows[0].cell(.note), .count(1))
        XCTAssertEqual(store.rows[1].cell(.interpretation), .count(0))
        XCTAssertEqual(store.rows[1].cell(.note), .count(0))

        // Strict row-major order: one resolver call, then 释义 → 例句 → 助记 per
        // word, before moving to the next word.
        XCTAssertEqual(
            transport.requests.map(\.route),
            [
                .vocabularyQuery,
                .interpretations(vocabularyID: "VOC_ALPHA"),
                .phrases(vocabularyID: "VOC_ALPHA"),
                .notes(vocabularyID: "VOC_ALPHA"),
                .interpretations(vocabularyID: "VOC_BETA"),
                .phrases(vocabularyID: "VOC_BETA"),
                .notes(vocabularyID: "VOC_BETA"),
            ]
        )
        // Query is read-only: no mutating request is reachable from this path.
        XCTAssertEqual(transport.postCount, 0)
    }

    func testDuplicateRowsCostOneReadAndShowTheSameTruthTwice() async throws {
        let store = QuerySessionStore()
        store.updateInput("Alpha\nbeta\nALPHA")

        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["Alpha", "beta"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        // Three visible rows, in the typed order.
        XCTAssertEqual(store.rows.map(\.spelling), ["Alpha", "beta", "ALPHA"])
        // Both spellings of the same word show the same truth …
        XCTAssertEqual(store.rows[0].cell(.interpretation), .count(1))
        XCTAssertEqual(store.rows[2].cell(.interpretation), .count(1))
        // … from a single set of reads.
        XCTAssertEqual(transport.count(of: .interpretations(vocabularyID: "VOC_ALPHA")), 1)
        XCTAssertEqual(transport.readCount, 1 + 3 + 3)
    }

    // MARK: - Q-31 / Q-32: inability is never a zero

    func testUnresolvedRowIsWhollyUnavailableAndNeverCountsAsZero() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nghost")

        let transport = FakeHTTPTransport([
            // Only `alpha` comes back; `ghost` stays unresolved.
            vocabularyQueryResponse([(id: "VOC_ALPHA", spelling: "alpha")]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        let ghost = try XCTUnwrap(store.rows.first { $0.spelling == "ghost" })
        XCTAssertEqual(ghost.rowInability, .targetNotFound)
        XCTAssertEqual(ghost.readStatus, .unavailable)
        for family in QueryContentFamily.allCases {
            XCTAssertEqual(ghost.cell(family), .unavailable(.targetNotFound))
            XCTAssertNil(ghost.cell(family).knownCount)
        }
        // No content request was ever made for the unresolved row.
        XCTAssertEqual(transport.readCount, 1 + 3)
    }

    func testOneUndecodableCellLeavesTheRestOfTheRowTruthful() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")

        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["alpha"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            // A note record the closed decoder cannot accept.
            notesResponse([["id": "N1", "note": "x", "status": "ARCHIVED"]]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        let row = store.rows[0]
        XCTAssertEqual(row.cell(.interpretation), .count(1))
        XCTAssertEqual(row.cell(.phrase), .count(0))
        XCTAssertEqual(row.cell(.note), .unavailable(.responseNotSafelyReadable))
        XCTAssertEqual(row.readStatus, .unavailable)
        XCTAssertEqual(store.phase, .completed)
    }

    // MARK: - Q-09 → Q-11: stop, preserve, resume

    func testStopPreservesCompletedTruthAndMarksTheRestUnread() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")

        // `alpha` completes; the run then parks on `beta`'s first read.
        let transport = SteppedHTTPTransport(alphaCompletesThenParks())
        store.start(lease: try queryLease(transport))
        await transport.waitUntilParked()

        store.stop()
        await transport.release()
        await store.awaitRunCompletion()

        // Completed cells stay truthful …
        XCTAssertEqual(store.rows[0].cell(.interpretation), .count(1))
        XCTAssertEqual(store.rows[0].cell(.phrase), .count(0))
        XCTAssertEqual(store.rows[0].cell(.note), .count(0))
        // … and everything unfinished is 未读, never a zero.
        XCTAssertEqual(store.rows[1].cell(.interpretation), .unread)
        XCTAssertEqual(store.rows[1].cell(.note), .unread)
        XCTAssertNil(store.rows[1].cell(.interpretation).knownCount)
        XCTAssertTrue(store.hasUnfinishedWork)
        XCTAssertEqual(store.completedRowCount, 1)
        XCTAssertEqual(store.phase, .stopped(.userStopped))
    }

    func testResumeReadsOnlyUnfinishedCellsAndNeverRerunsCompletedOnes() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")

        let first = SteppedHTTPTransport(alphaCompletesThenParks())
        store.start(lease: try queryLease(first))
        await first.waitUntilParked()
        store.stop()
        await first.release()
        await store.awaitRunCompletion()
        let resolverCalls = await first.vocabularyQueryCount
        XCTAssertEqual(resolverCalls, 1)

        // 继续查阅: the resolver stage already completed, so it is not repeated,
        // and `alpha`'s three finished cells are not re-read.
        let second = FakeHTTPTransport([
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.resume(lease: try queryLease(second))
        await store.awaitRunCompletion()

        XCTAssertEqual(store.phase, .completed)
        XCTAssertEqual(second.vocabularyQueryCount, 0, "resolver stage re-run")
        XCTAssertEqual(
            second.requests.map(\.route),
            [
                .interpretations(vocabularyID: "VOC_BETA"),
                .phrases(vocabularyID: "VOC_BETA"),
                .notes(vocabularyID: "VOC_BETA"),
            ]
        )
        XCTAssertEqual(store.rows[0].cell(.interpretation), .count(1))
        XCTAssertEqual(store.rows[1].cell(.interpretation), .count(0))
    }

    func testAnAlreadyUnavailableCellIsNeverAutomaticallyRetried() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")

        let first = SteppedHTTPTransport([
            resolvedQueryResponse(["alpha", "beta"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            // `alpha`'s notes cell fails closed …
            notesResponse([["id": "N1", "note": "x", "status": "ARCHIVED"]]),
        ])
        store.start(lease: try queryLease(first))
        await first.waitUntilParked()
        store.stop()
        await first.release()
        await store.awaitRunCompletion()
        XCTAssertEqual(
            store.rows[0].cell(.note),
            .unavailable(.responseNotSafelyReadable)
        )

        let second = FakeHTTPTransport([
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.resume(lease: try queryLease(second))
        await store.awaitRunCompletion()

        // … and 继续查阅 reads only `beta`; the unavailable cell is untouched.
        XCTAssertFalse(
            second.requests.contains { $0.route == .notes(vocabularyID: "VOC_ALPHA") }
        )
        XCTAssertEqual(
            store.rows[0].cell(.note),
            .unavailable(.responseNotSafelyReadable)
        )
    }

    func testResolverStageIsAtomicAndRerunsWhenItNeverCompleted() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")

        // Stopped while the resolver stage is still in flight: no durable
        // resolver truth is recorded.
        let gated = GatedHTTPTransport(resolvedQueryResponse(["alpha"]))
        store.start(lease: try queryLease(gated))
        await gated.waitUntilRequested()
        store.stop()
        await gated.resume()
        await store.awaitRunCompletion()

        XCTAssertNil(store.rows[0].vocabularyID)
        XCTAssertEqual(store.rows[0].cell(.interpretation), .unread)

        // An explicit continue runs the whole atomic stage again.
        let second = FakeHTTPTransport([
            resolvedQueryResponse(["alpha"]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.resume(lease: try queryLease(second))
        await store.awaitRunCompletion()

        XCTAssertEqual(second.vocabularyQueryCount, 1)
        XCTAssertEqual(store.phase, .completed)
    }

    // MARK: - Late responses from a superseded run

    func testALateResponseFromAStoppedRunCannotMutateTheStore() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")

        let gated = GatedHTTPTransport(resolvedQueryResponse(["alpha"]))
        store.start(lease: try queryLease(gated))
        await gated.waitUntilRequested()

        // Stop supersedes the run generation while the resolver is in flight.
        store.stop()
        XCTAssertEqual(store.rows[0].cell(.interpretation), .unread)

        // The stopped run's response arrives afterwards and must be ignored.
        await gated.resume()
        await store.awaitRunCompletion()

        XCTAssertNil(store.rows[0].vocabularyID)
        XCTAssertNil(store.rows[0].rowInability)
        XCTAssertEqual(store.rows[0].cell(.interpretation), .unread)
        if case .stopped = store.phase {} else {
            XCTFail("expected a stopped phase, got \(store.phase)")
        }
    }

    // MARK: - Q-33 … Q-36: global stops

    func testAuthenticationRejectionStopsTheBatchAndPreservesCompletedTruth() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")

        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["alpha", "beta"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
            jsonResponse(["error": "unauthorized"], status: 401),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        XCTAssertEqual(store.phase, .stopped(.globalFailure(.authenticationRejected)))
        // Completed rows keep their truth …
        XCTAssertEqual(store.rows[0].cell(.interpretation), .count(1))
        XCTAssertEqual(store.rows[0].cell(.note), .count(0))
        // … and the unfinished row is unread, never zero.
        XCTAssertEqual(store.rows[1].cell(.interpretation), .unread)
        XCTAssertNil(store.rows[1].cell(.interpretation).knownCount)
        // Nothing is dispatched afterwards and nothing retries.
        XCTAssertEqual(transport.readCount, 5)
        XCTAssertTrue(store.hasUnfinishedWork)

        // A 401 is a stop, not an identity change: the result survives it.
        XCTAssertFalse(store.rows.isEmpty)
        XCTAssertFalse(store.accountChangedBanner)
    }

    func testEachGlobalFailureFamilyStopsWithItsOwnFrozenBanner() async throws {
        let families: [(CompanionError, String)] = [
            (.authenticationRejected, "已停止 · 墨墨拒绝了当前 Token"),
            (.transport, "已停止 · 网络请求失败"),
            (.rateLimited, "已停止 · 请求过于频繁"),
            (.serverFailure, "已停止 · 服务返回无法安全确认"),
        ]
        for (error, expectedTitle) in families {
            let store = QuerySessionStore()
            store.updateInput("alpha")
            let transport = FakeHTTPTransport([
                resolvedQueryResponse(["alpha"]),
                .failure(error),
            ])
            store.start(lease: try queryLease(transport))
            await store.awaitRunCompletion()

            guard case let .stopped(reason) = store.phase else {
                XCTFail("expected stopped for \(error)")
                continue
            }
            XCTAssertEqual(reason.bannerTitle, expectedTitle)
            XCTAssertNotNil(reason.bannerBody(read: 0, remaining: 1))
            XCTAssertEqual(
                reason.requiresReconnect,
                error == .authenticationRejected
            )
            XCTAssertEqual(store.rows[0].cell(.interpretation), .unread)
        }
    }

    // MARK: - Q-37: account identity

    func testRealIdentityChangeClearsResultFilterScrollButKeepsInputText() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")
        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["alpha", "beta"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.handleAccountIdentityChange(
            to: AccountIdentity(fingerprint: "QUERY_FP_1", authorityGeneration: 1)
        )
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        var filter = QueryFilter()
        filter.interpretation = .positive
        store.setFilter(filter)
        store.scrollAnchor = 1
        XCTAssertEqual(store.phase, .completed)

        // A replacement: new fingerprint and an advanced authority generation.
        store.handleAccountIdentityChange(
            to: AccountIdentity(fingerprint: "QUERY_FP_2", authorityGeneration: 2)
        )

        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.filter, .none)
        XCTAssertNil(store.scrollAnchor)
        XCTAssertEqual(store.phase, .input)
        XCTAssertTrue(store.accountChangedBanner)
        // The Owner's typed input survives so they can simply run it again.
        XCTAssertEqual(store.inputText, "alpha\nbeta")
        XCTAssertEqual(store.parse?.visibleCount, 2)
    }

    func testTransientSuspensionAndSameTokenRestoreAreNotIdentityChanges() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")
        store.handleAccountIdentityChange(
            to: AccountIdentity(fingerprint: "QUERY_FP_1", authorityGeneration: 1)
        )
        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["alpha"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()
        XCTAssertEqual(store.phase, .completed)

        // A foreground restore of the same saved Token: identical identity.
        store.handleAccountIdentityChange(
            to: AccountIdentity(fingerprint: "QUERY_FP_1", authorityGeneration: 1)
        )
        XCTAssertEqual(store.rows.count, 1)
        XCTAssertEqual(store.phase, .completed)
        XCTAssertFalse(store.accountChangedBanner)
    }

    func testAnExplicitReconnectAfterRejectionClearsEvenWithTheSameToken() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")
        store.handleAccountIdentityChange(
            to: AccountIdentity(fingerprint: "QUERY_FP_1", authorityGeneration: 1)
        )
        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["alpha"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        // Same fingerprint, but a deliberate reconnect advanced the authority
        // generation: the old account-derived result must not survive it.
        store.handleAccountIdentityChange(
            to: AccountIdentity(fingerprint: "QUERY_FP_1", authorityGeneration: 2)
        )
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertTrue(store.accountChangedBanner)
        XCTAssertEqual(store.inputText, "alpha")
    }

    // MARK: - Q-24 / Q-27 / Q-28: modify and return

    func testModifyKeepsTheResultReturnableUntilTheFirstRealEdit() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")
        let transport = FakeHTTPTransport(completedRunResponses())
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        var filter = QueryFilter()
        filter.phrase = .zero
        store.setFilter(filter)
        store.scrollAnchor = 2
        let readsAfterRun = transport.readCount

        store.beginModify()
        XCTAssertEqual(store.phase, .input)
        XCTAssertTrue(store.returnableResult)
        XCTAssertEqual(store.inputText, "alpha\nbeta")

        // Re-assigning the identical text is not an edit.
        store.updateInput("alpha\nbeta")
        XCTAssertTrue(store.returnableResult)

        // 返回结果 restores the same result, filter and position, with no network.
        store.returnToResult()
        XCTAssertEqual(store.phase, .completed)
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertEqual(store.filter, filter)
        XCTAssertEqual(store.scrollAnchor, 2)
        XCTAssertEqual(transport.readCount, readsAfterRun)
    }

    func testFirstRealEditInvalidatesTheOldResultAndItsFilter() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")
        store.start(lease: try queryLease(FakeHTTPTransport(completedRunResponses())))
        await store.awaitRunCompletion()

        var filter = QueryFilter()
        filter.phrase = .zero
        store.setFilter(filter)
        store.beginModify()

        store.updateInput("alpha\nbeta\ngamma")

        XCTAssertFalse(store.returnableResult)
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.filter, .none)
        XCTAssertNil(store.scrollAnchor)
        XCTAssertEqual(store.phase, .input)
        XCTAssertEqual(store.startActionCount, 3)
    }

    // MARK: - Q-29 / Q-30b: interrupts while running

    func testRunningInterruptsRequireAnAnswerAndStopPreservesTruth() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")
        let gated = GatedHTTPTransport(resolvedQueryResponse(["alpha"]))
        store.start(lease: try queryLease(gated))
        await gated.waitUntilRequested()
        XCTAssertTrue(store.phase.isRunning)

        store.requestInterrupt(.back)
        XCTAssertEqual(store.pendingInterrupt, .back)

        // 继续查阅 dismisses without stopping.
        store.dismissInterrupt()
        XCTAssertNil(store.pendingInterrupt)
        XCTAssertTrue(store.phase.isRunning)

        // 停止并返回 stops.
        store.requestInterrupt(.back)
        store.resolveInterrupt(.back)
        XCTAssertNil(store.pendingInterrupt)
        XCTAssertFalse(store.phase.isRunning)

        await gated.resume()
        await store.awaitRunCompletion()
        XCTAssertFalse(store.phase.isRunning)
    }

    func testStopAndModifyLandsInTheInputPhaseWithTheResultStillReturnable() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")
        let gated = GatedHTTPTransport(resolvedQueryResponse(["alpha"]))
        store.start(lease: try queryLease(gated))
        await gated.waitUntilRequested()

        store.requestInterrupt(.modify)
        store.resolveInterrupt(.modify)

        XCTAssertEqual(store.phase, .input)
        XCTAssertTrue(store.returnableResult)
        XCTAssertEqual(store.inputText, "alpha")
        await gated.resume()
        await store.awaitRunCompletion()
    }

    // MARK: - Q-30: same-process restore

    func testACompletedResultSurvivesLeavingAndReenteringTheQueryDestination() async throws {
        // The store is app-scoped, so "leaving" is simply the view going away.
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")
        let transport = FakeHTTPTransport(completedRunResponses())
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()
        var filter = QueryFilter()
        filter.interpretation = .positive
        store.setFilter(filter)
        store.scrollAnchor = 1

        let readsAfterRun = transport.readCount
        // Re-entering performs no work of any kind.
        XCTAssertEqual(store.phase, .completed)
        XCTAssertEqual(store.rows.count, 2)
        XCTAssertEqual(store.filter, filter)
        XCTAssertEqual(store.scrollAnchor, 1)
        XCTAssertEqual(transport.readCount, readsAfterRun)
    }

    // MARK: - Q-21 / Q-22: copy

    func testCopyCoversExactlyTheCurrentlyMatchedSpellings() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")
        store.start(lease: try queryLease(FakeHTTPTransport(completedRunResponses())))
        await store.awaitRunCompletion()

        XCTAssertEqual(store.matchCount, 2)
        XCTAssertEqual(store.copyPayload, "alpha\nbeta")

        var filter = QueryFilter()
        filter.interpretation = .positive
        store.setFilter(filter)
        XCTAssertEqual(store.matchCount, 1)
        XCTAssertEqual(store.copyPayload, "alpha")

        filter.interpretation = .zero
        filter.phrase = .positive
        store.setFilter(filter)
        XCTAssertEqual(store.matchCount, 0)
        XCTAssertEqual(store.copyPayload, "")
    }

    // MARK: - D-01 … D-05: detail

    func testDetailUsesAlreadyReturnedObjectsAndSendsNoRequest() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")
        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["alpha"]),
            interpretationsResponse([
                interpretation("I1", "n. a", tags: ["考研"], status: "PUBLISHED"),
                interpretation("I2", "n. b", status: "UNPUBLISHED"),
                interpretation("I3", "n. gone", status: "DELETED"),
            ]),
            phrasesResponse([phraseRecordPayload("P1", english: "an alpha")]),
            notesResponse([note("N1", "记忆 a"), note("N2", "旧", status: "DELETED")]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        let readsAfterRun = transport.readCount
        let detail = try XCTUnwrap(store.detail(forRowID: 1))

        // DELETED records are excluded from both the count and the detail.
        XCTAssertEqual(store.rows[0].cell(.interpretation), .count(2))
        XCTAssertEqual(detail.interpretations.map(\.id), ["I1", "I2"])
        XCTAssertEqual(detail.phrases.map(\.id), ["P1"])
        XCTAssertEqual(detail.notes.map(\.id), ["N1"])
        // Opening it cost nothing.
        XCTAssertEqual(transport.readCount, readsAfterRun)
    }

    func testDetailForAConfirmedZeroIsEmptyRatherThanUnknown() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha")
        store.start(lease: try queryLease(FakeHTTPTransport([
            resolvedQueryResponse(["alpha"]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])))
        await store.awaitRunCompletion()

        let detail = try XCTUnwrap(store.detail(forRowID: 1))
        XCTAssertTrue(detail.interpretations.isEmpty)
        XCTAssertEqual(store.rows[0].cell(.interpretation), .count(0))
    }

    // MARK: - Filter narrowing offers only reasons present in this batch

    func testPresentInabilityReasonsAreLimitedToWhatActuallyOccurred() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nghost")
        store.start(lease: try queryLease(FakeHTTPTransport([
            vocabularyQueryResponse([(id: "VOC_ALPHA", spelling: "alpha")]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])))
        await store.awaitRunCompletion()

        XCTAssertEqual(store.presentInabilityReasons, [.targetNotFound])
        XCTAssertFalse(
            store.presentInabilityReasons.contains(.responseNotSafelyReadable)
        )
    }

    // MARK: - Guards

    func testAStartWithMalformedOrEmptyInputIsRefusedAndReleasesTheLease() throws {
        let store = QuerySessionStore()
        store.updateInput("  ")
        XCTAssertFalse(store.canStart)

        var released = false
        store.start(lease: try queryLease(
            FakeHTTPTransport([]),
            onFinish: { released = true }
        ))
        XCTAssertTrue(released, "a refused start must release the operation lane")
        XCTAssertTrue(store.rows.isEmpty)
        XCTAssertEqual(store.phase, .input)
    }

    func testResumeUnderADifferentCredentialIsRefused() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta")
        let first = SteppedHTTPTransport(alphaCompletesThenParks())
        store.start(lease: try queryLease(first))
        await first.waitUntilParked()
        store.stop()
        await first.release()
        await store.awaitRunCompletion()

        var released = false
        let other = FakeHTTPTransport([interpretationsResponse([])])
        store.resume(lease: try queryLease(
            other,
            fingerprint: "A_DIFFERENT_FINGERPRINT",
            onFinish: { released = true }
        ))
        await store.awaitRunCompletion()

        XCTAssertTrue(released)
        XCTAssertEqual(other.readCount, 0)
    }

    // MARK: - Helpers

    /// `alpha` has one interpretation, `beta` has none; neither has phrases or
    /// notes. Enough to exercise every numeric predicate.
    /// `alpha`'s three cells complete; the run then parks on `beta`.
    private func alphaCompletesThenParks() -> [StubbedResult] {
        [
            resolvedQueryResponse(["alpha", "beta"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
        ]
    }

    private func completedRunResponses() -> [StubbedResult] {
        [
            resolvedQueryResponse(["alpha", "beta"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ]
    }
}
