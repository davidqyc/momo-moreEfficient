import CryptoKit
import Foundation

enum PhrasePreviewClassification: String, Equatable, Sendable {
    case create = "CREATE"
    case alreadyMatching = "ALREADY_MATCHING"
    case blocked = "BLOCKED"
}

extension PhrasePreviewClassification {
    var compactLabel: String {
        switch self {
        case .create: return "新建"
        case .alreadyMatching: return "一致"
        case .blocked: return "阻断"
        }
    }
}

struct PhraseRange: Equatable, Sendable {
    let start: Int
    let end: Int
}

enum PhraseHighlightShape: String, Equatable, Sendable {
    case integerPairArray = "integer-pair-array"
    case objectRangeArray = "object-range-array"
    case emptyArray = "empty-array"
}

enum PhraseHighlight: Equatable, Sendable {
    case missing
    case ranges(shape: PhraseHighlightShape, values: [PhraseRange])
}

/// Closed observations only. No raw response value can escape through this type.
enum PhraseObservation: String, Equatable, Sendable {
    case tagsMatchRequested = "tags-match-requested"
    case tagsMissing = "tags-missing"
    case tagsDiffer = "tags-differ"
    case highlightExactTarget = "highlight-exact-target"
    case highlightMissing = "highlight-missing"
    case highlightEmpty = "highlight-empty"
    case highlightOtherReviewedRange = "highlight-other-reviewed-range"
    case chineseRangeUnavailable = "chinese-range-unavailable"
}

struct PhraseRecord: Equatable, Sendable {
    let id: String
    let phrase: String
    let interpretation: String
    let tags: [String]?
    let origin: String
    let status: String
    let highlight: PhraseHighlight

    func hardMatches(_ entry: PhraseBatchEntry) -> Bool {
        phrase == entry.english
            && interpretation == entry.chinese
            && origin == entry.source
            && status == CompanionConstants.status
    }

    func observations(for entry: PhraseBatchEntry) -> [PhraseObservation] {
        let tagObservation: PhraseObservation
        if let tags {
            tagObservation = tags.count == CompanionConstants.tags.count
                && Set(tags).count == CompanionConstants.tags.count
                && Set(tags) == Set(CompanionConstants.tags)
                ? .tagsMatchRequested
                : .tagsDiffer
        } else {
            tagObservation = .tagsMissing
        }

        let highlightObservation: PhraseObservation
        switch highlight {
        case .missing:
            highlightObservation = .highlightMissing
        case let .ranges(_, values) where values.isEmpty:
            highlightObservation = .highlightEmpty
        case let .ranges(_, values):
            let intended = Self.uniqueExactTargetRange(
                phrase: entry.english,
                spelling: entry.spelling
            )
            highlightObservation = intended.map { values == [$0] } == true
                ? .highlightExactTarget
                : .highlightOtherReviewedRange
        }
        return [tagObservation, highlightObservation, .chineseRangeUnavailable]
    }

    private static func uniqueExactTargetRange(
        phrase: String,
        spelling: String
    ) -> PhraseRange? {
        let phraseScalars = Array(phrase.unicodeScalars)
        let spellingScalars = Array(spelling.unicodeScalars)
        guard !spellingScalars.isEmpty, spellingScalars.count <= phraseScalars.count else {
            return nil
        }
        var matches: [PhraseRange] = []
        for start in 0...(phraseScalars.count - spellingScalars.count) {
            let end = start + spellingScalars.count
            if Array(phraseScalars[start..<end]) == spellingScalars {
                matches.append(PhraseRange(start: start, end: end))
            }
        }
        return matches.count == 1 ? matches[0] : nil
    }
}

struct PhrasePreflightItem: Equatable, Sendable {
    let entry: PhraseBatchEntry
    let classification: PhrasePreviewClassification
    let vocabularyID: String?
    /// Only same-English records are retained. Unrelated phrases are deliberately
    /// excluded from the approval baseline because they cannot affect CREATE.
    let sameEnglishBaseline: [PhraseRecord]
    let reason: String?

    var observations: [PhraseObservation] {
        guard classification == .alreadyMatching, sameEnglishBaseline.count == 1 else {
            return []
        }
        return sameEnglishBaseline[0].observations(for: entry)
    }
}

struct PhrasePreviewRow: Equatable, Identifiable, Sendable {
    let ordinal: Int
    let spelling: String
    let classification: PhrasePreviewClassification
    let english: String
    let chinese: String
    let source: String
    let blockedReason: String?
    let observations: [PhraseObservation]

