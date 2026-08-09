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

enum ConfirmationBinding {
    static func makePreviewBindingContext(
        items: [PrivatePreflightItem]
    ) throws -> PreviewBindingContext {
        let createItems = try confirmationItems(items, group: .create)
        let updateItems = try confirmationItems(items, group: .update)
        return PreviewBindingContext(
            host: CompanionConstants.productionBaseURL.absoluteString,
            createPath: reviewedBindingPath(.create),
            updatePath: reviewedBindingPath(.update),
            tags: CompanionConstants.tags,
            status: CompanionConstants.status,
            createBatchDigest: createItems.isEmpty
                ? nil
                : try makeBatchDigest(items: createItems, group: .create),
            updateBatchDigest: updateItems.isEmpty
                ? nil
                : try makeBatchDigest(items: updateItems, group: .update)
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
        let batchDigest = try makeBatchDigest(items: items, group: group)
        let expectedStoredDigest = group == .create
            ? snapshot.bindingContext.createBatchDigest
            : snapshot.bindingContext.updateBatchDigest
        guard snapshot.bindingContext.host == CompanionConstants.productionBaseURL.absoluteString,
              snapshot.bindingContext.createPath == reviewedBindingPath(.create),
              snapshot.bindingContext.updatePath == reviewedBindingPath(.update),
              snapshot.bindingContext.tags == CompanionConstants.tags,
              snapshot.bindingContext.status == CompanionConstants.status,
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
            "tags": CompanionConstants.tags,
            "status": CompanionConstants.status,
            "item_count": items.count,
            "batch_digest": batchDigest,
            "credential_fingerprint": snapshot.credentialFingerprint,
            "items": items.map { boundItem($0) },
        ]
        if group == .update { boundFields["no_op_count"] = 0 }

        var binding = boundFields
        binding["account_label"] = CompanionConstants.accountLabel
        binding["vocabulary_ids"] = items.map(\.vocabularyID)
        binding["request_bodies"] = items.map { requestBody($0, group: group) }
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

    static func requestBody(_ item: ConfirmationPlan.Item, group: OperationGroup) -> [String: Any] {
        var interpretation: [String: Any] = [
            "interpretation": item.interpretation,
            "tags": CompanionConstants.tags,
            "status": CompanionConstants.status,
        ]
        if group == .create { interpretation["voc_id"] = item.vocabularyID }
        return ["interpretation": interpretation]
    }

    static func requestData(_ item: ConfirmationPlan.Item, group: OperationGroup) throws -> Data {
        try canonicalData(requestBody(item, group: group))
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
        group: OperationGroup
    ) throws -> String {
        try digest([
            "operation": operationName(group),
            "host": CompanionConstants.productionBaseURL.absoluteString,
            "method": "POST",
            "path": reviewedBindingPath(group),
            "tags": CompanionConstants.tags,
            "status": CompanionConstants.status,
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

    private static func boundItem(_ item: ConfirmationPlan.Item) -> [String: Any] {
        var value: [String: Any] = [
            "ordinal": item.ordinal,
            "spelling": item.spelling,
            "interpretation": item.interpretation,
            "tags": CompanionConstants.tags,
            "status": CompanionConstants.status,
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
