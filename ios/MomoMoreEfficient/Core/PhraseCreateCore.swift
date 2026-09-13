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
    case listVisibilityPending = "list-visibility-pending"
}

/// Provider-state English identity only. Approved input and request bindings
/// retain their original scalars. Only apostrophes are mapped; comparison keeps
/// Swift's pre-existing Unicode canonical equality, not compatibility folding.
enum PhraseEnglishIdentity {
    static func canonical(_ english: String) -> String {
        String(String.UnicodeScalarView(english.unicodeScalars.map {
            $0.value == 0x2019 ? Unicode.Scalar(0x0027)! : $0
        }))
    }

    static func equivalent(_ lhs: String, _ rhs: String) -> Bool {
        canonical(lhs) == canonical(rhs)
    }

    /// Old v1 receipts hashed raw English; also accept the provider's straight
    /// apostrophe form without rewriting old files or changing the schema.
    static func journalCandidates(_ english: String) -> [String] {
        let canonical = canonical(english)
        return english.unicodeScalars.elementsEqual(canonical.unicodeScalars)
            ? [english] : [english, canonical]
    }
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
        PhraseEnglishIdentity.equivalent(phrase, entry.english)
            && interpretation == entry.chinese
            && (entry.source.map { origin == $0 } ?? true)
            && status == CompanionConstants.status
    }

    func hardMismatchKeys(_ entry: PhraseBatchEntry) -> [PhraseMismatchKey] {
        var keys: [PhraseMismatchKey] = []
        if !PhraseEnglishIdentity.equivalent(phrase, entry.english) { keys.append(.english) }
        if interpretation != entry.chinese { keys.append(.chinese) }
        if let source = entry.source, origin != source { keys.append(.source) }
        if status != CompanionConstants.status { keys.append(.status) }
        return keys
    }

    func observations(for entry: PhraseBatchEntry, tags intendedTags: [String])
        -> [PhraseObservation]
    {
        let tagObservation: PhraseObservation
        if let tags {
            tagObservation = tags.count == intendedTags.count
                && Set(tags).count == intendedTags.count
                && Set(tags) == Set(intendedTags)
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

    func observations(tags: [String]) -> [PhraseObservation] {
        if reason == "CREATED_LIST_PENDING" { return [.listVisibilityPending] }
        guard classification == .alreadyMatching, sameEnglishBaseline.count == 1 else {
            return []
        }
        return sameEnglishBaseline[0].observations(for: entry, tags: tags)
    }
}

struct PhrasePreviewRow: Equatable, Identifiable, Sendable {
    let ordinal: Int
    let spelling: String
    let classification: PhrasePreviewClassification
    let english: String
    let chinese: String
    let source: String?
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
                    observations: item.observations(tags: bindingContext.tags)
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
        case "ACTIVE_CAPACITY_REACHED":
            return "已达到当前安全上限 5 条，请先在墨墨中编辑或删除一条旧例句后重新预览"
        case "ACTIVE_CAPACITY_EXCEEDED":
            return "当前例句数量超过安全上限 5 条，无法安全新建"
        case "JOURNAL_UNAVAILABLE":
            return CompanionError.phraseJournalUnavailable.description
        case "JOURNAL_PROTECTION_FAILED":
            return CompanionError.phraseJournalProtectionFailed.description
        case "DUPLICATE_PLANNED_ENGLISH":
            return "本批次包含相同英文例句，请保留一条后重新预览"
        case "READ_FAILED":
            return "无法安全读取例句状态"
        case "VOCABULARY_NOT_FOUND":
            return "当前 Open API 无法解析该词条；若为自添加词，当前暂不支持"
        case "VOCABULARY_MATCH_ANOMALY":
            return "词条目标匹配异常"
        case .none:
            return nil
        default:
            return "其他无法安全读取"
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
    let tags: [String]
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
    let diagnostic: WriteAttemptDiagnostic?

    init(
        spelling: String,
        outcome: WriteOutcome,
        observations: [PhraseObservation],
        diagnostic: WriteAttemptDiagnostic? = nil
    ) {
        self.spelling = spelling
        self.outcome = outcome
        self.observations = observations
        self.diagnostic = diagnostic
    }
}

struct PhraseExecutionSummary: Equatable, Sendable {
    let succeeded: Int
    let failed: Int
    let cancelled: Bool
    let stalePreview: Bool
    let results: [PhraseItemExecutionResult]
    let terminalError: CompanionError?

    init(
        succeeded: Int,
        failed: Int,
        cancelled: Bool,
        stalePreview: Bool,
        results: [PhraseItemExecutionResult],
        terminalError: CompanionError? = nil
    ) {
        self.succeeded = succeeded
        self.failed = failed
        self.cancelled = cancelled
        self.stalePreview = stalePreview
        self.results = results
        self.terminalError = terminalError
    }

    static let stale = PhraseExecutionSummary(
        succeeded: 0,
        failed: 0,
        cancelled: false,
        stalePreview: true,
        results: []
    )

    static func globalFailure(_ error: CompanionError) -> PhraseExecutionSummary {
        PhraseExecutionSummary(
            succeeded: 0,
            failed: 0,
            cancelled: false,
            stalePreview: false,
            results: [],
            terminalError: error
        )
    }

    var feedbackMessage: String? {
        if stalePreview { return CompanionError.stalePreview.description }
        let unconfirmed = results.contains { $0.outcome == .notVerified && $0.diagnostic?.postDispatch.wasDispatched == true }
        let unknown = "结果仍无法确认，请勿重复提交；稍后重新预览。"
        let diagnostic = results.last(where: { $0.outcome == .notVerified })?.diagnostic
        let mismatchWarning: String? = diagnostic?.phraseCreateResponse == .mismatching
            ? "创建响应与输入不一致"
                + (diagnostic?.phraseCreateMismatchFieldList.map { "（字段：\($0)）" } ?? "")
                + "；已停止后续新建。" + unknown
            : nil
        if let error = terminalError {
            if error == .phraseJournalProtectionFailed { return error.description }
            let message: String
            switch error {
            case .globalHTTPFailure: message = "墨墨拒绝了本次例句请求；已停止后续新建。"
            case .blocked: message = "已创建的例句已计入数量；已达到或超过安全上限 5 条，已停止后续新建。"
            case .responseRejected, .itemResponseRejected: message = "例句返回内容无法安全读取；已停止后续新建。"
            default: message = error.description
            }
            return unconfirmed ? message + "\n" + (mismatchWarning ?? unknown) : message
        }
        if failed > 0 {
            if let mismatchWarning { return mismatchWarning }
            let category = results.last?.diagnostic?.phraseCreateResponse
            return (category == .malformed || category == .mismatching ? "创建响应无法安全确认。" : "") + unknown
        }
        return cancelled ? CompanionError.cancelled.description : nil
    }

    var isFullSuccess: Bool {
        !stalePreview
            && !cancelled
            && failed == 0
            && terminalError == nil
            && !results.isEmpty
            && succeeded == results.count
            && results.allSatisfy { $0.outcome == .confirmed || $0.outcome == .recovered }
    }
}

struct PhrasePreflightPlanner {
    let api: MaimemoTransport
    let journal: PhraseSafetyJournal

    init(journal: PhraseSafetyJournal = .shared, api: MaimemoTransport) {
        self.api = api
        self.journal = journal
    }

    func buildSnapshot(
        entries: [PhraseBatchEntry],
        tags: [String],
        credentialFingerprint: String,
        control: ExecutionControl? = nil,
        onEntryStarted: (@Sendable (_ entry: Int, _ total: Int) -> Void)? = nil
    ) async throws -> PhrasePreviewSnapshot {
        guard !entries.isEmpty,
              credentialFingerprint == api.credentialFingerprint,
              (try? WriteTagPreference.canonicalized(tags)) == tags
        else {
            throw CompanionError.inputRejected
        }

        // The same shared batch resolver interpretation preflight uses, so both
        // modes bind write targets through one fail-closed identity contract.
        let resolution = try await VocabularyTargetResolver(api: api).resolve(
            spellings: entries.map(\.spelling),
            control: control
        )

        var planned: [PhrasePreflightItem] = []
        var reserved: [String: Int] = [:]
        var plannedEnglish: [String: Set<String>] = [:]
        for (index, entry) in entries.enumerated() {
            onEntryStarted?(entry.ordinal, entries.count)
            let outcome = resolution.outcomes[index]
            guard let vocabularyID = outcome.vocabularyID else {
                planned.append(
                    PhrasePreflightItem(
                        entry: entry,
                        classification: .blocked,
                        vocabularyID: nil,
                        sameEnglishBaseline: [],
                        reason: outcome.blockedReason
                    )
                )
                continue
            }
            do {
                let records = try await api.phrases(
                    vocabularyID: vocabularyID,
                    control: control
                )
                let active = records.filter { $0.status == CompanionConstants.status }
                let pending = try journal.pending(accountFingerprint: credentialFingerprint,
                                                  vocabularyID: vocabularyID, visible: records)
                let englishDigest = try PhraseSafetyEntry.digest("english", [PhraseEnglishIdentity.canonical(entry.english)])
                let hiddenSameEnglish = try pending.filter { try $0.matchesEnglish(entry.english) }
                let sameEnglish = active.filter { PhraseEnglishIdentity.equivalent($0.phrase, entry.english) }
                let sameEnglishCount = sameEnglish.count + hiddenSameEnglish.count
                let effectiveCount = active.count + pending.count
                let classification: PhrasePreviewClassification
                let reason: String?
                if sameEnglishCount == 1, sameEnglish.first?.hardMatches(entry) == true {
                    classification = .alreadyMatching
                    reason = nil
                } else if sameEnglishCount == 1, let hidden = hiddenSameEnglish.first, try hidden.matches(entry) {
                    classification = .alreadyMatching
                    reason = "CREATED_LIST_PENDING"
                } else if effectiveCount > 5 {
                    classification = .blocked
                    reason = "ACTIVE_CAPACITY_EXCEEDED"
                } else if sameEnglishCount > 0 {
                    classification = .blocked
                    reason = sameEnglishCount == 1 ? "CONFLICTING_SAME_ENGLISH" : "AMBIGUOUS_SAME_ENGLISH"
                } else if plannedEnglish[vocabularyID, default: []].contains(englishDigest) {
                    classification = .blocked
                    reason = "DUPLICATE_PLANNED_ENGLISH"
                } else if effectiveCount + reserved[vocabularyID, default: 0] >= 5 {
                    classification = .blocked
                    reason = "ACTIVE_CAPACITY_REACHED"
                } else {
                    classification = .create
                    reason = nil
                    reserved[vocabularyID, default: 0] += 1
                    plannedEnglish[vocabularyID, default: []].insert(englishDigest)
                }
                planned.append(PhrasePreflightItem(entry: entry, classification: classification,
                                                  vocabularyID: vocabularyID, sameEnglishBaseline: sameEnglish,
                                                  reason: reason))
            } catch let error as CompanionError where error == .phraseJournalUnavailable || error == .phraseJournalProtectionFailed {
                planned.append(PhrasePreflightItem(entry: entry, classification: .blocked,
                    vocabularyID: vocabularyID, sameEnglishBaseline: [],
                    reason: error == .phraseJournalUnavailable ? "JOURNAL_UNAVAILABLE" : "JOURNAL_PROTECTION_FAILED"))
            } catch CompanionError.cancelled {
                throw CompanionError.cancelled
            } catch let error as CompanionError where error.abortsReadPlan {
                throw error
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
            bindingContext: try PhraseCreateBinding.makePreviewBindingContext(
                items: planned,
                tags: tags
            ),
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
                    "source": optionalJSON(entry.source),
                ] as [String: Any]
            },
        ])
    }

    static func makePreviewBindingContext(
        items: [PhrasePreflightItem],
        tags: [String]
    ) throws -> PhrasePreviewBindingContext {
        guard try WriteTagPreference.canonicalized(tags) == tags else {
            throw CompanionError.inputRejected
        }
        let createItems = try confirmationItems(items)
        return PhrasePreviewBindingContext(
            host: CompanionConstants.productionBaseURL.absoluteString,
            vocabularyPath: vocabularyPath,
            collectionPath: collectionPath,
            createPath: createPath,
            tags: tags,
            expectedStatus: CompanionConstants.status,
            createBatchDigest: createItems.isEmpty
                ? nil
                : try batchDigest(createItems, tags: tags)
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
                    "source": optionalJSON(item.entry.source),
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
        let context = snapshot.bindingContext
        guard try WriteTagPreference.canonicalized(context.tags) == context.tags else {
            throw CompanionError.stalePreview
        }
        let digest = try batchDigest(items, tags: context.tags)
        guard context.host == CompanionConstants.productionBaseURL.absoluteString,
              context.vocabularyPath == vocabularyPath,
              context.collectionPath == collectionPath,
              context.createPath == createPath,
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
                    "source": optionalJSON(item.entry.source),
                    "voc_id_fingerprint": item.vocabularyFingerprint,
                ] as [String: Any]
            },
            "request_bodies": items.map { requestBody($0, tags: context.tags) },
        ]
        let bindingDigest = String(try ConfirmationBinding.digest(binding).prefix(16))
        return PhraseConfirmationPlan(
            credentialFingerprint: snapshot.credentialFingerprint,
            tags: context.tags,
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

    static func requestBody(
        _ item: PhraseConfirmationPlan.Item,
        tags: [String]
    ) -> [String: Any] {
        [
            "phrase": [
                "voc_id": item.vocabularyID,
                "phrase": item.entry.english,
                "interpretation": item.entry.chinese,
                "tags": tags,
                "origin": item.entry.source ?? "",
            ],
        ]
    }

    static func requestData(
        _ item: PhraseConfirmationPlan.Item,
        tags: [String]
    ) throws -> Data {
        try ConfirmationBinding.canonicalData(requestBody(item, tags: tags))
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

    private static func batchDigest(
        _ items: [PhraseConfirmationPlan.Item],
        tags: [String]
    ) throws -> String {
        try ConfirmationBinding.digest([
            "operation": "batch-phrase-create",
            "host": CompanionConstants.productionBaseURL.absoluteString,
            "method": "POST",
            "vocabulary_path": vocabularyPath,
            "collection_path": collectionPath,
            "create_path": createPath,
            "tags": tags,
            "expected_status": CompanionConstants.status,
            "item_count": items.count,
            "items": items.map { item in
                [
                    "ordinal": item.entry.ordinal,
                    "spelling": item.entry.spelling,
                    "english": item.entry.english,
                    "chinese": item.entry.chinese,
                    "source": optionalJSON(item.entry.source),
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
    let journal: PhraseSafetyJournal

    init(journal: PhraseSafetyJournal = .shared, api: MaimemoTransport) {
        self.api = api
        self.journal = journal
    }

    /// The first readback remains immediate. Two further paced GETs tolerate the
    /// observed short visibility lag while keeping total latency and API pressure
    /// bounded. No path through this window can dispatch another POST.
    private static let maximumReadbackAttempts = 3

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

            try journal.prepareForCreate()
            progress?.report(.securing)
            let fresh = try await PhrasePreflightPlanner(journal: journal, api: api).buildSnapshot(
                entries: displayedSnapshot.items.map(\.entry),
                tags: displayedSnapshot.bindingContext.tags,
                credentialFingerprint: displayedSnapshot.credentialFingerprint,
                control: control
            )
            if fresh.items.contains(where: { $0.reason == "JOURNAL_UNAVAILABLE" || $0.reason == "JOURNAL_PROTECTION_FAILED" }) {
                return .globalFailure(.phraseJournalUnavailable)
            }
            guard try PhraseCreateBinding.snapshotIdentity(fresh) == approval.snapshotIdentity else {
                return .stale
            }
            let plan = try PhraseCreateBinding.makePlan(snapshot: fresh)
            guard plan.bindingDigest == approval.bindingDigest else { return .stale }
            return await perform(plan: plan, control: control, progress: progress)
        } catch let error as CompanionError where error == .phraseJournalUnavailable || error == .phraseJournalProtectionFailed {
            return .globalFailure(error)
        } catch CompanionError.cancelled {
            return PhraseExecutionSummary(
                succeeded: 0,
                failed: 0,
                cancelled: true,
                stalePreview: false,
                results: []
            )
        } catch let error as CompanionError where error.abortsReadPlan {
            return .globalFailure(error)
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
        var terminalError: CompanionError?

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
                let body = try PhraseCreateBinding.requestData(item, tags: plan.tags)
                try journal.prepareForCreate()
                let create = await api.createPhrase(body: body, control: control)
                let dispatch = create.dispatch
                guard dispatch != .notDispatched else {
                    results.append(
                        PhraseItemExecutionResult(
                            spelling: item.entry.spelling,
                            outcome: .notAttempted,
                            observations: [],
                            diagnostic: WriteAttemptDiagnostic(
                                ordinal: item.entry.ordinal,
                                postDispatch: .notDispatched,
                                readbackAttempts: [],
                                terminalErrorCategory: nil
                            )
                        )
                    )
                    break
                }

                let proven = create.phrase.flatMap { $0.hardMatches(item.entry) ? $0 : nil }
                let responseCategory: PhraseCreateResponseCategory? = dispatch.isClean2xx
                    ? (proven != nil ? .proven : (create.phrase == nil ? .malformed : .mismatching)) : nil
                let responseMismatchKeys = responseCategory == .mismatching
                    ? create.phrase?.hardMismatchKeys(item.entry) : nil
                let responseEnglishScalarDiff: PhraseEnglishScalarDiff?
                if responseCategory == .mismatching,
                   responseMismatchKeys?.contains(.english) == true,
                   let returnedEnglish = create.phrase?.phrase {
                    responseEnglishScalarDiff = PhraseEnglishScalarDiff(
                        expected: item.entry.english,
                        returned: returnedEnglish
                    )
                } else {
                    responseEnglishScalarDiff = nil
                }
                var safetyError: CompanionError?
                if let proven {
                    do {
                        try journal.recordCreated(proven, accountFingerprint: plan.credentialFingerprint,
                                                  vocabularyID: item.vocabularyID, approvedEnglish: item.entry.english)
                    } catch { safetyError = .phraseJournalProtectionFailed }
                }
                // Even an unexpected journal save failure cannot skip the required
                // authenticated GET or cause another mutating POST.
                let confirmation = await confirmPhrase(item: item, control: control)
                control.finishPostResolution()
                var pendingVisibility = false
                var capacityRequiresStop = false
                if let records = confirmation.records {
                    if let proven { pendingVisibility = !records.contains { $0.id == proven.id } }
                    if safetyError == nil {
                        do {
                            let pending = try journal.pending(accountFingerprint: plan.credentialFingerprint,
                                                              vocabularyID: item.vocabularyID, visible: records)
                            let effectiveCount = records.filter { $0.status == CompanionConstants.status }.count + pending.count
                            let remainingSameVocabularyCreate = plan.items.dropFirst(index + 1).contains {
                                $0.vocabularyID == item.vocabularyID
                            }
                            // A valid fifth CREATE stays successful, but cannot be
                            // followed by another CREATE for this vocabulary.
                            capacityRequiresStop = effectiveCount > 5
                                || (effectiveCount >= 5 && remainingSameVocabularyCreate)
                        } catch { safetyError = error as? CompanionError ?? .phraseJournalUnavailable }
                    }
                }
                let matched = proven ?? confirmation.matchedRecord
                let postError = dispatch.phraseFailure
                let stopError = safetyError ?? confirmation.terminalError
                    ?? (capacityRequiresStop ? .blocked : nil)
                    ?? ((matched == nil || postError == .authenticationRejected || postError == .rateLimited) ? postError : nil)
                    ?? ((proven != nil && confirmation.attempts.last?.category != .success
                         && confirmation.attempts.last?.category != .targetNotVisible) ? .itemResponseRejected : nil)
                let diagnostic = WriteAttemptDiagnostic(
                    ordinal: item.entry.ordinal, postDispatch: dispatch.diagnosticCategory,
                    readbackAttempts: confirmation.attempts, terminalErrorCategory: stopError,
                    phraseCreateResponse: responseCategory,
                    phraseCreateMismatchKeys: responseMismatchKeys,
                    phraseEnglishScalarDiff: responseEnglishScalarDiff
                )
                if let matched {
                    succeeded += 1
                    var observations = matched.observations(for: item.entry, tags: plan.tags)
                    if pendingVisibility { observations.append(.listVisibilityPending) }
                    results.append(PhraseItemExecutionResult(spelling: item.entry.spelling,
                        outcome: dispatch.isClean2xx ? .confirmed : .recovered,
                        observations: observations, diagnostic: diagnostic))
                } else {
                    failed += 1
                    results.append(PhraseItemExecutionResult(spelling: item.entry.spelling, outcome: .notVerified,
                                                            observations: [], diagnostic: diagnostic))
                }
                terminalError = stopError
                if matched == nil || stopError != nil { break }
            } catch {
                if control.allowsInFlightReadback() { control.finishPostResolution() }
                failed += 1
                let companionError = error as? CompanionError ?? .responseRejected
                terminalError = companionError
                results.append(
                    PhraseItemExecutionResult(
                        spelling: item.entry.spelling,
                        outcome: .notVerified,
                        observations: [],
                        diagnostic: WriteAttemptDiagnostic(
                            ordinal: item.entry.ordinal,
                            postDispatch: .notDispatched,
                            readbackAttempts: [],
                            terminalErrorCategory: companionError
                        )
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
            results: results,
            terminalError: terminalError
        )
    }

    private struct ConfirmationResult {
        let matchedRecord: PhraseRecord?
        let attempts: [ReadbackAttemptDiagnostic]
        let terminalError: CompanionError?
        let records: [PhraseRecord]?
    }

    private func confirmPhrase(
        item: PhraseConfirmationPlan.Item,
        control: ExecutionControl
    ) async -> ConfirmationResult {
        var attempts: [ReadbackAttemptDiagnostic] = []
        var lastRecords: [PhraseRecord]?
        var terminalError: CompanionError?

        for attemptNumber in 1...Self.maximumReadbackAttempts {
            do {
                let records = try await api.phrases(
                    vocabularyID: item.vocabularyID,
                    control: control,
                    readback: true
                )
                terminalError = nil
                lastRecords = records
                let evaluation = evaluatePhraseReadback(records, expected: item.entry)
                attempts.append(evaluation.diagnostic)
                if let matched = evaluation.matchedRecord {
                    return ConfirmationResult(
                        matchedRecord: matched,
                        attempts: attempts,
                        terminalError: nil,
                        records: records
                    )
                }
                guard evaluation.diagnostic.category.isRetryablePhraseConfirmationFailure,
                      attemptNumber < Self.maximumReadbackAttempts
                else {
                    break
                }
            } catch {
                let companionError = error as? CompanionError ?? .responseRejected
                let category = ReadbackCategory(error: companionError)
                attempts.append(ReadbackAttemptDiagnostic(category: category))
                terminalError = companionError
                guard companionError != .cancelled,
                      category.isRetryablePhraseConfirmationFailure,
                      attemptNumber < Self.maximumReadbackAttempts
                else {
                    break
                }
            }
        }
        return ConfirmationResult(
            matchedRecord: nil,
            attempts: attempts,
            terminalError: terminalError,
            records: lastRecords
        )
    }

    private func evaluatePhraseReadback(
        _ records: [PhraseRecord],
        expected entry: PhraseBatchEntry
    ) -> (matchedRecord: PhraseRecord?, diagnostic: ReadbackAttemptDiagnostic) {
        let active = records.filter { $0.status == CompanionConstants.status }
        let sameEnglish = active.filter { PhraseEnglishIdentity.equivalent($0.phrase, entry.english) }
        var mismatchKeys: [PhraseMismatchKey] = []

        let category: ReadbackCategory
        let matched: PhraseRecord?
        if sameEnglish.count > 1 {
            category = .targetAmbiguous
            matched = nil
        } else if let candidate = sameEnglish.first {
            mismatchKeys = candidate.hardMismatchKeys(entry)
            if mismatchKeys.isEmpty {
                category = .success
                matched = candidate
            } else {
                category = .intendedStateMismatch
                matched = nil
            }
        } else {
            // A deleted same-English tombstone may be visible before the new
            // active record. Retain only the safe status mismatch fact, but keep
            // treating the target as temporarily not visible inside the window.
            let inactiveSameEnglish = records.filter { PhraseEnglishIdentity.equivalent($0.phrase, entry.english) }
            if inactiveSameEnglish.count == 1 {
                mismatchKeys = inactiveSameEnglish[0].hardMismatchKeys(entry)
            }
            category = .targetNotVisible
            matched = nil
        }

        return (
            matched,
            ReadbackAttemptDiagnostic(
                category: category,
                phraseFacts: PhraseReadbackFacts(
                    activeRecordCount: active.count,
                    sameEnglishCount: sameEnglish.count,
                    mismatchKeys: mismatchKeys
                )
            )
        )
    }

}