    var id: Int { ordinal }
    var canExpand: Bool { true }
}

struct PhrasePreviewPresentation: Equatable, Sendable {
    let rows: [PhrasePreviewRow]
    let createCount: Int
    let alreadyMatchingCount: Int
    let blockedCount: Int
}

struct PhrasePreviewBindingContext: Equatable, Sendable {
    let host: String
    let vocabularyPath: String
    let collectionPath: String
    let createPath: String
    let tags: [String]
    let expectedStatus: String
    let createBatchDigest: String?
}

struct PhrasePreviewSnapshot: Equatable, Sendable {
    let sourceIdentity: String
    let credentialFingerprint: String
    let accountMode: String
    let bindingContext: PhrasePreviewBindingContext
    let items: [PhrasePreflightItem]

    var createCount: Int { items.filter { $0.classification == .create }.count }
    var alreadyMatchingCount: Int {
        items.filter { $0.classification == .alreadyMatching }.count
    }
    var blockedCount: Int { items.filter { $0.classification == .blocked }.count }

    var presentation: PhrasePreviewPresentation {
        PhrasePreviewPresentation(
            rows: items.map { item in
                PhrasePreviewRow(
                    ordinal: item.entry.ordinal,
                    spelling: item.entry.spelling,
                    classification: item.classification,
                    english: item.entry.english,
                    chinese: item.entry.chinese,
                    source: item.entry.source,
                    blockedReason: Self.safeBlockedReason(item.reason),
                    observations: item.observations
                )
            },
            createCount: createCount,
            alreadyMatchingCount: alreadyMatchingCount,
            blockedCount: blockedCount
        )
    }

    private static func safeBlockedReason(_ reason: String?) -> String? {
        switch reason {
        case "CONFLICTING_SAME_ENGLISH":
            return "相同英文已存在，但中文或来源不一致"
        case "AMBIGUOUS_SAME_ENGLISH":
            return "存在多条相同英文例句，无法安全判断"
        case "READ_FAILED":
            return "无法安全读取例句状态"
        default:
            return nil
        }
    }
}

struct PhraseConfirmationPlan {
    struct Item {
        let entry: PhraseBatchEntry
        let vocabularyID: String

        var vocabularyFingerprint: String {
            SHA256.hash(data: Data(vocabularyID.utf8)).hexPrefix(16)
        }
    }

    let credentialFingerprint: String
    let items: [Item]
    let batchDigest: String
    let bindingDigest: String
    let expectedConfirmation: String
}

struct PhraseCreateApproval: Equatable, Sendable {
    let snapshotIdentity: String
    let bindingDigest: String
}

struct PhraseItemExecutionResult: Equatable, Sendable {
    let spelling: String
    let outcome: WriteOutcome
    let observations: [PhraseObservation]
}

struct PhraseExecutionSummary: Equatable, Sendable {
    let succeeded: Int
    let failed: Int
    let cancelled: Bool
    let stalePreview: Bool
    let results: [PhraseItemExecutionResult]

    static let stale = PhraseExecutionSummary(
        succeeded: 0,
        failed: 0,
        cancelled: false,
        stalePreview: true,
        results: []
    )

    var isFullSuccess: Bool {
        !stalePreview
            && !cancelled
            && failed == 0
            && !results.isEmpty
            && succeeded == results.count
            && results.allSatisfy { $0.outcome == .confirmed || $0.outcome == .recovered }
    }
}

struct PhrasePreflightPlanner {
    let api: MaimemoTransport

