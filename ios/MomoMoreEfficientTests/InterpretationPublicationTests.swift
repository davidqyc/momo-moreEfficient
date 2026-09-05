import Foundation
import XCTest
@testable import MomoMoreEfficient

/// #161 interpretation publication status (`公开` / `未发布`).
///
/// The status is a value threaded through the *existing* write chain — Preview
/// snapshot → binding context → digest → fresh preflight → request body →
/// authenticated readback — not a new approval stack. These tests pin every
/// link, plus the two isolation rules: phrase stays PUBLISHED, and an
/// out-of-allowlist status fails closed.
final class InterpretationPublicationTests: XCTestCase {

    private let document = "## merchandise\nn. 商品"

    // MARK: - Preference

    func testPreferenceDefaultsToPublishedAndRoundTrips() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "publication-\(UUID().uuidString)"))
        XCTAssertEqual(InterpretationPublicationPreference.load(from: defaults), .published)

        InterpretationPublicationPreference.save(.unpublished, to: defaults)
        XCTAssertEqual(InterpretationPublicationPreference.load(from: defaults), .unpublished)

        // A value the app does not recognise never becomes an active preference.
        defaults.set("DELETED", forKey: InterpretationPublicationPreference.userDefaultsKey)
        XCTAssertEqual(InterpretationPublicationPreference.load(from: defaults), .published)
    }

    func testAllowedStatusSetIsExactlyPublishedAndUnpublished() {
        XCTAssertEqual(
            InterpretationPublicationStatus.documentedWriteStatuses,
            ["PUBLISHED", "UNPUBLISHED"]
        )
        XCTAssertTrue(InterpretationPublicationStatus.isDocumentedWriteStatus("PUBLISHED"))
        XCTAssertTrue(InterpretationPublicationStatus.isDocumentedWriteStatus("UNPUBLISHED"))
        for rejected in ["DELETED", "PRIVATE", "", "published", "UNKNOWN"] {
            XCTAssertFalse(
                InterpretationPublicationStatus.isDocumentedWriteStatus(rejected),
                rejected
            )
        }
        // Never surfaced as 私密 — the provider contract does not prove that.
        XCTAssertEqual(InterpretationPublicationStatus.unpublished.label, "未发布")
        XCTAssertEqual(InterpretationPublicationStatus.published.label, "公开")
    }

    // MARK: - Classification: a status-only difference is 更新, never 一致

    func testSameTextAndTagsWithDifferentStatusClassifiesAsUpdate() async throws {
        let existing = interpretation("REC_1", "n. 商品", tags: [], status: "PUBLISHED")

        // Default preference: identical in every dimension → 一致.
        let (matching, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([existing]),
            ]
        )
        XCTAssertEqual(matching.presentation.counts.alreadyMatching, 1)
        XCTAssertEqual(matching.presentation.counts.update, 0)

        // Same text, same tags, requested 未发布 → 更新.
        let (changed, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([existing]),
            ],
            status: "UNPUBLISHED"
        )
        XCTAssertEqual(changed.presentation.counts.update, 1)
        XCTAssertEqual(changed.presentation.counts.alreadyMatching, 0)
        XCTAssertEqual(changed.presentation.rows.first?.classification, .update)
    }

    func testMatchesIntendedStateDefaultsToTheLegacyPublishedConstant() {
        let record = InterpretationRecord(
            id: "REC_1",
            interpretation: "n. 商品",
            tags: [],
            status: "PUBLISHED"
        )
        // Every pre-#161 caller keeps identical meaning.
        XCTAssertTrue(record.matchesIntendedState("n. 商品", tags: []))
        XCTAssertTrue(record.matchesIntendedState("n. 商品", tags: [], status: "PUBLISHED"))
        XCTAssertFalse(record.matchesIntendedState("n. 商品", tags: [], status: "UNPUBLISHED"))
    }

    // MARK: - Binding / digest / request body

    func testUnpublishedStatusBindsIntoContextDigestAndCreateBody() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([]),
            ],
            status: "UNPUBLISHED"
        )
        XCTAssertEqual(snapshot.bindingContext.status, "UNPUBLISHED")

        let plan = try ConfirmationBinding.makePlan(snapshot: snapshot, group: .create)
        XCTAssertEqual(plan.status, "UNPUBLISHED")

        let body = ConfirmationBinding.requestBody(
            plan.items[0],
            group: .create,
            tags: plan.tags,
            status: plan.status
        )
        let interpretationBody = try XCTUnwrap(body["interpretation"] as? [String: Any])
        XCTAssertEqual(interpretationBody["status"] as? String, "UNPUBLISHED")
        XCTAssertEqual(interpretationBody["interpretation"] as? String, "n. 商品")
        // No undocumented field is ever added alongside it.
        XCTAssertEqual(
            Set(interpretationBody.keys),
            ["interpretation", "tags", "status", "voc_id"]
        )
    }

    func testUnpublishedStatusBindsIntoTheUpdateBody() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([
                    interpretation("REC_1", "n. 旧的商品", tags: [], status: "PUBLISHED"),
                ]),
            ],
            status: "UNPUBLISHED"
        )
        let plan = try ConfirmationBinding.makePlan(snapshot: snapshot, group: .update)
        let body = ConfirmationBinding.requestBody(
            plan.items[0],
            group: .update,
            tags: plan.tags,
            status: plan.status
        )
        let interpretationBody = try XCTUnwrap(body["interpretation"] as? [String: Any])
        XCTAssertEqual(interpretationBody["status"] as? String, "UNPUBLISHED")
        // UPDATE never carries voc_id; the record path identifies the target.
        XCTAssertEqual(Set(interpretationBody.keys), ["interpretation", "tags", "status"])
    }

    func testStatusParticipatesInTheApprovalDigest() async throws {
        func digest(_ status: String) async throws -> String {
            let (snapshot, _, _) = try await makeSnapshot(
                document: document,
                results: [
                    resolvedQueryResponse(["merchandise"]),
                    interpretationsResponse([]),
                ],
                status: status
            )
            return try ConfirmationBinding.makeApproval(
                snapshot: snapshot,
                group: .create
            ).bindingDigest
        }
        let published = try await digest("PUBLISHED")
        let unpublished = try await digest("UNPUBLISHED")
        XCTAssertNotEqual(published, unpublished)

        // The default preference reproduces today's digest exactly, so a device
        // that never touches the preference writes precisely what it wrote before.
        let (legacy, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([]),
            ]
        )
        XCTAssertEqual(
            try ConfirmationBinding.makeApproval(snapshot: legacy, group: .create).bindingDigest,
            published
        )
    }

    // MARK: - Fail closed

    func testStatusOutsideTheAllowlistFailsClosedBeforeAnyDigestExists() async throws {
        for rejected in ["DELETED", "PRIVATE", "published", ""] {
            do {
                _ = try await makeSnapshot(
                    document: document,
                    results: [
                        resolvedQueryResponse(["merchandise"]),
                        interpretationsResponse([]),
                    ],
                    status: rejected
                )
                XCTFail("accepted out-of-allowlist status \(rejected)")
            } catch let error as CompanionError {
                XCTAssertEqual(error, .inputRejected, rejected)
            }
        }
    }

    func testAPlanBuiltFromATamperedSnapshotStatusIsStale() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([]),
            ]
        )
        // Simulate a snapshot whose binding context carries an undocumented
        // status; the guard must reject it rather than plan a write from it.
        let tampered = PreviewSnapshot(
            sourceIdentity: snapshot.sourceIdentity,
            credentialFingerprint: snapshot.credentialFingerprint,
            accountMode: snapshot.accountMode,
            bindingContext: PreviewBindingContext(
                host: snapshot.bindingContext.host,
                createPath: snapshot.bindingContext.createPath,
                updatePath: snapshot.bindingContext.updatePath,
                tags: snapshot.bindingContext.tags,
                status: "DELETED",
                createBatchDigest: snapshot.bindingContext.createBatchDigest,
                updateBatchDigest: snapshot.bindingContext.updateBatchDigest
            ),
            items: snapshot.items,
            presentation: snapshot.presentation
        )
        XCTAssertThrowsError(
            try ConfirmationBinding.makePlan(snapshot: tampered, group: .create)
        ) { error in
            XCTAssertEqual(error as? CompanionError, .stalePreview)
        }
    }

    // MARK: - Readback verifies the approved status

    func testReadbackStatusMismatchIsNotVerifiedAndIsNeverRetried() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([]),
            ],
            status: "UNPUBLISHED"
        )
        // POST accepted, but the authenticated readback reports PUBLISHED.
        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["merchandise"]),
            interpretationsResponse([]),
            jsonResponse([:], status: 201),
            interpretationsResponse([
                interpretation("REC_NEW", "n. 商品", tags: [], status: "PUBLISHED"),
            ]),
        ])
        let lease = try credentialLease()
        let api = MaimemoTransport(
            transport: transport,
            credential: lease,
            sleeper: RecordingSleeper()
        )
        let summary = await WriteExecutor(api: api).execute(
            group: .create,
            displayedSnapshot: snapshot,
            approval: try ConfirmationBinding.makeApproval(snapshot: snapshot, group: .create),
            control: ExecutionControl()
        )
        lease.clear()

        XCTAssertEqual(summary.results.first?.outcome, .notVerified)
        XCTAssertEqual(
            summary.results.first?.diagnostic?.readbackAttempts.first?.category,
            .intendedStateMismatch
        )
        // Exactly one mutating POST, never repeated because verification failed.
        XCTAssertEqual(transport.postCount, 1)
    }

    func testReadbackMatchingTheApprovedUnpublishedStatusConfirms() async throws {
        let (snapshot, _, _) = try await makeSnapshot(
            document: document,
            results: [
                resolvedQueryResponse(["merchandise"]),
                interpretationsResponse([]),
            ],
            status: "UNPUBLISHED"
        )
        let transport = FakeHTTPTransport([
            resolvedQueryResponse(["merchandise"]),
            interpretationsResponse([]),
            jsonResponse([:], status: 201),
            interpretationsResponse([
                interpretation("REC_NEW", "n. 商品", tags: [], status: "UNPUBLISHED"),
            ]),
        ])
        let lease = try credentialLease()
        let api = MaimemoTransport(
            transport: transport,
            credential: lease,
            sleeper: RecordingSleeper()
        )
        let summary = await WriteExecutor(api: api).execute(
            group: .create,
            displayedSnapshot: snapshot,
            approval: try ConfirmationBinding.makeApproval(snapshot: snapshot, group: .create),
            control: ExecutionControl()
        )
        lease.clear()

        XCTAssertEqual(summary.results.first?.outcome, .confirmed)
        XCTAssertTrue(summary.isFullSuccess)
        XCTAssertEqual(transport.postCount, 1)

        // The POST body carried the approved status.
        let post = try XCTUnwrap(transport.requests.first { $0.route.isMutating })
        let body = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: try XCTUnwrap(post.body)) as? [String: Any]
        )
        let interpretationBody = try XCTUnwrap(body["interpretation"] as? [String: Any])
        XCTAssertEqual(interpretationBody["status"] as? String, "UNPUBLISHED")
    }

    // MARK: - Phrase isolation

    func testPhrasePathIsUnaffectedByTheInterpretationPreference() throws {
        // The legacy shared constant remains the phrase authority and is not a
        // preference; `RetrofitCharacterizationTests` pins the binding context
        // itself. Here: the enum must not be reachable from the phrase status.
        XCTAssertEqual(CompanionConstants.status, "PUBLISHED")
        XCTAssertEqual(
            InterpretationPublicationStatus.published.providerStatus,
            CompanionConstants.status
        )
    }

    func testReceiptStatusFieldIsOptionalAndAbsentForPhrase() throws {
        let interpretationReceipt = ExecutionReceipt(
            contentKind: .interpretation,
            operationGroup: .create,
            selectedSpellings: ["merchandise"],
            interpretationStatus: "UNPUBLISHED",
            result: ExecutionSummary(
                group: .create,
                succeeded: 1,
                failed: 0,
                cancelled: false,
                stalePreview: false,
                results: [ItemExecutionResult(spelling: "merchandise", outcome: .confirmed)]
            )
        )
        XCTAssertEqual(interpretationReceipt.interpretationStatus, "UNPUBLISHED")
        XCTAssertEqual(interpretationReceipt.publicationLabel, "未发布")

        let phraseReceipt = ExecutionReceipt(
            contentKind: .phrase,
            operationGroup: .create,
            selectedSpellings: ["take into account"],
            result: ExecutionSummary(
                group: .create,
                succeeded: 1,
                failed: 0,
                cancelled: false,
                stalePreview: false,
                results: [
                    ItemExecutionResult(spelling: "take into account", outcome: .confirmed),
                ]
            )
        )
        XCTAssertNil(phraseReceipt.interpretationStatus)
        XCTAssertNil(phraseReceipt.publicationLabel)

        // Round-trips, and an old receipt without the key still decodes.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(
            ExecutionReceipt.self,
            from: try encoder.encode(interpretationReceipt)
        )
        XCTAssertEqual(restored.interpretationStatus, "UNPUBLISHED")
    }
}
