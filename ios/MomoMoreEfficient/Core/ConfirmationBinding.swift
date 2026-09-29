import CryptoKit
import Foundation

struct ConfirmationPlan {
    struct Item {
        let ordinal: Int
        let spelling: String
        let interpretation: String
        let vocabularyID: String
        let baseline: InterpretationRecord?

        var vocabularyFingerprint: String {
            SHA256.hash(data: Data(vocabularyID.utf8)).hexPrefix(16)
        }

        var recordFingerprint: String? {
            baseline.map { SHA256.hash(data: Data($0.id.utf8)).hexPrefix(16) }
        }
    }

    let group: OperationGroup
    let credentialFingerprint: String
    let tags: [String]
    /// The approved interpretation publication status for this plan, taken from
    /// the Preview snapshot's binding context — never from a live preference.
    let status: String
    let items: [Item]
    let batchDigest: String
    let bindingDigest: String
    let expectedConfirmation: String
}

struct NativeApproval: Equatable {
    let group: OperationGroup
    let snapshotIdentity: String
    let bindingDigest: String

    init(group: OperationGroup, snapshotIdentity: String, bindingDigest: String) {
        self.group = group
        self.snapshotIdentity = snapshotIdentity
        self.bindingDigest = bindingDigest
    }
}

/// The whole run the Owner authorizes with one native confirmation (#76).
///
/// It is built strictly *on top of* the existing per-group `ConfirmationPlan`s —
/// their digests are unchanged and still computed exactly as before — so a phase
/// is never authorized by anything weaker than its own operation-group binding.
/// What the batch plan adds is a single digest that additionally commits to the
/// exact displayed Preview and to the deterministic CREATE-then-UPDATE ordering,
/// so one approval covers that whole plan and nothing else.
struct BatchPlan {
    let phases: [ConfirmationPlan]
    let credentialFingerprint: String
    let bindingDigest: String
    let expectedConfirmation: String

    var totalItemCount: Int { phases.reduce(0) { $0 + $1.items.count } }

    func plan(for group: OperationGroup) -> ConfirmationPlan? {
        phases.first { $0.group == group }
    }
}

/// The armed, comparable form of a `BatchPlan`.
///
/// Each phase carries its own operation-group binding digest verbatim. A later
/// phase is admitted only when a fresh authenticated read reproduces that exact
/// digest — never by inheriting the earlier phase's approval, and never by
/// re-deriving authority from whatever the server happens to say later.
struct BatchPlanApproval: Equatable, Sendable {
    struct Phase: Equatable, Sendable {
        let group: OperationGroup
        let itemCount: Int
        let batchDigest: String
        let bindingDigest: String
    }

    let snapshotIdentity: String
    let credentialFingerprint: String
    let phases: [Phase]
    let bindingDigest: String

    func phase(for group: OperationGroup) -> Phase? {
        phases.first { $0.group == group }
    }
}

enum ConfirmationBinding {
    /// Binds the Preview to the exact status it will write.
    ///
    /// `status` defaults to the legacy shared constant so every pre-#161 caller
    /// keeps identical behavior and identical digests. An out-of-allowlist value
    /// fails closed here, before it can reach a digest or a request body.
    static func makePreviewBindingContext(
        items: [PrivatePreflightItem],
        tags: [String],
        status: String = CompanionConstants.status
    ) throws -> PreviewBindingContext {
        guard try WriteTagPreference.canonicalized(tags) == tags,
              InterpretationPublicationStatus.isDocumentedWriteStatus(status)
        else {
            throw CompanionError.inputRejected
        }
        let createItems = try confirmationItems(items, group: .create)
        let updateItems = try confirmationItems(items, group: .update)
        return PreviewBindingContext(
            host: CompanionConstants.productionBaseURL.absoluteString,
            createPath: reviewedBindingPath(.create),
            updatePath: reviewedBindingPath(.update),
            tags: tags,
            status: status,
            createBatchDigest: createItems.isEmpty
                ? nil
                : try makeBatchDigest(
                    items: createItems, group: .create, tags: tags, status: status
                ),
            updateBatchDigest: updateItems.isEmpty
                ? nil
                : try makeBatchDigest(
                    items: updateItems, group: .update, tags: tags, status: status
                )
        )
    }