    func buildSnapshot(
        entries: [PhraseBatchEntry],
        credentialFingerprint: String,
        control: ExecutionControl? = nil,
        onEntryStarted: (@Sendable (_ entry: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PhrasePreviewSnapshot {
        guard !entries.isEmpty, entries.count <= CompanionConstants.maxBatchItems else {
            throw CompanionError.inputRejected
        }

        var planned: [PhrasePreflightItem] = []
        for entry in entries {
            onEntryStarted?(entry.ordinal, entries.count)
            do {
                let vocabulary = try await api.vocabulary(
                    spelling: entry.spelling,
                    control: control
                )
                let records = try await api.phrases(
                    vocabularyID: vocabulary.id,
                    control: control
                )
                let sameEnglish = records.filter { $0.phrase == entry.english }
                if sameEnglish.isEmpty {
                    planned.append(
                        PhrasePreflightItem(
                            entry: entry,
                            classification: .create,
                            vocabularyID: vocabulary.id,
                            sameEnglishBaseline: [],
                            reason: nil
                        )
                    )
                } else if sameEnglish.count == 1, sameEnglish[0].hardMatches(entry) {
                    planned.append(
                        PhrasePreflightItem(
                            entry: entry,
                            classification: .alreadyMatching,
                            vocabularyID: vocabulary.id,
                            sameEnglishBaseline: sameEnglish,
                            reason: nil
                        )
                    )
                } else {
                    planned.append(
                        PhrasePreflightItem(
                            entry: entry,
                            classification: .blocked,
                            vocabularyID: vocabulary.id,
                            sameEnglishBaseline: sameEnglish,
                            reason: sameEnglish.count == 1
                                ? "CONFLICTING_SAME_ENGLISH"
                                : "AMBIGUOUS_SAME_ENGLISH"
                        )
                    )
                }
            } catch CompanionError.cancelled {
                throw CompanionError.cancelled
            } catch {
                planned.append(
                    PhrasePreflightItem(
                        entry: entry,
                        classification: .blocked,
                        vocabularyID: nil,
                        sameEnglishBaseline: [],
                        reason: "READ_FAILED"
                    )
                )
            }
        }

        return PhrasePreviewSnapshot(
            sourceIdentity: try PhraseCreateBinding.sourceIdentity(entries),
            credentialFingerprint: credentialFingerprint,
            accountMode: CompanionConstants.accountMode,
            bindingContext: try PhraseCreateBinding.makePreviewBindingContext(items: planned),
            items: planned
        )
    }
}

enum PhraseCreateBinding {
    static let vocabularyPath = "/open/api/v1/vocabulary"
    static let collectionPath = "/open/api/v1/phrases"
    static let createPath = "/open/api/v1/phrases"

    static func sourceIdentity(_ entries: [PhraseBatchEntry]) throws -> String {
        try ConfirmationBinding.digest([
            "items": entries.map { entry in
                [
                    "ordinal": entry.ordinal,
                    "spelling": entry.spelling,
                    "english": entry.english,
                    "chinese": entry.chinese,
                    "source": entry.source,
                ] as [String: Any]
            },
        ])
    }

    static func makePreviewBindingContext(
        items: [PhrasePreflightItem]
    ) throws -> PhrasePreviewBindingContext {
        let createItems = try confirmationItems(items)
        return PhrasePreviewBindingContext(
            host: CompanionConstants.productionBaseURL.absoluteString,
            vocabularyPath: vocabularyPath,
            collectionPath: collectionPath,
            createPath: createPath,
            tags: CompanionConstants.tags,
            expectedStatus: CompanionConstants.status,
            createBatchDigest: createItems.isEmpty ? nil : try batchDigest(createItems)
        )
    }

    static func snapshotIdentity(_ snapshot: PhrasePreviewSnapshot) throws -> String {
        try ConfirmationBinding.digest([
            "source_identity": snapshot.sourceIdentity,
            "credential_fingerprint": snapshot.credentialFingerprint,
            "account_mode": snapshot.accountMode,
            "binding_context": [
                "host": snapshot.bindingContext.host,
                "vocabulary_path": snapshot.bindingContext.vocabularyPath,
                "collection_path": snapshot.bindingContext.collectionPath,
                "create_path": snapshot.bindingContext.createPath,
                "tags": snapshot.bindingContext.tags,
                "expected_status": snapshot.bindingContext.expectedStatus,
                "create_batch_digest": optionalJSON(
                    snapshot.bindingContext.createBatchDigest
                ),
            ] as [String: Any],
            "items": snapshot.items.map { item in
                [
                    "ordinal": item.entry.ordinal,
                    "spelling": item.entry.spelling,
                    "english": item.entry.english,
                    "chinese": item.entry.chinese,
                    "source": item.entry.source,
                    "classification": item.classification.rawValue,
                    "vocabulary_id": optionalJSON(item.vocabularyID),
                    "reason": optionalJSON(item.reason),
                    // Tags/highlight are intentionally excluded. They are
                    // observations, not CREATE admission fields.
                    "same_english_baseline": item.sameEnglishBaseline.map { record in
                        [
                            "id": record.id,
                            "phrase": record.phrase,
                            "interpretation": record.interpretation,
                            "origin": record.origin,
                            "status": record.status,
                        ] as [String: Any]
                    },
                ] as [String: Any]
            },
        ])
    }

    static func makePlan(snapshot: PhrasePreviewSnapshot) throws -> PhraseConfirmationPlan {
        guard snapshot.items.allSatisfy({ $0.classification != .blocked }) else {
            throw CompanionError.blocked
        }
        let items = try confirmationItems(snapshot.items)
        guard !items.isEmpty else { throw CompanionError.blocked }
        let digest = try batchDigest(items)
        let context = snapshot.bindingContext
        guard context.host == CompanionConstants.productionBaseURL.absoluteString,
              context.vocabularyPath == vocabularyPath,
              context.collectionPath == collectionPath,
              context.createPath == createPath,
              context.tags == CompanionConstants.tags,
              context.expectedStatus == CompanionConstants.status,
              context.createBatchDigest == digest,
              snapshot.accountMode == CompanionConstants.accountMode
        else {
            throw CompanionError.stalePreview
        }

        let binding: [String: Any] = [
            "operation": "batch-phrase-create",
            "host": context.host,
            "method": "POST",
            "vocabulary_path": context.vocabularyPath,
            "collection_path": context.collectionPath,
            "create_path": context.createPath,
            "account_mode": snapshot.accountMode,
            "account_label": CompanionConstants.accountLabel,
            "credential_fingerprint": snapshot.credentialFingerprint,
            "tags": context.tags,
            "expected_status": context.expectedStatus,
            "write_policy": CompanionConstants.writePolicy,
            "snapshot_identity": try snapshotIdentity(snapshot),
            "batch_digest": digest,
            "item_count": items.count,
            "items": items.map { item in
                [
                    "ordinal": item.entry.ordinal,
                    "spelling": item.entry.spelling,
                    "english": item.entry.english,
                    "chinese": item.entry.chinese,
                    "source": item.entry.source,
                    "voc_id_fingerprint": item.vocabularyFingerprint,
                ] as [String: Any]
            },
            "request_bodies": items.map(requestBody),
        ]
        let bindingDigest = String(try ConfirmationBinding.digest(binding).prefix(16))
        return PhraseConfirmationPlan(
            credentialFingerprint: snapshot.credentialFingerprint,
            items: items,
            batchDigest: digest,
            bindingDigest: bindingDigest,
            expectedConfirmation: "CONFIRM MAIN PHRASE CREATE \(bindingDigest)"
        )
    }

    static func makeApproval(snapshot: PhrasePreviewSnapshot) throws -> PhraseCreateApproval {
        let plan = try makePlan(snapshot: snapshot)
        return PhraseCreateApproval(
            snapshotIdentity: try snapshotIdentity(snapshot),
            bindingDigest: plan.bindingDigest
        )
    }

    static func requestBody(_ item: PhraseConfirmationPlan.Item) -> [String: Any] {
        [
            "phrase": [
                "voc_id": item.vocabularyID,
                "phrase": item.entry.english,
                "interpretation": item.entry.chinese,
                "tags": CompanionConstants.tags,
                "origin": item.entry.source,
            ],
        ]
    }

    static func requestData(_ item: PhraseConfirmationPlan.Item) throws -> Data {
        try ConfirmationBinding.canonicalData(requestBody(item))
    }

    private static func confirmationItems(
        _ source: [PhrasePreflightItem]
    ) throws -> [PhraseConfirmationPlan.Item] {
        try source.filter { $0.classification == .create }.map { item in
            guard let vocabularyID = item.vocabularyID,
                  item.sameEnglishBaseline.isEmpty
            else {
                throw CompanionError.blocked
            }
            return PhraseConfirmationPlan.Item(entry: item.entry, vocabularyID: vocabularyID)
        }
    }

    private static func batchDigest(_ items: [PhraseConfirmationPlan.Item]) throws -> String {
        try ConfirmationBinding.digest([
            "operation": "batch-phrase-create",
            "host": CompanionConstants.productionBaseURL.absoluteString,
            "method": "POST",
            "vocabulary_path": vocabularyPath,
            "collection_path": collectionPath,
            "create_path": createPath,
            "tags": CompanionConstants.tags,
            "expected_status": CompanionConstants.status,
            "item_count": items.count,
            "items": items.map { item in
                [
                    "ordinal": item.entry.ordinal,
                    "spelling": item.entry.spelling,
                    "english": item.entry.english,
                    "chinese": item.entry.chinese,
                    "source": item.entry.source,
                ] as [String: Any]
            },
        ])
    }

    private static func optionalJSON(_ value: String?) -> Any {
        value.map { $0 as Any } ?? NSNull()
    }
}

struct PhraseWriteExecutor {
    let api: MaimemoTransport

    func execute(
        displayedSnapshot: PhrasePreviewSnapshot,
        approval: PhraseCreateApproval,
        control: ExecutionControl,
        progress: ExecutionProgressReporter? = nil
    ) async -> PhraseExecutionSummary {
        do {
            guard approval == (try PhraseCreateBinding.makeApproval(snapshot: displayedSnapshot))
            else {
                return .stale
            }

            progress?.report(.securing)
            let fresh = try await PhrasePreflightPlanner(api: api).buildSnapshot(
                entries: displayedSnapshot.items.map(\.entry),
                credentialFingerprint: displayedSnapshot.credentialFingerprint,
                control: control
            )
            guard try PhraseCreateBinding.snapshotIdentity(fresh) == approval.snapshotIdentity else {
                return .stale
            }
            let plan = try PhraseCreateBinding.makePlan(snapshot: fresh)
            guard plan.bindingDigest == approval.bindingDigest else { return .stale }
            return await perform(plan: plan, control: control, progress: progress)
        } catch CompanionError.cancelled {
            return PhraseExecutionSummary(
                succeeded: 0,
                failed: 0,
                cancelled: true,
                stalePreview: false,
                results: []
            )
        } catch {
            return .stale
        }
    }

    private func perform(
        plan: PhraseConfirmationPlan,
        control: ExecutionControl,
        progress: ExecutionProgressReporter?
    ) async -> PhraseExecutionSummary {
        var results: [PhraseItemExecutionResult] = []
        var succeeded = 0
        var failed = 0

        defer { progress?.report(.finishing(group: .create)) }

        for (index, item) in plan.items.enumerated() {
            if control.isCancellationRequested {
                results.append(
                    PhraseItemExecutionResult(
                        spelling: item.entry.spelling,
                        outcome: .notAttempted,
                        observations: []
                    )
                )
                break
            }

            progress?.report(
                .writing(
                    group: .create,
                    item: index + 1,
                    total: plan.items.count,
                    spelling: item.entry.spelling
                )
            )

            do {
                let body = try PhraseCreateBinding.requestData(item)
                let dispatch = await api.post(route: .createPhrase, body: body, control: control)
                guard dispatch != .notDispatched else {
                    results.append(
                        PhraseItemExecutionResult(
                            spelling: item.entry.spelling,
                            outcome: .notAttempted,
                            observations: []
                        )
                    )
                    break
                }

                let records: [PhraseRecord]
                do {
                    records = try await api.phrases(
                        vocabularyID: item.vocabularyID,
                        control: control,
                        readback: true
                    )
                } catch {
                    control.finishPostResolution()
                    failed += 1
                    results.append(
                        PhraseItemExecutionResult(
                            spelling: item.entry.spelling,
                            outcome: .notVerified,
                            observations: []
                        )
                    )
                    break
                }
                control.finishPostResolution()

                let sameEnglish = records.filter { $0.phrase == item.entry.english }
                guard sameEnglish.count == 1, sameEnglish[0].hardMatches(item.entry) else {
                    failed += 1
                    results.append(
                        PhraseItemExecutionResult(
                            spelling: item.entry.spelling,
                            outcome: .notVerified,
                            observations: []
                        )
                    )
                    break
                }

                succeeded += 1
                results.append(
                    PhraseItemExecutionResult(
                        spelling: item.entry.spelling,
                        outcome: dispatch == .clean ? .confirmed : .recovered,
                        observations: sameEnglish[0].observations(for: item.entry)
                    )
                )
            } catch {
                if control.allowsInFlightReadback() { control.finishPostResolution() }
                failed += 1
                results.append(
                    PhraseItemExecutionResult(
                        spelling: item.entry.spelling,
                        outcome: .notVerified,
                        observations: []
                    )
                )
                break
            }
        }

        return PhraseExecutionSummary(
            succeeded: succeeded,
            failed: failed,
            cancelled: control.isCancellationRequested,
            stalePreview: false,
            results: results
        )
    }
}
