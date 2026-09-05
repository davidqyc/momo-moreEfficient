import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The application-level provider operation lane, and the narrow read seam
/// batch Query is given (adjudication findings 1–5).
///
/// The shared `RequestWindowScheduler` is a *rate ledger*: it paces requests
/// against the documented windows but does not by itself prove that only one
/// request is in flight. These tests therefore observe the **actual fake
/// transport**, not scheduler reservations.
@MainActor
final class ProviderOperationLaneTests: XCTestCase {

    // MARK: - Actual in-flight observation

    func testAQueryRunNeverHasMoreThanOneRequestInFlight() async throws {
        let store = QuerySessionStore()
        store.updateInput("alpha\nbeta\ngamma")

        let transport = ConcurrencyObservingHTTPTransport([
            resolvedQueryResponse(["alpha", "beta", "gamma"]),
            interpretationsResponse([interpretation("I1", "n. a")]),
            phrasesResponse([]),
            notesResponse([]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
            interpretationsResponse([]),
            phrasesResponse([]),
            notesResponse([]),
        ])
        store.start(lease: try queryLease(transport))
        await store.awaitRunCompletion()

        XCTAssertEqual(store.phase, .completed)
        XCTAssertEqual(transport.readCount, 10)
        // The real proof: never two overlapping requests, at any point.
        XCTAssertEqual(transport.maximumConcurrentRequests, 1)
        XCTAssertEqual(transport.postCount, 0)
    }

    // MARK: - The lane excludes incompatible operations

    func testQueryCannotTakeTheLaneWhileAPreviewIsReading() async throws {
        // Parks on the Preview's very first (resolver) request.
        let stepped = SteppedHTTPTransport([])
        let model = makeConnectedModel(transport: stepped)
        model.sourceText = "## merchandise\nn. 商品"

        XCTAssertNil(model.activeProviderOperation)
        let preview = Task { await model.previewCurrentInput() }
        await stepped.waitUntilParked()

        XCTAssertEqual(model.activeProviderOperation, .preview)
        XCTAssertTrue(model.isProviderLaneBusy)
        // Query simply does not start rather than racing the Preview.
        XCTAssertNil(model.beginQueryRead())

        // Let the Preview end (a transport failure aborts its read plan).
        await stepped.release(.failure(.transport))
        await preview.value

        XCTAssertNil(model.activeProviderOperation)
        XCTAssertFalse(model.isProviderLaneBusy)
        // …and now Query may take the lane.
        let lease = try XCTUnwrap(model.beginQueryRead())
        lease.finish()
    }

    func testQueryCannotTakeTheLaneWhileCredentialValidationIsInFlight() async throws {
        let gated = GatedHTTPTransport(
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple")
        )
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { gated },
            sleeperFactory: { RecordingSleeper() }
        )
        let connection = Task { await model.connect(token: fakeToken) }
        await gated.waitUntilRequested()

        XCTAssertEqual(model.activeProviderOperation, .credentialValidation)
        XCTAssertNil(model.beginQueryRead())

        await gated.resume()
        _ = await connection.value
        XCTAssertNil(model.activeProviderOperation)
    }

    func testPreviewAndWritesCannotStartWhileQueryOwnsTheLane() async throws {
        let model = makeConnectedModel(transport: FakeHTTPTransport([]))
        model.sourceText = "## merchandise\nn. 商品"

        let lease = try XCTUnwrap(model.beginQueryRead())
        XCTAssertEqual(model.activeProviderOperation, .query)

        // A Preview started now takes no lane and dispatches nothing.
        await model.previewCurrentInput()
        XCTAssertFalse(model.isPreviewing)
        XCTAssertNil(model.preview)

        // An authorized write is refused while Query still holds the lane.
        XCTAssertNil(model.executeConfirmedWholePlan())
        XCTAssertNil(model.executeConfirmed(.create))
        XCTAssertNil(model.executeConfirmedPhrase())

        lease.finish()
        XCTAssertNil(model.activeProviderOperation)
    }