    static func sourceIdentity(_ entries: [BatchEntry]) throws -> String {
        return try digest([
            "items": entries.map {
                [
                    "ordinal": $0.ordinal,
                    "spelling": $0.spelling,
                    "interpretation": $0.interpretation,
                ] as [String: Any]
            },
        ])
    }

    static func snapshotIdentity(_ snapshot: PreviewSnapshot) throws -> String {
        var context: [String: Any] = [
            "host": snapshot.bindingContext.host,
            "create_path": snapshot.bindingContext.createPath,
            "update_path": snapshot.bindingContext.updatePath,
            "tags": snapshot.bindingContext.tags,
            "status": snapshot.bindingContext.status,
        ]
        context["create_batch_digest"] = snapshot.bindingContext.createBatchDigest ?? NSNull()
        context["update_batch_digest"] = snapshot.bindingContext.updateBatchDigest ?? NSNull()
        return try digest([
            "source_identity": snapshot.sourceIdentity,
            "credential_fingerprint": snapshot.credentialFingerprint,
            "account_mode": snapshot.accountMode,
            "binding_context": context,
            "counts": [
                "create": snapshot.presentation.counts.create,
                "update": snapshot.presentation.counts.update,
                "already_matching": snapshot.presentation.counts.alreadyMatching,
                "blocked": snapshot.presentation.counts.blocked,
            ],
            "items": snapshot.items.map { item in
                var value: [String: Any] = [
                    "ordinal": item.entry.ordinal,
                    "spelling": item.entry.spelling,
                    "interpretation": item.entry.interpretation,
                    "classification": item.classification.rawValue,
                    "vocabulary_id": item.vocabularyID as Any,
                    "reason": item.reason as Any,
                ]
                if let baseline = item.baseline {
                    value["baseline"] = [
                        "record_id": baseline.id,
                        "interpretation": baseline.interpretation,
                        "tags": baseline.tags,
                        "status": baseline.status,
                    ]
                } else {
                    value["baseline"] = NSNull()
                }
                if item.vocabularyID == nil { value["vocabulary_id"] = NSNull() }
                if item.reason == nil { value["reason"] = NSNull() }
                return value
            },
        ])
    }

    static func makePlan(snapshot: PreviewSnapshot, group: OperationGroup) throws -> ConfirmationPlan {
        let items = try confirmationItems(snapshot.items, group: group)
        guard !items.isEmpty else { throw CompanionError.blocked }
        let intendedTags = snapshot.bindingContext.tags
        let intendedStatus = snapshot.bindingContext.status
        guard try WriteTagPreference.canonicalized(intendedTags) == intendedTags else {
            throw CompanionError.stalePreview
        }
        let batchDigest = try makeBatchDigest(
            items: items,
            group: group,
            tags: intendedTags,
            status: intendedStatus
        )
        let expectedStoredDigest = group == .create
            ? snapshot.bindingContext.createBatchDigest
            : snapshot.bindingContext.updateBatchDigest
        guard snapshot.bindingContext.host == CompanionConstants.productionBaseURL.absoluteString,
              snapshot.bindingContext.createPath == reviewedBindingPath(.create),
              snapshot.bindingContext.updatePath == reviewedBindingPath(.update),
              // #161 relaxes this pin to an explicit documented allowlist and
              // nothing wider: an unknown or undocumented status still fails
              // closed here, before any digest, body or POST exists.
              InterpretationPublicationStatus.isDocumentedWriteStatus(intendedStatus),
              expectedStoredDigest == batchDigest
        else {
            throw CompanionError.stalePreview
        }
        var boundFields: [String: Any] = [
            "operation": operationName(group),
            "mode": group.rawValue,
            "host": CompanionConstants.productionBaseURL.absoluteString,
            "method": "POST",
            "path": reviewedBindingPath(group),
            "tags": intendedTags,
            "status": intendedStatus,
            "item_count": items.count,
            "batch_digest": batchDigest,
            "credential_fingerprint": snapshot.credentialFingerprint,
            "items": items.map {
                boundItem($0, tags: intendedTags, status: intendedStatus)
            },
        ]
        if group == .update { boundFields["no_op_count"] = 0 }

        var binding = boundFields
        binding["account_label"] = CompanionConstants.accountLabel
        binding["vocabulary_ids"] = items.map(\.vocabularyID)
        binding["request_bodies"] = items.map {
            requestBody($0, group: group, tags: intendedTags, status: intendedStatus)
        }
        binding["write_policy"] = CompanionConstants.writePolicy
        binding["pricing_and_terms_checked"] = true
        binding["account_mode"] = CompanionConstants.accountMode
        if group == .update {
            binding["record_ids"] = items.compactMap { $0.baseline?.id }
            binding["write_paths"] = items.compactMap {
                $0.baseline.map { "/open/api/v1/interpretations/\($0.id)" }
            }
        }

        let bindingDigest = String(try digest(binding).prefix(16))
        let prefix = group == .create ? "CONFIRM MAIN CREATE" : "CONFIRM MAIN UPDATE"
        return ConfirmationPlan(
            group: group,
            credentialFingerprint: snapshot.credentialFingerprint,
            tags: intendedTags,
            status: intendedStatus,
            items: items,
            batchDigest: batchDigest,
            bindingDigest: bindingDigest,
            expectedConfirmation: "\(prefix) \(bindingDigest)"
        )
    }

