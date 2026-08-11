import Foundation
import XCTest
@testable import MomoMoreEfficient

final class BindingAndExecutionTests: XCTestCase {
    func testCrossLanguageGoldenVectorsMatchCurrentPython() throws {
        let url = try XCTUnwrap(
            Bundle(for: Self.self).url(
                forResource: "confirmation-golden-vectors",
                withExtension: "json"
            )
        )
        let fixture = try JSONDecoder().decode(GoldenFile.self, from: Data(contentsOf: url))
        let credential = try InMemoryCredential(token: fixture.fakeToken)
        XCTAssertEqual(credential.fingerprint, fixture.credentialFingerprint)

        for vector in fixture.vectors {
            let group: OperationGroup = vector.group == "create" ? .create : .update
            let privateItems = vector.items.enumerated().map { index, item in
                let entry = BatchEntry(
                    ordinal: index + 1,
                    spelling: item.spelling,
                    normalizedSpelling: BatchParser.normalizeSpelling(item.spelling),
                    interpretation: item.interpretation
                )
                let baseline = item.baseline.map {
                    InterpretationRecord(
                        id: $0.recordID,
                        interpretation: $0.interpretation,
                        tags: $0.tags,
                        status: $0.status
                    )
                }
                return PrivatePreflightItem(
                    entry: entry,
                    classification: group == .create ? .create : .update,
                    vocabularyID: item.vocabularyID,
                    baseline: baseline,
                    reason: nil
                )
            }
            let rows = privateItems.map(\.publicRow)
            let presentation = PreviewPresentation(
                rows: rows,
                counts: PreviewCounts(
                    create: group == .create ? rows.count : 0,
                    update: group == .update ? rows.count : 0,
                    alreadyMatching: 0,
                    blocked: 0
                )
            )
            let entries = privateItems.map(\.entry)
            let snapshot = PreviewSnapshot(
                sourceIdentity: try ConfirmationBinding.sourceIdentity(entries),
                credentialFingerprint: fixture.credentialFingerprint,
                accountMode: CompanionConstants.accountMode,
                bindingContext: try ConfirmationBinding.makePreviewBindingContext(
                    items: privateItems
                ),
                items: privateItems,
                presentation: presentation
            )
            let plan = try ConfirmationBinding.makePlan(snapshot: snapshot, group: group)
            XCTAssertEqual(plan.batchDigest, vector.batchDigest, vector.name)
            XCTAssertEqual(plan.bindingDigest, vector.bindingDigest, vector.name)
            XCTAssertEqual(plan.expectedConfirmation, vector.confirmation, vector.name)
        }
    }

    func testCreateAndUpdateConfirmationsAreIsolated() throws {
        let create = try syntheticSnapshot(group: .create)
        let update = try syntheticSnapshot(group: .update)
        let createApproval = try ConfirmationBinding.makeApproval(snapshot: create, group: .create)
        let updateApproval = try ConfirmationBinding.makeApproval(snapshot: update, group: .update)
        XCTAssertNotEqual(createApproval.bindingDigest, updateApproval.bindingDigest)
        XCTAssertTrue(
            try ConfirmationBinding.makePlan(snapshot: create, group: .create)
                .expectedConfirmation.hasPrefix("CONFIRM MAIN CREATE ")
        )
        XCTAssertTrue(
            try ConfirmationBinding.makePlan(snapshot: update, group: .update)
                .expectedConfirmation.hasPrefix("CONFIRM MAIN UPDATE ")
        )
    }

    func testPreviewSnapshotExplicitlyBindsPolicyAndBatchDigest() throws {
        let snapshot = try syntheticSnapshot(group: .create)
        let plan = try ConfirmationBinding.makePlan(snapshot: snapshot, group: .create)
        XCTAssertEqual(snapshot.bindingContext.host, "https://open.maimemo.com")
        XCTAssertEqual(snapshot.bindingContext.createPath, "/open/api/v1/interpretations")
        XCTAssertEqual(
            snapshot.bindingContext.updatePath,
            "/open/api/v1/interpretations/{record_id}"
        )
        XCTAssertEqual(snapshot.bindingContext.tags, ["MBA", "BEC", "GMAT"])
        XCTAssertEqual(snapshot.bindingContext.status, "PUBLISHED")
        XCTAssertEqual(snapshot.bindingContext.createBatchDigest, plan.batchDigest)
    }