    func testTheLeaseIsIdempotentAndAlwaysReleasesTheLane() throws {
        let model = makeConnectedModel(transport: FakeHTTPTransport([]))
        let lease = try XCTUnwrap(model.beginQueryRead())
        XCTAssertEqual(model.activeProviderOperation, .query)

        lease.finish()
        lease.finish()
        XCTAssertNil(model.activeProviderOperation)

        // The lane is reusable afterwards.
        let second = try XCTUnwrap(model.beginQueryRead())
        XCTAssertEqual(model.activeProviderOperation, .query)
        second.finish()
    }

    func testQueryIsRefusedWhenThereIsNoConnection() {
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { FakeHTTPTransport([]) },
            sleeperFactory: { RecordingSleeper() }
        )
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.beginQueryRead())
        XCTAssertNil(model.activeProviderOperation)
    }

    // MARK: - Identity semantics (findings 4 and 5)

    func testASuccessfulConnectAndRemovalAdvanceTheAccountAuthority() async {
        let store = FakeTokenStore()
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )
        XCTAssertEqual(model.accountIdentity, .disconnected)

        let connected = await model.connect(token: fakeToken)
        XCTAssertTrue(connected)
        let afterConnect = model.accountIdentity
        XCTAssertNotNil(afterConnect.fingerprint)
        XCTAssertEqual(afterConnect.authorityGeneration, 1)

        model.removeToken()
        XCTAssertNil(model.accountIdentity.fingerprint)
        XCTAssertEqual(model.accountIdentity.authorityGeneration, 2)
    }

    func testAFailedCandidateChangesNeitherIdentityDimension() async {
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
            jsonResponse(["error": "unauthorized"], status: 401),
        ])
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )
        let connected = await model.connect(token: fakeToken)
        XCTAssertTrue(connected)
        let before = model.accountIdentity

        let replaced = await model.connect(token: "CANDIDATE_TOKEN_NOT_VALID")
        XCTAssertFalse(replaced)
        // Nothing was mutated, so account-derived truth must not be cleared.
        XCTAssertEqual(model.accountIdentity, before)
    }

    func testAFailedRemovalLeavesTheIdentityAndConnectionIntact() async {
        let store = FakeTokenStore()
        let model = CompanionViewModel(
            tokenStore: store,
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { successfulCredentialValidationTransport() },
            sleeperFactory: { RecordingSleeper() }
        )
        let connected = await model.connect(token: fakeToken)
        XCTAssertTrue(connected)
        let before = model.accountIdentity

        store.failDelete = true
        model.removeToken()

        // Truthful: nothing was deleted, so the app still says 已连接.
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.accountIdentity, before)
        XCTAssertNotNil(model.errorMessage)
    }

    func testAQueryAuthenticationRejectionDisconnectsWithoutChangingIdentity() async {
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { successfulCredentialValidationTransport() },
            sleeperFactory: { RecordingSleeper() }
        )
        let connected = await model.connect(token: fakeToken)
        XCTAssertTrue(connected)
        let before = model.accountIdentity

        model.handleQueryAuthenticationRejection()

        // The session drops and the Owner is routed to Settings …
        XCTAssertFalse(model.isConnected)
        // … but this is not an account change, so a Query result built under
        // this identity stays truthful.
        XCTAssertEqual(model.accountIdentity, before)
    }

    func testABackgroundSuspensionIsNotAnAccountChange() async {
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
            vocabularyResponse("INVALID_VALIDATION_VOC", "apple"),
        ])
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            credentialValidationTransportFactory: { transport },
            sleeperFactory: { RecordingSleeper() }
        )
        let connected = await model.connect(token: fakeToken)
        XCTAssertTrue(connected)
        let before = model.accountIdentity

        model.enterBackground()
        XCTAssertFalse(model.isConnected)
        XCTAssertEqual(model.accountIdentity, before, "suspension changed identity")

        // Restoring the same saved Token keeps the same identity, so nothing
        // account-derived is cleared.
        await model.enterForeground()
        XCTAssertTrue(model.isConnected)
        XCTAssertEqual(model.accountIdentity, before)
    }

    // MARK: - Helpers

    private func makeConnectedModel(transport: HTTPTransport) -> CompanionViewModel {
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            credentialValidationTransportFactory: {
                successfulCredentialValidationTransport()
            },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        return model
    }
}