    static func makeApproval(snapshot: PreviewSnapshot, group: OperationGroup) throws -> NativeApproval {
        let plan = try makePlan(snapshot: snapshot, group: group)
        return NativeApproval(
            group: group,
            snapshotIdentity: try snapshotIdentity(snapshot),
            bindingDigest: plan.bindingDigest
        )
    }

    /// Deterministic phase ordering for a whole-plan run: CREATE first, then
    /// UPDATE. Only groups with at least one actionable item take part.
    static let batchPhaseOrder: [OperationGroup] = [.create, .update]

    static func makeBatchPlan(snapshot: PreviewSnapshot) throws -> BatchPlan {
        let phases = try batchPhaseOrder
            .filter { !snapshot.items(for: $0).isEmpty }
            .map { try makePlan(snapshot: snapshot, group: $0) }
        guard !phases.isEmpty else { throw CompanionError.blocked }

        let binding: [String: Any] = [
            "operation": "batch-interpretation-run",
            "host": CompanionConstants.productionBaseURL.absoluteString,
            "method": "POST",
            "account_label": CompanionConstants.accountLabel,
            "account_mode": CompanionConstants.accountMode,
            "write_policy": CompanionConstants.writePolicy,
            "pricing_and_terms_checked": true,
            "tags": snapshot.bindingContext.tags,
            "status": snapshot.bindingContext.status,
            "credential_fingerprint": snapshot.credentialFingerprint,
            // Commits the approval to the exact Preview the Owner was shown,
            // including its counts, classifications and baselines.
            "snapshot_identity": try snapshotIdentity(snapshot),
            "total_item_count": phases.reduce(0) { $0 + $1.items.count },
            "phase_order": phases.map { $0.group.rawValue },
            "phases": phases.map { plan -> [String: Any] in
                [
                    "group": plan.group.rawValue,
                    "operation": operationName(plan.group),
                    "path": reviewedBindingPath(plan.group),
                    "item_count": plan.items.count,
                    "batch_digest": plan.batchDigest,
                    // The per-group binding digest, verbatim. A later phase is
                    // admitted only by reproducing exactly this value.
                    "binding_digest": plan.bindingDigest,
                    "items": plan.items.map {
                        boundItem($0, tags: plan.tags, status: plan.status)
                    },
                    "request_bodies": plan.items.map {
                        requestBody(
                            $0, group: plan.group, tags: plan.tags, status: plan.status
                        )
                    },
                    "vocabulary_ids": plan.items.map(\.vocabularyID),
                    "record_ids": plan.items.compactMap { $0.baseline?.id },
                ] as [String: Any]
            },
        ]

        let bindingDigest = String(try digest(binding).prefix(16))
        return BatchPlan(
            phases: phases,
            credentialFingerprint: snapshot.credentialFingerprint,
            bindingDigest: bindingDigest,
            expectedConfirmation: "CONFIRM MAIN BATCH \(bindingDigest)"
        )
    }

