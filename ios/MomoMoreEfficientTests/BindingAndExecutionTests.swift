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
            let rows = privateItems.map { $0.publicRow(tags: legacyTestTags) }
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
                    items: privateItems,
                    tags: legacyTestTags
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

    func testInterpretationCreateBodiesUseEmptyAndSelectedTags() throws {
        let empty = try syntheticSnapshot(group: .create, tags: [])
        let emptyPlan = try ConfirmationBinding.makePlan(snapshot: empty, group: .create)
        let emptyBody = ConfirmationBinding.requestBody(
            try XCTUnwrap(emptyPlan.items.first),
            group: .create,
            tags: emptyPlan.tags
        )
        let emptyPayload = try XCTUnwrap(emptyBody["interpretation"] as? [String: Any])
        XCTAssertEqual(emptyPayload["tags"] as? [String], [])

        let selected = try syntheticSnapshot(group: .create, tags: ["MBA", "BEC"])
        let selectedPlan = try ConfirmationBinding.makePlan(
            snapshot: selected,
            group: .create
        )
        let selectedBody = ConfirmationBinding.requestBody(
            try XCTUnwrap(selectedPlan.items.first),
            group: .create,
            tags: selectedPlan.tags
        )
        let selectedPayload = try XCTUnwrap(
            selectedBody["interpretation"] as? [String: Any]
        )
        XCTAssertEqual(selectedPayload["tags"] as? [String], ["MBA", "BEC"])
    }

    func testTagOnlyInterpretationDifferenceIsVisibleAndExecutesApprovedTags() async throws {
        let document = "word\nn. 保持正文"
        let old = interpretation("INVALID_RECORD", "n. 保持正文", tags: [])
        let (shown, _, _) = try await makeSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "word"),
                interpretationsResponse([old]),
            ],
            tags: ["MBA"]
        )
        XCTAssertEqual(shown.presentation.counts.update, 1)
        XCTAssertEqual(shown.presentation.rows[0].current, "n. 保持正文")
        XCTAssertEqual(shown.presentation.rows[0].proposed, "n. 保持正文")
        XCTAssertEqual(shown.presentation.rows[0].currentTags, [])
        XCTAssertEqual(shown.presentation.rows[0].proposedTags, ["MBA"])

        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([old]),
            jsonResponse([:]),
            interpretationsResponse([
                interpretation("INVALID_RECORD", "n. 保持正文", tags: ["MBA"]),
            ]),
        ])
        let (summary, requests) = try await execute(
            snapshot: shown,
            group: .update,
            transport: transport
        )
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(transport.postCount, 1)
        let post = try XCTUnwrap(requests.first(where: { $0.route.method == .post }))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(post.body)) as? [String: Any]
        )
        let payload = try XCTUnwrap(object["interpretation"] as? [String: Any])
        XCTAssertEqual(payload["tags"] as? [String], ["MBA"])
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
        XCTAssertEqual(summary.results[0].diagnostic?.postDispatch, .clean2xx(status: 201))
        XCTAssertEqual(
            summary.results[0].diagnostic?.readbackAttempts.map(\.category),
            [.success]
        )
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
            "UIPasteboard", "os_log", "NSUbiquitousKeyValueStore",
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

        let defaultsFiles = Set(
            sources.compactMap { path, contents in
                contents.contains("UserDefaults") ? path : nil
            }
        )
        XCTAssertEqual(defaultsFiles, Set(["Core/Domain.swift", "UI/CompanionViewModel.swift"]))
        XCTAssertFalse(try XCTUnwrap(sources["Core/ExecutionHistory.swift"]).contains("selectedTags"))
        XCTAssertFalse(try XCTUnwrap(sources["Core/TokenStore.swift"]).contains("selectedTags"))

        let contentView = try XCTUnwrap(sources["UI/ContentView.swift"])
        XCTAssertFalse(contentView.contains("主账号"))
        let staleStart = try XCTUnwrap(contentView.range(of: "private var stalePreviewRow"))
        let staleEnd = try XCTUnwrap(
            contentView.range(
                of: "private func phrasePreviewRow",
                range: staleStart.upperBound..<contentView.endIndex
            )
        )
        let stalePreviewSource = String(
            contentView[staleStart.lowerBound..<staleEnd.lowerBound]
        )
        for required in [
            "if viewModel.isPreviewing", "ProgressView()",
            "Text(previewLoadingTitle(repreview: true))",
        ] {
            XCTAssertTrue(stalePreviewSource.contains(required), required)
        }
        XCTAssertTrue(
            contentView.contains(
                "正在重新预览 \\(progress.entry)/\\(progress.total)…"
            )
        )
        XCTAssertTrue(contentView.contains("return \"正在重新预览…\""))
        for requiredCopy in [
            "墨墨账号", "粘贴 Token", "录入偏好", "发布", "公开", "未填写",
            "复制或分享诊断信息",
            "墨墨 App → 我的 → 更多设置 → 实验功能 → 开放 API",
            "设备本地 Keychain", "不会上传给开发者或任何项目服务器",
            "独立第三方工具", "不是墨墨官方应用", "隐私说明", "项目与反馈",
        ] {
            XCTAssertTrue(contentView.contains(requiredCopy), requiredCopy)
        }
        XCTAssertTrue(contentView.contains("PasteButton(payloadType: String.self)"))
        XCTAssertTrue(contentView.contains("tokenDraft = pastedToken"))
        XCTAssertTrue(contentView.contains("Text(\"正在验证…\")"))
        XCTAssertTrue(contentView.contains("@State private var isSubmittingToken = false"))
        XCTAssertTrue(contentView.contains("isSubmittingToken = true\n                        Task {"))
        XCTAssertTrue(contentView.contains("isSubmittingToken || viewModel.isValidatingCredential"))
        XCTAssertTrue(contentView.contains(".interactiveDismissDisabled(tokenValidationIsInFlight)"))
        XCTAssertTrue(contentView.contains(".disabled(tokenValidationIsInFlight)"))

        let projectFile = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("MomoMoreEfficient.xcodeproj/project.pbxproj")
        let project = try String(contentsOf: projectFile, encoding: .utf8)
        XCTAssertEqual(
            project.components(separatedBy: "INFOPLIST_KEY_CFBundleDisplayName = \"小黑鸟伴侣\";").count - 1,
            2
        )
        XCTAssertEqual(
            project.components(separatedBy: "CURRENT_PROJECT_VERSION = 3;").count - 1,
            4 // app Debug/Release + Share Extension Debug/Release
        )
        XCTAssertEqual(
            project.components(separatedBy: "INFOPLIST_KEY_ITSAppUsesNonExemptEncryption = NO;").count - 1,
            2
        )
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

    private func syntheticSnapshot(
        group: OperationGroup,
        tags: [String] = legacyTestTags
    ) throws -> PreviewSnapshot {
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
            rows: [item.publicRow(tags: tags)],
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
            bindingContext: try ConfirmationBinding.makePreviewBindingContext(
                items: [item],
                tags: tags
            ),
            items: [item],
            presentation: presentation
        )
    }
}
