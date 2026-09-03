import XCTest
@testable import MomoMoreEfficient

/// #76: a mixed actionable batch is paste once → Preview once → one Run → one
/// native confirmation → automatic CREATE then UPDATE.
///
/// Internal state stays separated: two phases, two fresh preflights, two History
/// receipts. Only the Owner's workflow is collapsed.
@MainActor
final class MixedBatchRunTests: XCTestCase {

    // MARK: - One approval drives both phases

    func testOneApprovalRunsEightCreatesThenTwoUpdatesToFullSuccess() async throws {
        let plan = MixedPlan.eightCreateTwoUpdate
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight                       // whole-batch execution-time gate
                + plan.createWrites               // CREATE phase
                + plan.updatePreflight            // fresh preflight of the remainder
                + plan.updateWrites,              // UPDATE phase
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = plan.document
        await model.previewCurrentInput()

        XCTAssertEqual(model.preview?.counts, PreviewCounts(
            create: 8,
            update: 2,
            alreadyMatching: 0,
            blocked: 0
        ))
        XCTAssertEqual(
            model.executionActions.map(\.title),
            ["执行 10 条（新建 8 · 更新 2）"]
        )

        // One explicit Run action, one native confirmation.
        model.askToExecuteWholePlan()
        let pending = try XCTUnwrap(model.pendingBatchConfirmation)
        XCTAssertEqual(pending.totalCount, 10)
        XCTAssertEqual(pending.createCount, 8)
        XCTAssertEqual(pending.updateCount, 2)
        XCTAssertEqual(pending.updateSpellings, ["manning", "certified"])

        await model.executeConfirmedWholePlan()?.value

        // Both phases wrote, exactly once per item.
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 10)
        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(model.history.map(\.operationGroup), [.update, .create])
        XCTAssertEqual(model.history.first(where: { $0.operationGroup == .create })?.succeeded, 8)
        XCTAssertEqual(model.history.first(where: { $0.operationGroup == .update })?.succeeded, 2)
        XCTAssertTrue(model.history.allSatisfy(\.isFullSuccess))
        XCTAssertEqual(historyStore.saveCount, 2)
        // Final state: empty editor, one concise acknowledgement.
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.localParseState, .empty)
        XCTAssertEqual(model.completionAcknowledgement, "已完成 10 条 · 新建 8 · 更新 2")
        XCTAssertNil(model.errorMessage)
        XCTAssertFalse(model.hasExecutionFeedback)
    }

    func testTheOwnerIsAskedForExactlyOneApprovalAndNoSecondOneIsMinted() async {
        let plan = MixedPlan.eightCreateTwoUpdate
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory)
        model.sourceText = plan.document
        await model.previewCurrentInput()

        model.askToExecuteWholePlan()
        XCTAssertNotNil(model.pendingBatchConfirmation)
        // A whole-plan arming never leaves a per-group confirmation behind.
        XCTAssertNil(model.pendingConfirmation)

        let execution = model.executeConfirmedWholePlan()
        // Consumed by the run itself; nothing re-arms it mid-flight.
        XCTAssertNil(model.pendingBatchConfirmation)
        await execution?.value

        // Not at any point during or after the run.
        XCTAssertNil(model.pendingBatchConfirmation)
        XCTAssertNil(model.pendingConfirmation)
        // And the consumed approval cannot be replayed.
        XCTAssertNil(model.executeConfirmedWholePlan())
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 10)
    }

    func testConfirmedRunWithoutAnArmedWholePlanApprovalSendsZeroPOST() async {
        let plan = MixedPlan.eightCreateTwoUpdate
        let factory = SequencedTransportFactory([plan.preflight])
        let model = connectedModel(factory)
        model.sourceText = plan.document
        await model.previewCurrentInput()

        XCTAssertNil(model.executeConfirmedWholePlan())

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertEqual(model.errorMessage, CompanionError.approvalRequired.description)
        XCTAssertTrue(model.history.isEmpty)
    }

    func testWholePlanApprovalCannotAuthorizeADifferentPlan() async throws {
        let plan = MixedPlan.eightCreateTwoUpdate
        let (shown, _, _) = try await makeSnapshot(
            document: plan.document,
            results: plan.preflight
        )
        let other = MixedPlan.twoCreateOneUpdate
        let (otherShown, _, _) = try await makeSnapshot(
            document: other.document,
            results: other.preflight
        )
        let approval = try ConfirmationBinding.makeBatchApproval(snapshot: shown)

        XCTAssertNotEqual(
            approval,
            try ConfirmationBinding.makeBatchApproval(snapshot: otherShown)
        )

        let transport = FakeHTTPTransport(other.preflight)
        let lease = try credentialLease()
        defer { lease.clear() }
        let result = await WriteExecutor(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).executeBatchPlan(
            displayedSnapshot: otherShown,
            approval: approval,
            control: ExecutionControl()
        )

        XCTAssertEqual(result.outcome, .stale)
        XCTAssertEqual(transport.postCount, 0)
    }

    // MARK: - Whole-batch gate before the first POST

    func testWholeBatchFreshPreflightRunsBeforeTheFirstPOST() async throws {
        let plan = MixedPlan.eightCreateTwoUpdate
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        let requests = factory.transports[1].requests
        let firstPOST = try XCTUnwrap(requests.firstIndex { $0.route.isMutating })
        // Every one of the ten approved items was re-read before anything was
        // written: one batch vocabulary resolution + 10 interpretations reads.
        // This is the gate a per-item read → POST fusion would destroy.
        XCTAssertEqual(firstPOST, 11)
        XCTAssertTrue(requests.prefix(firstPOST).allSatisfy { !$0.route.isMutating })
    }

    func testStateChangeBeforeTheFirstPOSTStopsWithZeroPOST() async {
        let plan = MixedPlan.twoCreateOneUpdate
        // The execution-time preflight now sees a different baseline on the
        // UPDATE target — the last entry, so items 1…N-1 would already have been
        // written under a per-item fusion.
        var changed = plan.preflight
        changed[changed.count - 1] = interpretationsResponse([
            interpretation("INVALID_RECORD_2", "n. 别的旧释义", tags: ["考研"]),
        ])
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([plan.preflight, changed])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertEqual(model.errorMessage, CompanionError.stalePreview.description)
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertEqual(historyStore.saveCount, 0)
        // Nothing was written, so the whole draft is preserved untouched.
        XCTAssertEqual(model.sourceText, plan.document)
    }

    func testEveryPOSTIsUniqueAndImmediatelyFollowedByItsReadback() async {
        let plan = MixedPlan.eightCreateTwoUpdate
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        let requests = factory.transports[1].requests
        let posts = requests.filter { $0.route.isMutating }
        XCTAssertEqual(posts.count, 10)
        // Max one POST per item, across both phases: no request ever repeats.
        for i in posts.indices {
            for j in posts.indices where j > i {
                XCTAssertNotEqual(posts[i], posts[j], "duplicate POST at \(i)/\(j)")
            }
        }
        // Immediate readback: every POST is followed straight away by a GET.
        for (index, request) in requests.enumerated() where request.route.isMutating {
            XCTAssertLessThan(index + 1, requests.count)
            XCTAssertEqual(requests[index + 1].route.method, .get, "POST at \(index)")
        }
    }

    // MARK: - The second phase is freshly preflighted and separately validated

    func testUpdatePhaseIsFreshlyPreflightedAfterCreateSucceeds() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        let requests = factory.transports[1].requests
        let posts = requests.enumerated().filter { $0.element.route.isMutating }
        XCTAssertEqual(posts.count, 3)
        // Between the last CREATE POST's readback and the UPDATE POST there is a
        // fresh read pair for the update target: its own preflight.
        let lastCreatePOST = posts[1].offset
        let updatePOST = posts[2].offset
        let between = requests[(lastCreatePOST + 1)..<updatePOST]
        XCTAssertTrue(between.allSatisfy { !$0.route.isMutating })
        // readback of create #2, then batch resolution + interpretations for the update.
        XCTAssertEqual(between.count, 3)
        XCTAssertEqual(model.history.count, 2)
    }

    func testChangedUpdateSubsetAfterCreateKeepsCreateAndSendsZeroUpdatePOST() async {
        let plan = MixedPlan.twoCreateOneUpdate
        // The UPDATE target's own fresh preflight no longer matches the approved
        // subplan: someone edited that interpretation while CREATE was running.
        let movedUpdatePreflight: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_2", spelling: "manning")]),
            interpretationsResponse([
                interpretation("INVALID_RECORD_2", "n. 被别处改过", tags: ["考研"]),
            ]),
        ]
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + movedUpdatePreflight,
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        // The two CREATEs stay committed; not one UPDATE POST was sent.
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 2)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .create)
        XCTAssertEqual(model.history.first?.succeeded, 2)
        XCTAssertTrue(model.history.first?.isFullSuccess == true)
        // No fake UPDATE receipt.
        XCTAssertFalse(model.history.contains { $0.operationGroup == .update })
        XCTAssertEqual(model.errorMessage, CompanionError.remainingPhaseChanged.description)
        // Only the still-pending UPDATE source survives, for a future fresh Preview.
        XCTAssertEqual(model.sourceText, "## manning\nn. 人员配置")
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.completionAcknowledgement)
        XCTAssertTrue(model.hasExecutionFeedback)
        XCTAssertEqual(model.finalSummary.created, 2)
        XCTAssertEqual(model.finalSummary.updated, 0)
        XCTAssertEqual(model.finalSummary.notAttempted, 1)
        XCTAssertTrue(model.finalSummary.stopped)
    }

    func testARemainingPhaseIsNeverAdmittedByTheEarlierPhasesApproval() async throws {
        let plan = MixedPlan.twoCreateOneUpdate
        let (shown, _, _) = try await makeSnapshot(
            document: plan.document,
            results: plan.preflight
        )
        let approval = try ConfirmationBinding.makeBatchApproval(snapshot: shown)
        let createPhase = try XCTUnwrap(approval.phase(for: .create))
        let updatePhase = try XCTUnwrap(approval.phase(for: .update))

        // Each phase carries its own operation-group binding digest, verbatim.
        XCTAssertNotEqual(createPhase.bindingDigest, updatePhase.bindingDigest)
        XCTAssertNotEqual(createPhase.batchDigest, updatePhase.batchDigest)
        XCTAssertEqual(
            createPhase.bindingDigest,
            try ConfirmationBinding.makePlan(snapshot: shown, group: .create).bindingDigest
        )
        XCTAssertEqual(
            updatePhase.bindingDigest,
            try ConfirmationBinding.makePlan(snapshot: shown, group: .update).bindingDigest
        )
        // Deterministic ordering: CREATE first, then UPDATE.
        XCTAssertEqual(approval.phases.map(\.group), [.create, .update])
        // The whole-plan digest is not any phase's digest.
        XCTAssertNotEqual(approval.bindingDigest, createPhase.bindingDigest)
        XCTAssertNotEqual(approval.bindingDigest, updatePhase.bindingDigest)
    }

    func testWholePlanApprovalIsBoundToTheExactDisplayedPreview() async throws {
        let plan = MixedPlan.twoCreateOneUpdate
        let (shown, _, _) = try await makeSnapshot(
            document: plan.document,
            results: plan.preflight
        )
        // Same items, one different proposed body.
        let edited = plan.document.replacingOccurrences(of: "n. 人员配置", with: "n. 人员配置 2")
        let (editedShown, _, _) = try await makeSnapshot(
            document: edited,
            results: plan.preflight
        )

        let approval = try ConfirmationBinding.makeBatchApproval(snapshot: shown)
        let editedApproval = try ConfirmationBinding.makeBatchApproval(snapshot: editedShown)
        XCTAssertNotEqual(approval, editedApproval)
        XCTAssertNotEqual(approval.bindingDigest, editedApproval.bindingDigest)
        XCTAssertNotEqual(approval.snapshotIdentity, editedApproval.snapshotIdentity)

        let batchPlan = try ConfirmationBinding.makeBatchPlan(snapshot: shown)
        XCTAssertEqual(batchPlan.totalItemCount, 3)
        XCTAssertEqual(
            batchPlan.expectedConfirmation,
            "CONFIRM MAIN BATCH \(batchPlan.bindingDigest)"
        )
    }

    // MARK: - A failed or stopped phase never lets the next one begin

    func testCreateFailureStopsTheRunBeforeUpdateEverStarts() async {
        let plan = MixedPlan.twoCreateOneUpdate
        // The first CREATE reads back as something else: an unverified write.
        let brokenCreateWrites: [StubbedResult] = [
            jsonResponse([:], status: 201),
            interpretationsResponse([]),
        ]
        let historyStore = InMemoryHistoryStore()
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + brokenCreateWrites,
        ])
        let model = connectedModel(factory, historyStore: historyStore)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .create)
        XCTAssertFalse(model.history.contains { $0.operationGroup == .update })
        XCTAssertEqual(model.errorMessage, CompanionError.uncertainWriteOutcome.description)
        // The earlier phase did not commit cleanly: nothing is trimmed away.
        XCTAssertEqual(model.sourceText, plan.document)
        XCTAssertNil(model.completionAcknowledgement)
        XCTAssertEqual(model.finalSummary.failed, 0)
        XCTAssertEqual(model.finalSummary.unconfirmed, 1)
        XCTAssertEqual(model.finalSummary.notAttempted, 2)
    }

    func testUpdateFailureIsNotRetriedOrReplayed() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let failingUpdateWrites: [StubbedResult] = [
            jsonResponse([:]),
            interpretationsResponse([
                interpretation("INVALID_RECORD_2", "n. 没有写进去", tags: ["考研"]),
            ]),
        ]
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + failingUpdateWrites,
        ])
        let model = connectedModel(factory)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        // Exactly one UPDATE POST, never a second attempt.
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 3)
        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(model.history.first?.operationGroup, .update)
        XCTAssertEqual(model.history.first?.failed, 0)
        XCTAssertEqual(model.history.first?.unconfirmed, 1)
        XCTAssertEqual(model.history.first?.items.map(\.finalOutcome), [.notVerified])
        XCTAssertEqual(model.errorMessage, CompanionError.uncertainWriteOutcome.description)
        // CREATE committed, so the recoverable remainder is the UPDATE source.
        XCTAssertEqual(model.sourceText, "## manning\nn. 人员配置")
        XCTAssertNil(model.completionAcknowledgement)
        XCTAssertFalse(model.hasExecutablePreview)

        // Nothing re-runs on its own.
        let postsAfterStop = factory.transports.reduce(0) { $0 + $1.postCount }
        await model.enterForeground()
        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, postsAfterStop)
        XCTAssertNil(model.executeConfirmedWholePlan())
    }

    // MARK: - #75 background behaviour across the phase boundary

    func testBackgroundingAcrossTheCreateToUpdateHandoverDoesNotCancelTheRun() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        let execution = model.executeConfirmedWholePlan()
        // A call arrives and the Owner switches away and back, spanning the
        // CREATE → UPDATE handover.
        model.enterBackground()
        await model.enterForeground()
        model.enterBackground()
        await execution?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 3)
        XCTAssertEqual(model.history.count, 2)
        XCTAssertTrue(model.history.allSatisfy(\.isFullSuccess))
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.completionAcknowledgement, "已完成 3 条 · 新建 2 · 更新 1")
    }

    func testOneFiniteAssertionCoversTheWholeOrchestration() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        let afterPreview = assertion.beginCount
        model.askToExecuteWholePlan()

        let execution = model.executeConfirmedWholePlan()
        // Exactly one for the whole run, held across both phases.
        XCTAssertEqual(assertion.beginCount, afterPreview + 1)
        XCTAssertTrue(assertion.isHeld)
        await execution?.value

        XCTAssertEqual(assertion.beginCount, afterPreview + 1)
        XCTAssertEqual(assertion.endCount, afterPreview + 1)
        XCTAssertFalse(assertion.isHeld)
    }

    func testBackgroundExpiryDuringCreateProducesADeterministicStoppedState() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let assertion = FakeBackgroundExecutionAssertion()
        let previewTransport = FakeHTTPTransport(plan.preflight)
        let executionTransport = PausingPOSTTransport(
            plan.preflight + [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD_A", "n. 崩塌")]),
            ]
        )
        let model = connectedModel(
            transports: [previewTransport, executionTransport],
            assertion: assertion
        )
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        let execution = model.executeConfirmedWholePlan()
        await executionTransport.waitUntilPOSTDispatched()
        assertion.expire()
        await executionTransport.resumePOST()
        await execution?.value

        // The in-flight item keeps its readback; nothing after it is dispatched,
        // and the UPDATE phase never begins.
        let postCount = await executionTransport.postCount
        XCTAssertEqual(postCount, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .create)
        XCTAssertEqual(
            model.history.first?.items.map(\.finalOutcome),
            [.confirmed, .notAttempted]
        )
        XCTAssertFalse(model.history.contains { $0.operationGroup == .update })
        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(model.finalSummary.created, 1)
        XCTAssertEqual(model.finalSummary.notAttempted, 2)
        // The earlier phase did not commit cleanly, so the draft is kept whole.
        XCTAssertEqual(model.sourceText, plan.document)
    }

    func testBackgroundExpiryImmediatelyAfterConfirmSendsZeroPOST() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        let execution = model.executeConfirmedWholePlan()
        assertion.expire()
        await execution?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 0)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(
            model.history.first?.items.map(\.finalOutcome),
            [.notAttempted, .notAttempted]
        )
        XCTAssertTrue(model.finalSummary.stopped)
        XCTAssertEqual(model.finalSummary.notAttempted, 3)
        XCTAssertEqual(model.sourceText, plan.document)
    }

    func testAnExpiredWholePlanRunIsNeverResumedOnReturn() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let assertion = FakeBackgroundExecutionAssertion()
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory, assertion: assertion)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()
        let execution = model.executeConfirmedWholePlan()
        assertion.expire()
        await execution?.value
        let postsAfterStop = factory.transports.reduce(0) { $0 + $1.postCount }

        await model.enterForeground()

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, postsAfterStop)
        XCTAssertFalse(model.isExecuting)
        XCTAssertNil(model.executionStage)
        XCTAssertNil(model.pendingBatchConfirmation)
        XCTAssertFalse(model.hasExecutablePreview)
        XCTAssertNil(model.executeConfirmedWholePlan())
        XCTAssertEqual(model.history.count, 1)
    }

    // MARK: - Progress presentation

    func testWholeRunShowsCompactSecuringAndNumberedWritesOnly() async {
        let plan = MixedPlan.twoCreateOneUpdate
        let factory = SequencedTransportFactory([
            plan.preflight,
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites,
        ])
        let model = connectedModel(factory)
        model.sourceText = plan.document
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        let execution = model.executeConfirmedWholePlan()
        XCTAssertEqual(model.executionStage, .securing)
        XCTAssertEqual(model.executionProgressLabel, "安全确认中…")
        await execution?.value

        XCTAssertNil(model.executionStage)
        XCTAssertNil(model.executionProgressLabel)
    }

    func testExecutorReportsSecuringOncePerPhaseAndNumbersOnlyWrites() async throws {
        let plan = MixedPlan.twoCreateOneUpdate
        let (shown, _, _) = try await makeSnapshot(
            document: plan.document,
            results: plan.preflight
        )
        let transport = FakeHTTPTransport(
            plan.preflight + plan.createWrites + plan.updatePreflight + plan.updateWrites
        )
        let lease = try credentialLease()
        defer { lease.clear() }
        let recorder = StageRecorder()

        let result = await WriteExecutor(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).executeBatchPlan(
            displayedSnapshot: shown,
            approval: try ConfirmationBinding.makeBatchApproval(snapshot: shown),
            control: ExecutionControl(),
            progress: ExecutionProgressReporter { recorder.record($0) }
        )

        XCTAssertEqual(result.outcome, .completed)
        let stages = recorder.stages
        // One compact stage per fresh preflight: the whole batch, then the
        // remaining UPDATE subset. Never a 1/N pass for either.
        XCTAssertEqual(stages.filter { $0 == .securing }.count, 2)
        XCTAssertEqual(
            stages.compactMap { stage -> String? in
                guard case .writing = stage else { return nil }
                return stage.label
            },
            ["正在新建 1/2 · collapse", "正在新建 2/2 · ledger", "正在更新 1/1 · manning"]
        )
        for stage in stages where !stage.isWriting {
            XCTAssertFalse(stage.label.contains("/"), stage.label)
        }
    }

    // MARK: - Single-group batches are untouched

    func testSingleGroupSuccessPreservesBlockedSourceInOriginalOrder() async throws {
        let source = "create\nn. 新建\nblocked-one\nn. 待处理一\nblocked-two\nn. 待处理二"
        let ambiguous = [
            interpretation("INVALID_RECORD_A", "n. 旧一"),
            interpretation("INVALID_RECORD_B", "n. 旧二"),
        ]
        let preflight: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_CREATE", spelling: "create"), (id: "INVALID_VOC_BLOCKED_1", spelling: "blocked-one"), (id: "INVALID_VOC_BLOCKED_2", spelling: "blocked-two")]), interpretationsResponse([]),
            interpretationsResponse(ambiguous),
            interpretationsResponse(ambiguous),
        ]
        let factory = SequencedTransportFactory([
            preflight,
            preflight + [
                jsonResponse([:], status: 201),
                interpretationsResponse([
                    interpretation("INVALID_CREATED", "n. 新建"),
                ]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = source
        await model.previewCurrentInput()
        XCTAssertEqual(model.preview?.counts.blocked, 2)
        model.askToExecute(.create)

        await model.executeConfirmed(.create)?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.items.map(\.spelling), ["create"])
        XCTAssertEqual(
            model.sourceText,
            "## blocked-one\nn. 待处理一\n\n## blocked-two\nn. 待处理二"
        )
        let remainder = try BatchParser.parseDailyInput(model.sourceText).entries
        XCTAssertEqual(remainder.map(\.spelling), ["blocked-one", "blocked-two"])
    }

    func testMixedPlanSuccessPreservesBlockedSourceAfterBothReceipts() async throws {
        let source = "create\nn. 新建\nblocked\nn. 待处理\nupdate\nn. 新版"
        let oldUpdate = interpretation("INVALID_UPDATE", "n. 旧版")
        let ambiguous = [
            interpretation("INVALID_BLOCKED_A", "n. 旧一"),
            interpretation("INVALID_BLOCKED_B", "n. 旧二"),
        ]
        let fullPreflight: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_CREATE", spelling: "create"), (id: "INVALID_VOC_BLOCKED", spelling: "blocked"), (id: "INVALID_VOC_UPDATE", spelling: "update")]), interpretationsResponse([]),
            interpretationsResponse(ambiguous),
            interpretationsResponse([oldUpdate]),
        ]
        let factory = SequencedTransportFactory([
            fullPreflight,
            fullPreflight + [
                jsonResponse([:], status: 201),
                interpretationsResponse([
                    interpretation("INVALID_CREATED", "n. 新建"),
                ]),
                vocabularyQueryResponse([(id: "INVALID_VOC_UPDATE", spelling: "update")]),
                interpretationsResponse([oldUpdate]),
                jsonResponse([:]),
                interpretationsResponse([
                    interpretation("INVALID_UPDATE", "n. 新版"),
                ]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = source
        await model.previewCurrentInput()
        XCTAssertEqual(model.preview?.counts, PreviewCounts(
            create: 1,
            update: 1,
            alreadyMatching: 0,
            blocked: 1
        ))
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 2)
        XCTAssertEqual(model.history.count, 2)
        XCTAssertTrue(model.history.allSatisfy(\.isFullSuccess))
        XCTAssertEqual(model.sourceText, "## blocked\nn. 待处理")
        let remainder = try BatchParser.parseDailyInput(model.sourceText).entries
        XCTAssertEqual(remainder.map(\.spelling), ["blocked"])
    }

    func testLaterPhaseGlobalFailureKeepsCompletedReceiptAndPendingSource() async {
        let source = "create\nn. 新建\nupdate\nn. 新版"
        let oldUpdate = interpretation("INVALID_UPDATE", "n. 旧版")
        let preflight: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_CREATE", spelling: "create"), (id: "INVALID_VOC_UPDATE", spelling: "update")]), interpretationsResponse([]),
            interpretationsResponse([oldUpdate]),
        ]
        let factory = SequencedTransportFactory([
            preflight,
            preflight + [
                jsonResponse([:], status: 201),
                interpretationsResponse([
                    interpretation("INVALID_CREATED", "n. 新建"),
                ]),
                jsonResponse(["error": "server"], status: 503),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = source
        await model.previewCurrentInput()
        model.askToExecuteWholePlan()

        await model.executeConfirmedWholePlan()?.value

        XCTAssertEqual(factory.transports.reduce(0) { $0 + $1.postCount }, 1)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.history.first?.operationGroup, .create)
        XCTAssertTrue(model.history.first?.isFullSuccess == true)
        XCTAssertEqual(model.sourceText, "## update\nn. 新版")
        XCTAssertEqual(model.errorMessage, CompanionError.serverFailure.description)
        XCTAssertTrue(model.isConnected)
    }

    func testSingleGroupBatchStillRunsThroughItsOwnSimpleFlow() async {
        let factory = SequencedTransportFactory([
            [vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([])],
            [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "word")]), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()

        XCTAssertFalse(model.executionActions.contains { $0.coversWholePlan })
        XCTAssertEqual(model.executionActions.map(\.title), ["新建 1", "更新 0"])

        model.askToExecute(.create)
        XCTAssertEqual(model.pendingConfirmation, .create)
        XCTAssertNil(model.pendingBatchConfirmation)
        await model.executeConfirmed(.create)?.value

        XCTAssertEqual(model.history.count, 1)
        XCTAssertEqual(model.completionAcknowledgement, "已新建 1 条 · word")
        XCTAssertEqual(model.sourceText, "")
    }

    // MARK: - Confirmation copy

    func testConfirmationStatesTotalBothMembershipsAndTheBindingDigest() {
        let pending = PendingBatchConfirmation(
            createSpellings: ["collapse", "ledger"],
            updateSpellings: ["manning", "certified"],
            bindingDigest: "0123456789abcdef"
        )

        XCTAssertEqual(pending.title, "确认执行 4 条？")
        XCTAssertEqual(pending.actionTitle, "确认执行 4 条（新建 2 · 更新 2）")
        XCTAssertTrue(pending.message.contains("共 4 条 · 新建 2 · 更新 2"))
        XCTAssertTrue(pending.message.contains("新建：collapse、ledger"))
        XCTAssertTrue(pending.message.contains("更新：manning、certified"))
        XCTAssertTrue(pending.message.contains("授权指纹 0123456789abcdef"))
        XCTAssertTrue(pending.message.contains("每项最多一次 POST，不重试。"))
        XCTAssertFalse(pending.message.contains(fakeToken))
    }

    // MARK: - Rehearsal harness

    /// The exact mixed shape the Owner rehearses on the physical device.
    func testRehearsalHarnessCompletesAMixedRunFromOneApproval() async {
        let model = CompanionViewModel.makeRehearsal(
            perRequestDelaySeconds: 0,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { FakeBackgroundExecutionAssertion() }
        )
        await model.enterForeground()
        model.sourceText = [
            "collapse\nn. 崩塌",
            "ledger\nn. 分类账",
            "manning\nn. 人员配置",
            "certified\nadj. 已认证",
        ].joined(separator: "\n")

        await model.previewCurrentInput()

        XCTAssertEqual(model.preview?.counts, PreviewCounts(
            create: 2,
            update: 2,
            alreadyMatching: 0,
            blocked: 0
        ))
        XCTAssertEqual(model.executionActions.map(\.title), ["执行 4 条（新建 2 · 更新 2）"])

        model.askToExecuteWholePlan()
        await model.executeConfirmedWholePlan()?.value

        XCTAssertEqual(model.history.count, 2)
        XCTAssertEqual(model.history.map(\.operationGroup), [.update, .create])
        XCTAssertTrue(model.history.allSatisfy(\.isFullSuccess))
        XCTAssertEqual(model.sourceText, "")
        XCTAssertEqual(model.completionAcknowledgement, "已完成 4 条 · 新建 2 · 更新 2")
    }

    // MARK: - Helpers

    private func connectedModel(
        _ factory: SequencedTransportFactory,
        historyStore: HistoryStore = InMemoryHistoryStore(),
        assertion: FakeBackgroundExecutionAssertion? = nil
    ) -> CompanionViewModel {
        let assertion = assertion ?? FakeBackgroundExecutionAssertion()
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: historyStore,
            transportFactory: factory.make,
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        return model
    }

    private func connectedModel(
        transports: [HTTPTransport],
        historyStore: HistoryStore = InMemoryHistoryStore(),
        assertion: FakeBackgroundExecutionAssertion? = nil
    ) -> CompanionViewModel {
        let assertion = assertion ?? FakeBackgroundExecutionAssertion()
        var remaining = transports
        let model = CompanionViewModel(
            tokenStore: FakeTokenStore(),
            historyStore: historyStore,
            transportFactory: { remaining.removeFirst() },
            sleeperFactory: { RecordingSleeper() },
            backgroundAssertionFactory: { assertion }
        )
        var draft = fakeToken
        model.installVerifiedCredentialForTesting(token: &draft)
        return model
    }
}

private extension ExecutionStage {
    var isWriting: Bool {
        if case .writing = self { return true }
        return false
    }
}

/// A mixed batch and the canned server it is rehearsed against.
///
/// `manning` and `certified` are the UPDATE seeds — the same two spellings the
/// DEBUG rehearsal harness pre-populates — plus fake CREATE entries.
struct MixedPlan {
    let spellings: [String]
    let bodies: [String]
    /// Indexes, into `spellings`, of the entries that already have one
    /// self-authored interpretation and therefore classify as UPDATE.
    let updateIndexes: Set<Int>

    static let eightCreateTwoUpdate = MixedPlan(
        spellings: [
            "collapse", "ledger", "covenant", "arrears",
            "manning", "escrow", "indemnity", "accrual",
            "certified", "tranche",
        ],
        bodies: [
            "n. 崩塌", "n. 分类账", "n. 契约", "n. 欠款",
            "n. 人员配置", "n. 第三方托管", "n. 赔偿", "n. 应计",
            "adj. 已认证", "n. 分批",
        ],
        updateIndexes: [4, 8]
    )

    static let twoCreateOneUpdate = MixedPlan(
        spellings: ["collapse", "ledger", "manning"],
        bodies: ["n. 崩塌", "n. 分类账", "n. 人员配置"],
        updateIndexes: [2]
    )

    var document: String {
        zip(spellings, bodies).map { "\($0)\n\($1)" }.joined(separator: "\n")
    }

    var createIndexes: [Int] {
        spellings.indices.filter { !updateIndexes.contains($0) }
    }

    var sortedUpdateIndexes: [Int] {
        updateIndexes.sorted()
    }

    /// One batch vocabulary resolution, then one interpretations read per
    /// entry, in document order.
    var preflight: [StubbedResult] {
        [batchVocabulary(spellings.indices)] + spellings.indices.map { index in
            updateIndexes.contains(index)
                ? interpretationsResponse([staleRecord(index)])
                : interpretationsResponse([])
        }
    }

    /// POST + immediate readback for every CREATE item, in phase order.
    var createWrites: [StubbedResult] {
        createIndexes.flatMap { index -> [StubbedResult] in
            [
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation(recordID(index), bodies[index])]),
            ]
        }
    }

    /// The remaining UPDATE subset's own fresh preflight.
    var updatePreflight: [StubbedResult] {
        [batchVocabulary(sortedUpdateIndexes)] + sortedUpdateIndexes.map { index in
            interpretationsResponse([staleRecord(index)])
        }
    }

    private func batchVocabulary(_ indexes: some Sequence<Int>) -> StubbedResult {
        vocabularyQueryResponse(
            indexes.map { (id: vocabularyID($0), spelling: spellings[$0]) }
        )
    }

    var updateWrites: [StubbedResult] {
        sortedUpdateIndexes.flatMap { index -> [StubbedResult] in
            [
                jsonResponse([:]),
                interpretationsResponse([interpretation(recordID(index), bodies[index])]),
            ]
        }
    }

    private func vocabularyID(_ index: Int) -> String { "INVALID_VOC_\(index)" }

    private func recordID(_ index: Int) -> String { "INVALID_RECORD_\(index)" }

    private func staleRecord(_ index: Int) -> [String: Any] {
        interpretation(recordID(index), "n. 演练用旧释义", tags: ["考研"])
    }
}