    func testExactFreshCreatePlanExecutesOnePOSTAndImmediateReadback() async throws {
        let document = "word\nn. 新建"
        let (shown, _, _) = try await makeSnapshot(
            document: document,
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])]
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([]),
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
        ])
        let (summary, requests) = try await execute(
            snapshot: shown,
            group: .create,
            transport: transport
        )
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.confirmed])
        XCTAssertEqual(requests.map(\.route.method), [.get, .get, .post, .get])
        XCTAssertEqual(transport.postCount, 1)
    }

    func testChangedFreshPreflightReturnsStaleAndZeroPOST() async throws {
        let document = "word\nn. 新建"
        let (shown, _, _) = try await makeSnapshot(
            document: document,
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])]
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"),
            interpretationsResponse([
                interpretation("INVALID_RECORD", "n. 现在存在", tags: ["考研"]),
            ]),
        ])
        let (summary, _) = try await execute(snapshot: shown, group: .create, transport: transport)
        XCTAssertTrue(summary.stalePreview)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testTamperedOwnerApprovalCannotBypassChangedPlan() async throws {
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 新建",
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])]
        )
        let transport = FakeHTTPTransport([])
        let lease = try credentialLease()
        let executor = WriteExecutor(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        )
        let invalid = NativeApproval(
            group: .create,
            snapshotIdentity: "0",
            bindingDigest: "0"
        )
        let summary = await executor.execute(
            group: .create,
            displayedSnapshot: shown,
            approval: invalid,
            control: ExecutionControl()
        )
        XCTAssertTrue(summary.stalePreview)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUncertainCreatePOSTUsesGETOnlyRecoveryAndNoSecondPOST() async throws {
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 新建",
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])]
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([]),
            .failure(.transport),
            interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
        ])
        let (summary, _) = try await execute(snapshot: shown, group: .create, transport: transport)
        XCTAssertEqual(summary.results.map(\.outcome), [.recovered])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(transport.getCount, 3)
    }

    func testUncertainCreateWithoutExactStateStops() async throws {
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 新建",
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])]
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([]),
            .failure(.transport), interpretationsResponse([]),
        ])
        let (summary, _) = try await execute(snapshot: shown, group: .create, transport: transport)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
        XCTAssertEqual(transport.postCount, 1)
    }

    func testUpdatePOSTTargetsAndReadsBackSameRecord() async throws {
        let old = interpretation("INVALID_RECORD", "n. 旧", tags: ["考研"])
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 新",
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([old])]
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([old]),
            jsonResponse([:]),
            interpretationsResponse([interpretation("INVALID_RECORD", "n. 新")]),
        ])
        let (summary, requests) = try await execute(snapshot: shown, group: .update, transport: transport)
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(requests[2].route, .updateInterpretation(recordID: "INVALID_RECORD"))
        XCTAssertEqual(requests[3].route, .interpretations(vocabularyID: "INVALID_VOC"))
        XCTAssertEqual(transport.postCount, 1)
    }

    func testUpdateReadbackWithDifferentRecordFails() async throws {
        let old = interpretation("INVALID_RECORD", "n. 旧", tags: ["考研"])
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 新",
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([old])]
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([old]),
            jsonResponse([:]),
            interpretationsResponse([interpretation("INVALID_OTHER", "n. 新")]),
        ])
        let (summary, _) = try await execute(snapshot: shown, group: .update, transport: transport)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(transport.postCount, 1)
    }

    func testUncertainUpdatePOSTUsesGETOnlySameRecordRecovery() async throws {
        let old = interpretation("INVALID_RECORD", "n. 旧", tags: ["考研"])
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 新",
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([old])]
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([old]),
            .failure(.transport),
            interpretationsResponse([interpretation("INVALID_RECORD", "n. 新")]),
        ])
        let (summary, requests) = try await execute(
            snapshot: shown,
            group: .update,
            transport: transport
        )
        XCTAssertEqual(summary.results.map(\.outcome), [.recovered])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(requests.suffix(2).map(\.route.method), [.post, .get])
    }

    func testMatchingUpdateNeverFallsBackToCreate() async throws {
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 相同",
            results: [
                vocabularyResponse("INVALID_VOC", "word"),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 相同")]),
            ]
        )
        XCTAssertThrowsError(try ConfirmationBinding.makeApproval(snapshot: shown, group: .update))
        XCTAssertThrowsError(try ConfirmationBinding.makeApproval(snapshot: shown, group: .create))
    }

    func testRuntimeFailureStopsLaterItems() async throws {
        let document = "one\nn. 一\ntwo\nn. 二"
        let initial: [StubbedResult] = [
            vocabularyResponse("INVALID_VOC_A", "one"), interpretationsResponse([]),
            vocabularyResponse("INVALID_VOC_B", "two"), interpretationsResponse([]),
        ]
        let (shown, _, _) = try await makeSnapshot(document: document, results: initial)
        let transport = FakeHTTPTransport(initial + [
            jsonResponse([:], status: 201), interpretationsResponse([]),
        ])
        let (summary, _) = try await execute(snapshot: shown, group: .create, transport: transport)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(summary.results.count, 1)
    }

    func testCancellationBeforePOSTSendsZeroPOST() async throws {
        let (shown, _, _) = try await makeSnapshot(
            document: "word\nn. 新建",
            results: [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])]
        )
        let transport = FakeHTTPTransport([])
        let control = ExecutionControl()
        control.requestCancellation()
        let (summary, _) = try await execute(
            snapshot: shown,
            group: .create,
            transport: transport,
            control: control
        )
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testBackgroundAfterDispatchedPOSTAllowsReadbackButNoLaterWrite() async throws {
        let document = "one\nn. 一\ntwo\nn. 二"
        let initial: [StubbedResult] = [
            vocabularyResponse("INVALID_VOC_A", "one"), interpretationsResponse([]),
            vocabularyResponse("INVALID_VOC_B", "two"), interpretationsResponse([]),
        ]
        let (shown, _, _) = try await makeSnapshot(document: document, results: initial)
        let transport = FakeHTTPTransport(initial + [
            jsonResponse([:], status: 201),
            interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 一")]),
        ])
        let control = ExecutionControl()
        transport.onSend = { request in
            if request.route.method == .post { control.requestCancellation() }
        }
        let (summary, requests) = try await execute(
            snapshot: shown,
            group: .create,
            transport: transport,
            control: control
        )
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(requests.suffix(2).map(\.route.method), [.post, .get])
    }

    func testProductionSourcesContainNoUnreviewedPersistenceOrForbiddenRouteAPIs() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourceRoot = testsDirectory.deletingLastPathComponent().appendingPathComponent("MomoMoreEfficient")
        let files = try FileManager.default.subpathsOfDirectory(atPath: sourceRoot.path)
            .filter { $0.hasSuffix(".swift") }
        let sources = try Dictionary(uniqueKeysWithValues: files.map {
            (
                $0,
                try String(contentsOf: sourceRoot.appendingPathComponent($0), encoding: .utf8)
            )
        })
        let source = sources.values.joined(separator: "\n")
        for forbidden in [
            "UserDefaults", "UIPasteboard", "os_log", "NSUbiquitousKeyValueStore",
            "localStorage", "\"DELETE\"", "\"PATCH\"", "\"PUT\"",
        ] {
            XCTAssertFalse(source.contains(forbidden), forbidden)
        }
        for (path, contents) in sources where path != "Core/ExecutionHistory.swift" {
            XCTAssertFalse(contents.contains("FileManager.default"), path)
            XCTAssertFalse(contents.contains("write(to:"), path)
        }
        for (path, contents) in sources where path != "Core/TokenStore.swift" {
            XCTAssertFalse(contents.contains("SecItem"), path)
            XCTAssertFalse(contents.contains("kSecAttr"), path)
        }
    }

    private func execute(
        snapshot: PreviewSnapshot,
        group: OperationGroup,
        transport: FakeHTTPTransport,
        control: ExecutionControl = ExecutionControl()
    ) async throws -> (ExecutionSummary, [TransportRequest]) {
        let lease = try credentialLease()
        let api = MaimemoTransport(
            transport: transport,
            credential: lease,
            sleeper: RecordingSleeper()
        )
        let summary = await WriteExecutor(api: api).execute(
            group: group,
            displayedSnapshot: snapshot,
            approval: try ConfirmationBinding.makeApproval(snapshot: snapshot, group: group),
            control: control
        )
        lease.clear()
        return (summary, transport.requests)
    }

    private func syntheticSnapshot(group: OperationGroup) throws -> PreviewSnapshot {
        let entry = BatchEntry(
            ordinal: 1,
            spelling: "word",
            normalizedSpelling: "word",
            interpretation: "n. 新"
        )
        let baseline = group == .update
            ? InterpretationRecord(
                id: "INVALID_RECORD",
                interpretation: "n. 旧",
                tags: ["考研"],
                status: "PUBLISHED"
            )
            : nil
        let item = PrivatePreflightItem(
            entry: entry,
            classification: group == .create ? .create : .update,
            vocabularyID: "INVALID_VOC",
            baseline: baseline,
            reason: nil
        )
        let presentation = PreviewPresentation(
            rows: [item.publicRow],
            counts: PreviewCounts(
                create: group == .create ? 1 : 0,
                update: group == .update ? 1 : 0,
                alreadyMatching: 0,
                blocked: 0
            )
        )
        return PreviewSnapshot(
            sourceIdentity: try ConfirmationBinding.sourceIdentity([entry]),
            credentialFingerprint: try InMemoryCredential(token: fakeToken).fingerprint,
            accountMode: CompanionConstants.accountMode,
            bindingContext: try ConfirmationBinding.makePreviewBindingContext(items: [item]),
            items: [item],
            presentation: presentation
        )
    }
}