    static func makeBatchApproval(snapshot: PreviewSnapshot) throws -> BatchPlanApproval {
        let plan = try makeBatchPlan(snapshot: snapshot)
        return BatchPlanApproval(
            snapshotIdentity: try snapshotIdentity(snapshot),
            credentialFingerprint: snapshot.credentialFingerprint,
            phases: plan.phases.map {
                BatchPlanApproval.Phase(
                    group: $0.group,
                    itemCount: $0.items.count,
                    batchDigest: $0.batchDigest,
                    bindingDigest: $0.bindingDigest
                )
            },
            bindingDigest: plan.bindingDigest
        )
    }

    static func requestBody(
        _ item: ConfirmationPlan.Item,
        group: OperationGroup,
        tags: [String],
        status: String = CompanionConstants.status
    ) -> [String: Any] {
        var interpretation: [String: Any] = [
            "interpretation": item.interpretation,
            "tags": tags,
            "status": status,
        ]
        if group == .create { interpretation["voc_id"] = item.vocabularyID }
        return ["interpretation": interpretation]
    }

    static func requestData(
        _ item: ConfirmationPlan.Item,
        group: OperationGroup,
        tags: [String],
        status: String = CompanionConstants.status
    ) throws -> Data {
        try canonicalData(
            requestBody(item, group: group, tags: tags, status: status)
        )
    }

    static func digest(_ value: Any) throws -> String {
        let data = try canonicalData(value)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonicalData(_ value: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(value) else {
            throw CompanionError.responseRejected
        }
        return try JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private static func makeBatchDigest(
        items: [ConfirmationPlan.Item],
        group: OperationGroup,
        tags: [String],
        status: String = CompanionConstants.status
    ) throws -> String {
        try digest([
            "operation": operationName(group),
            "host": CompanionConstants.productionBaseURL.absoluteString,
            "method": "POST",
            "path": reviewedBindingPath(group),
            "tags": tags,
            "status": status,
            "item_count": items.count,
            "items": items.map {
                [
                    "ordinal": $0.ordinal,
                    "spelling": $0.spelling,
                    "interpretation": $0.interpretation,
                ] as [String: Any]
            },
        ])
    }

    private static func confirmationItems(
        _ sourceItems: [PrivatePreflightItem],
        group: OperationGroup
    ) throws -> [ConfirmationPlan.Item] {
        let desired: PreviewClassification = group == .create ? .create : .update
        return try sourceItems.filter { $0.classification == desired }
            .enumerated()
            .map { index, source in
                guard let vocabularyID = source.vocabularyID else {
                    throw CompanionError.blocked
                }
                if group == .update, source.baseline == nil { throw CompanionError.blocked }
                if group == .create, source.baseline != nil { throw CompanionError.blocked }
                return ConfirmationPlan.Item(
                    ordinal: index + 1,
                    spelling: source.entry.spelling,
                    interpretation: source.entry.interpretation,
                    vocabularyID: vocabularyID,
                    baseline: source.baseline
                )
            }
    }

    private static func boundItem(
        _ item: ConfirmationPlan.Item,
        tags: [String],
        status: String = CompanionConstants.status
    ) -> [String: Any] {
        var value: [String: Any] = [
            "ordinal": item.ordinal,
            "spelling": item.spelling,
            "interpretation": item.interpretation,
            "tags": tags,
            "status": status,
            "voc_id_fingerprint": item.vocabularyFingerprint,
        ]
        if let baseline = item.baseline, let fingerprint = item.recordFingerprint {
            value["pre_update"] = [
                "interpretation": baseline.interpretation,
                "tags": baseline.tags,
                "status": baseline.status,
                "record_fingerprint": fingerprint,
            ]
        }
        return value
    }

    private static func operationName(_ group: OperationGroup) -> String {
        group == .create ? "batch-interpretation-create" : "batch-interpretation-update"
    }

    private static func reviewedBindingPath(_ group: OperationGroup) -> String {
        group == .create
            ? "/open/api/v1/interpretations"
            : "/open/api/v1/interpretations/{record_id}"
    }
}
