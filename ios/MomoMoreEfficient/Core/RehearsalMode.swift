import Foundation

/// A deterministic, offline rehearsal of the real execution pipeline, used to
/// verify background/interruption behaviour on a physical device without creating
/// a single real write on the Owner's account.
///
/// It substitutes exactly two things: the HTTP transport and the credential store.
/// Parsing, preflight, confirmation binding, the native confirmation, the write
/// executor, readback verification, cancellation, History and every safety
/// invariant run precisely as they do in production. Nothing is bypassed.
///
/// It cannot be reached in a Release build: `isEnabled` is compiled to a constant
/// `false` and the harness itself is behind `#if DEBUG`.
enum RehearsalMode {
    static let launchArgument = "-MomoRehearsalMode"
    static let environmentKey = "MOMO_REHEARSAL_MODE"

    static var isEnabled: Bool {
        #if DEBUG
        let info = ProcessInfo.processInfo
        return info.arguments.contains(launchArgument)
            || info.environment[environmentKey] == "1"
        #else
        return false
        #endif
    }
}

extension CompanionViewModel {
    /// The app's real view model, unless a DEBUG build was explicitly launched
    /// in one of the bounded UI-test modes.
    @MainActor
    static func makeDefault() -> CompanionViewModel {
        #if DEBUG
        if RehearsalMode.isEnabled { return makeRehearsal() }
        if UITestDisconnectedMode.isEnabled { return makeUITestDisconnected() }
        #endif
        return CompanionViewModel()
    }
}

#if DEBUG

/// UI-test-only disconnected shell mode. It never reads/deletes the real
/// Keychain or real History, so ShellNavigationUITests can run deterministically
/// on the Owner's physical phone without disturbing the connected production app.
enum UITestDisconnectedMode {
    static let launchArgument = "-MomoUITestForceDisconnected"

    static var isEnabled: Bool {
        ProcessInfo.processInfo.arguments.contains(launchArgument)
    }
}

final class UITestEmptyTokenStore: TokenStore {
    func loadToken() throws -> String? { nil }
    func saveToken(_ token: String) throws {}
    func deleteToken() throws {}
}

extension CompanionViewModel {
    @MainActor
    static func makeUITestDisconnected() -> CompanionViewModel {
        CompanionViewModel(
            phraseSafetyJournal: PhraseSafetyJournal(store: RehearsalPhraseJournalStore()),
            tokenStore: UITestEmptyTokenStore(),
            historyStore: RehearsalHistoryStore(),
            transportFactory: { RehearsalTransport(perRequestDelaySeconds: 0) },
            sleeperFactory: { RehearsalSleeper() }
        )
    }
}

extension RehearsalMode {
    /// Long enough that the Owner can leave the app, take a call, and come back
    /// while the batch is still running.
    static let perRequestDelaySeconds = 2.5

    /// Obviously not a credential. Never leaves the process.
    static let placeholderToken = "REHEARSAL_ONLY_NOT_A_REAL_TOKEN"

    /// Spellings the rehearsal server pretends already have one self-authored
    /// interpretation, so a mixed CREATE/UPDATE batch can be rehearsed.
    static let seededExistingSpellings = ["manning", "certified"]

    /// The one spelling the rehearsal resolver deliberately cannot resolve,
    /// so batch Query UI coverage can prove the truthful
    /// 「当前 Open API 无法解析该词条」 inability instead of a false-green
    /// numeric 0. Normal spellings still resolve as usual.
    static let unresolvableSpelling = "ghostword"

    /// One row of the deterministic rehearsal study world (#155/#165 UI
    /// regression). Synthetic, in-process, never a credential or real data.
    struct RehearsalTodayItem {
        let spelling: String
        let isNew: Bool
        let isFinished: Bool
        let firstResponse: String?
    }

    /// The fixed six-item study world behind `studyTodayItems` /
    /// `studyProgress`:
    ///
    ///     finished (3):   alpha (new, FORGET) · beta (VAGUE) · gamma (FAMILIAR)
    ///     unfinished (3): delta (new) · epsilon · zeta
    ///
    /// so the five supported public presets derive deterministic non-empty
    /// answers: 今天已学 = 3, 今日待复习 = 3, 今天新学 = 2, 今天忘记 = 1
    /// (alpha), 今天模糊 = 1 (beta). StudyRecord enumeration stays empty —
    /// those presets are withdrawn from the public UI and must not be
    /// reintroduced to satisfy tests.
    static let rehearsalTodayWorld: [RehearsalTodayItem] = [
        .init(spelling: "alpha", isNew: true, isFinished: true, firstResponse: "FORGET"),
        .init(spelling: "beta", isNew: false, isFinished: true, firstResponse: "VAGUE"),
        .init(spelling: "gamma", isNew: false, isFinished: true, firstResponse: "FAMILIAR"),
        .init(spelling: "delta", isNew: true, isFinished: false, firstResponse: nil),
        .init(spelling: "epsilon", isNew: false, isFinished: false, firstResponse: nil),
        .init(spelling: "zeta", isNew: false, isFinished: false, firstResponse: nil),
    ]
}

extension CompanionViewModel {
    @MainActor
    static func makeRehearsal(
        perRequestDelaySeconds: Double = RehearsalMode.perRequestDelaySeconds,
        sleeperFactory: @escaping () -> RequestSleeper = { RehearsalSleeper() },
        backgroundAssertionFactory: @escaping @MainActor () -> BackgroundExecutionAssertion
            = { makeDefaultBackgroundExecutionAssertion() }
    ) -> CompanionViewModel {
        let transport = RehearsalTransport(perRequestDelaySeconds: perRequestDelaySeconds)
        return CompanionViewModel(
            phraseSafetyJournal: PhraseSafetyJournal(store: RehearsalPhraseJournalStore()),
            tokenStore: RehearsalTokenStore(),
            // Never FileHistoryStore: rehearsal receipts must not reach the
            // Owner's real local History.
            historyStore: RehearsalHistoryStore(),
            transportFactory: { transport },
            sleeperFactory: sleeperFactory,
            backgroundAssertionFactory: backgroundAssertionFactory
        )
    }
}

final class RehearsalPhraseJournalStore: PhraseSafetyJournalStore {
    private var entries: [PhraseSafetyEntry] = []
    func load() throws -> [PhraseSafetyEntry] { entries }
    func save(_ entries: [PhraseSafetyEntry]) throws { self.entries = entries }
}

/// History for a rehearsal run: fully in memory, so the History screen behaves
/// normally during the rehearsal and nothing survives the process.
///
/// It never resolves the application-support directory and never opens the
/// production `history-v1.json`, so a rehearsal cannot read, overwrite, append to
/// or delete real receipts.
final class RehearsalHistoryStore: HistoryStore {
    private let lock = NSLock()
    private var receipts: [ExecutionReceipt] = []

    func loadReceipts() throws -> [ExecutionReceipt] {
        lock.lock()
        defer { lock.unlock() }
        return receipts.sorted { $0.timestamp > $1.timestamp }
    }

    func saveReceipts(_ receipts: [ExecutionReceipt]) throws {
        lock.lock()
        self.receipts = receipts
        lock.unlock()
    }

    func clearReceipts() throws {
        lock.lock()
        receipts.removeAll()
        lock.unlock()
    }
}

/// Hands out a placeholder token without ever reading the Keychain. The normal
/// authenticated fake GET still has to succeed before the app becomes connected.
final class RehearsalTokenStore: TokenStore, CustomDebugStringConvertible {
    private var token: String? = RehearsalMode.placeholderToken

    func loadToken() throws -> String? { token }
    func saveToken(_ token: String) throws { self.token = token }
    func deleteToken() throws { token = nil }

    var debugDescription: String { "RehearsalTokenStore(<no real credential>)" }
}

/// Real elapsed time, so pacing and interruption windows behave like production.
struct RehearsalSleeper: RequestSleeper {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// An in-process stand-in for the Maimemo API. It performs no networking of any
/// kind — it only builds JSON that the production parsers accept.
final class RehearsalTransport: HTTPTransport, @unchecked Sendable {
    private struct StoredInterpretation {
        let text: String
        let tags: [String]
        /// The rehearsal server echoes the exact status it was asked to write,
        /// so a 未发布 rehearsal reads back truthfully instead of always
        /// appearing PUBLISHED (#161).
        let status: String
    }

    private struct StoredPhrase {
        let id: String
        let english: String
        let chinese: String
        let source: String
        let tags: [String]
    }

    private let lock = NSLock()
    private var vocabularyIDs: [String: String] = [:]
    private var stored: [String: StoredInterpretation] = [:]
    private var storedPhrases: [String: [StoredPhrase]] = [:]
    private var nextVocabularyNumber = 1
    private var nextPhraseNumber = 1
    private let perRequestDelaySeconds: Double

    init(perRequestDelaySeconds: Double = RehearsalMode.perRequestDelaySeconds) {
        self.perRequestDelaySeconds = perRequestDelaySeconds
    }

    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse {
        // Deliberate: gives the Owner time to background the app mid-batch.
        if perRequestDelaySeconds > 0 {
            try? await Task.sleep(
                nanoseconds: UInt64(perRequestDelaySeconds * 1_000_000_000)
            )
        }

        switch request.route {
        case let .vocabulary(spelling):
            return try json(["voc": ["id": vocabularyID(for: spelling), "spelling": spelling]])

        case .vocabularyQuery:
            let spellings = (try? queryPayload(request.body))?["spellings"] as? [String] ?? []
            // The one deliberate unresolvable spelling stays absent, exactly
            // like a provider miss; everything else resolves deterministically.
            let resolvable = spellings.filter {
                BatchParser.normalizeSpelling($0) != BatchParser.normalizeSpelling(
                    RehearsalMode.unresolvableSpelling
                )
            }
            // The first-party raw envelope: `{ data: { voc: [...] }, ... }`.
            return try json([
                "data": [
                    "voc": resolvable.map {
                        ["id": vocabularyID(for: $0), "spelling": $0]
                    },
                ],
                "errors": [],
                "success": true,
            ])

        case let .interpretations(vocabularyID):
            return try json(["interpretations": records(for: vocabularyID)])

        case .createInterpretation:
            let payload = try interpretationPayload(request.body)
            guard let vocabularyID = payload["voc_id"] as? String,
                  let text = payload["interpretation"] as? String,
                  let tags = payload["tags"] as? [String],
                  let status = payload["status"] as? String,
                  InterpretationPublicationStatus.isDocumentedWriteStatus(status)
            else {
                return TransportResponse(status: 400, body: Data("{}".utf8))
            }
            store(text, tags: tags, status: status, for: vocabularyID)
            return try json([:], status: 201)

        case let .updateInterpretation(recordID):
            let payload = try interpretationPayload(request.body)
            guard let text = payload["interpretation"] as? String,
                  let tags = payload["tags"] as? [String],
                  let status = payload["status"] as? String,
                  InterpretationPublicationStatus.isDocumentedWriteStatus(status),
                  let vocabularyID = vocabularyID(forRecord: recordID)
            else {
                return TransportResponse(status: 400, body: Data("{}".utf8))
            }
            store(text, tags: tags, status: status, for: vocabularyID)
            return try json([:])

        case let .phrases(vocabularyID):
            return try json(["phrases": phraseRecords(for: vocabularyID)])

        case let .notes(vocabularyID):
            return try json(["notes": noteRecords(for: vocabularyID)])

        case .createPhrase:
            let payload = try phrasePayload(request.body)
            guard let vocabularyID = payload["voc_id"] as? String,
                  let english = payload["phrase"] as? String,
                  let chinese = payload["interpretation"] as? String,
                  let source = payload["origin"] as? String,
                  let tags = payload["tags"] as? [String]
            else {
                return TransportResponse(status: 400, body: Data("{}".utf8))
            }
            storePhrase(
                english: english,
                chinese: chinese,
                source: source,
                tags: tags,
                for: vocabularyID
            )
            return try json([:], status: 201)

        case .studyProgress:
            // Deterministic rehearsal study world: 3 of 6 today items are
            // finished, matching `rehearsalTodayWorld` below.
            return try json(["progress": ["finished": 3, "total": 6, "study_time": 0]])

        case .studyTodayItems:
            // Honors the same documented request filters (`is_finished`,
            // `is_new`) the production transport sends, over one fixed
            // six-row world — never a pre-baked unrelated list — so each of
            // the five supported presets derives its own deterministic
            // non-empty answer.
            let payload = try queryPayload(request.body)
            let wantedFinished = payload["is_finished"] as? Bool
            let wantedNew = payload["is_new"] as? Bool
            let rows: [[String: Any]] = RehearsalMode.rehearsalTodayWorld.enumerated()
                .filter { _, item in
                    (wantedFinished == nil || wantedFinished == item.isFinished)
                        && (wantedNew == nil || wantedNew == item.isNew)
                }
                .map { index, item in
                    var row: [String: Any] = [
                        "voc_id": "REHEARSAL_STUDY_ITEM_\(index + 1)",
                        "voc_spelling": item.spelling,
                        "order": index + 1,
                        "is_new": item.isNew,
                        "is_finished": item.isFinished,
                    ]
                    if let firstResponse = item.firstResponse {
                        row["first_response"] = firstResponse
                    }
                    return row
                }
            return try json(["today_items": rows])

        case .studyRecords:
            // StudyRecord enumeration stays empty: those presets are hidden
            // from the public UI and rehearsal must not resurrect them.
            return try json(["records": [], "count": 0])

        case .dogfoodDeleteInterpretation, .dogfoodDeletePhrase:
            // DEBUG-only real-provider cleanup routes are never used by
            // rehearsal state; an empty success keeps this fake exhaustive.
            return try json([:])
        }
    }

    private func vocabularyID(for spelling: String) -> String {
        let normalized = BatchParser.normalizeSpelling(spelling)
        lock.lock()
        defer { lock.unlock() }
        if let existing = vocabularyIDs[normalized] { return existing }
        let identifier = "REHEARSAL_VOC_\(nextVocabularyNumber)"
        nextVocabularyNumber += 1
        vocabularyIDs[normalized] = identifier
        if RehearsalMode.seededExistingSpellings.contains(normalized) {
            stored[identifier] = StoredInterpretation(
                text: "n. 演练用旧释义",
                tags: ["考研"],
                status: CompanionConstants.status
            )
        }
        return identifier
    }

    private func vocabularyID(forRecord recordID: String) -> String? {
        recordID.hasPrefix("REHEARSAL_REC_")
            ? "REHEARSAL_VOC_\(recordID.dropFirst("REHEARSAL_REC_".count))"
            : nil
    }

    private func records(for vocabularyID: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        guard let stored = stored[vocabularyID] else { return [] }
        let number = vocabularyID.dropFirst("REHEARSAL_VOC_".count)
        return [
            [
                "id": "REHEARSAL_REC_\(number)",
                "interpretation": stored.text,
                "tags": stored.tags,
                "status": stored.status,
            ],
        ]
    }

    /// Read-only rehearsal notes. There is no note write route, so this is
    /// purely a deterministic read fixture for batch Query.
    private func noteRecords(for vocabularyID: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        guard stored[vocabularyID] != nil else { return [] }
        let number = vocabularyID.dropFirst("REHEARSAL_VOC_".count)
        return [
            [
                "id": "REHEARSAL_NOTE_\(number)",
                "note_type": "MNEMONIC",
                "note": "演练用助记",
                "status": "PUBLISHED",
            ],
        ]
    }

    private func store(
        _ text: String,
        tags: [String],
        status: String,
        for vocabularyID: String
    ) {
        lock.lock()
        stored[vocabularyID] = StoredInterpretation(
            text: text,
            tags: tags,
            status: status
        )
        lock.unlock()
    }

    private func phraseRecords(for vocabularyID: String) -> [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return (storedPhrases[vocabularyID] ?? []).map { phrase in
            [
                "id": phrase.id,
                "phrase": phrase.english,
                "interpretation": phrase.chinese,
                "tags": phrase.tags,
                "origin": phrase.source,
                "status": CompanionConstants.status,
                // A deterministic, structurally reviewed non-blocking observation.
                "highlight": [],
            ]
        }
    }

    private func storePhrase(
        english: String,
        chinese: String,
        source: String,
        tags: [String],
        for vocabularyID: String
    ) {
        lock.lock()
        let phrase = StoredPhrase(
            id: "REHEARSAL_PHRASE_\(nextPhraseNumber)",
            english: english,
            chinese: chinese,
            source: source,
            tags: tags
        )
        nextPhraseNumber += 1
        storedPhrases[vocabularyID, default: []].append(phrase)
        lock.unlock()
    }

    private func queryPayload(_ body: Data?) throws -> [String: Any] {
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any]
        else {
            throw CompanionError.responseRejected
        }
        return object
    }

    private func interpretationPayload(_ body: Data?) throws -> [String: Any] {
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let payload = object["interpretation"] as? [String: Any]
        else {
            throw CompanionError.responseRejected
        }
        return payload
    }

    private func phrasePayload(_ body: Data?) throws -> [String: Any] {
        guard let body,
              let object = try JSONSerialization.jsonObject(with: body) as? [String: Any],
              let payload = object["phrase"] as? [String: Any]
        else {
            throw CompanionError.responseRejected
        }
        return payload
    }

    private func json(_ object: [String: Any], status: Int = 200) throws -> TransportResponse {
        TransportResponse(
            status: status,
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

// MARK: - Physical live dogfood (#155/#180 acceptance)

/// DEBUG-only, real-provider dogfood. It picks the first bounded-allowlist
/// candidate with no active self-authored interpretation, creates only
/// marker-owned records there, updates only the interpretation it just
/// created, and then deletes every active marker-owned record. Cleanup is also
/// exposed independently in Settings so an interrupted run can be restored on
/// a later launch. Release builds contain none of this surface.
struct LiveDogfoodReport: Equatable {
    let succeeded: Bool
    let message: String
    let diagnostic: String
    let remainingActiveRecords: Int
}

/// One ledger row: the minimum needed to recover this app's own dogfood
/// records across relaunch. Never a Token, fingerprint, request/response body.
struct DogfoodLedgerEntry: Codable, Equatable {
    var runID: String
    var kind: String
    var recordID: String?
    var spelling: String
    var state: String
}

/// DEBUG-only Application Support ledger (dispatch Part A). It nominates the
/// spellings a later relaunch must re-scan and shows cross-relaunch state; the
/// bounded marker scan over live authenticated lists remains the only deletion
/// authority, so a crash between provider success and ledger persistence can
/// never strand an orphan. Modeled on the D-020 journal: versioned Foundation
/// Codable file, atomic replace, excluded from backups.
final class DogfoodLedger: @unchecked Sendable {
    private let fileURL: URL
    private let lock = NSLock()

    init(applicationSupportDirectory: URL? = nil) {
        let base = applicationSupportDirectory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("DogfoodLedger-v1.json")
    }

    func load() -> [DogfoodLedgerEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    func recordActive(runID: String, kind: String, recordID: String?, spelling: String) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        entries.removeAll { $0.runID == runID && $0.kind == kind }
        entries.append(
            DogfoodLedgerEntry(
                runID: runID,
                kind: kind,
                recordID: recordID,
                spelling: spelling,
                state: "active"
            )
        )
        persistLocked(entries)
    }

    /// Marks entries deleted once the authenticated readback proves the exact
    /// record is absent or only a `DELETED` tombstone. Entries whose recorded
    /// ID no longer appears active in a bounded scan are retired the same way.
    func retire(recordIDs: Set<String>) {
        guard !recordIDs.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        var changed = false
        for index in entries.indices where entries[index].state == "active" {
            if let id = entries[index].recordID, recordIDs.contains(id) {
                entries[index].state = "deleted"
                changed = true
            }
        }
        if changed { persistLocked(entries) }
    }

    /// GET-only reconciliation for a crash between provider DELETE and ledger
    /// retire (#183 E3): an active entry whose record ID no longer exists in
    /// the fresh authenticated lists is stale and retired here. This is
    /// bookkeeping only — it never dispatches anything.
    func retireAbsent(visibleActiveRecordIDs: Set<String>) {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        var changed = false
        for index in entries.indices where entries[index].state == "active" {
            if let id = entries[index].recordID, !visibleActiveRecordIDs.contains(id) {
                entries[index].state = "deleted"
                changed = true
            }
        }
        if changed { persistLocked(entries) }
    }

    func spellings() -> Set<String> {
        Set(load().map(\.spelling))
    }

    func activeCount() -> Int {
        load().count { $0.state == "active" }
    }

    private func loadLocked() -> [DogfoodLedgerEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([DogfoodLedgerEntry].self, from: data)
        else {
            // A missing or unreadable file starts fresh: the bounded marker
            // scan, not this ledger, is what actually finds live records.
            return []
        }
        return entries
    }

    private func persistLocked(_ entries: [DogfoodLedgerEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        do {
            try data.write(to: fileURL, options: .atomic)
            var fileURL = fileURL
            var resourceValues = URLResourceValues()
            resourceValues.isExcludedFromBackup = true
            try? fileURL.setResourceValues(resourceValues)
        } catch {
            // Ledger persistence is best-effort state; the scan-based cleanup
            // path remains complete without it.
        }
    }
}

struct LiveDogfoodRunner {
    /// Bounded candidate allowlist (dispatch Part B): provider-known dictionary
    /// words, each evaluated read-only before any write. The first candidate
    /// with no active self-authored interpretation and phrase headroom becomes
    /// the run target; if none qualifies the live subtest blocks instead of
    /// touching real existing content.
    static let candidateSpellings = ["apple", "banana", "national", "ocean", "river"]
    static let marker = "__XHN_DOGFOOD_V1__"
    /// The phrase-family marker. The provider's documented phrase shape is a
    /// natural example sentence for the headword (its own `highlight` is
    /// computed from it), so the dogfood phrase embeds the headword and carries
    /// a hyphen-safe unique marker instead of the underscore interpretation
    /// marker; both are exact, run-unique, and both count for cleanup.
    static let phraseMarker = "XHN-DOGFOOD-"
    /// The provider's documented five-phrase-per-word ceiling (D-020). A
    /// candidate with more than four active phrases is never chosen, so the
    /// dogfood phrase always has a real free slot.
    static let phraseHeadroomLimit = 4

    let api: MaimemoTransport
    let ledger: DogfoodLedger

    init(api: MaimemoTransport, ledger: DogfoodLedger = DogfoodLedger()) {
        self.api = api
        self.ledger = ledger
    }

    /// GET-only residual count across every spelling a run could ever have
    /// used: the whole allowlist plus anything the ledger remembers. No
    /// mutation, no retry — the visible residual state for the Settings entry.
    func scanResidual() async -> LiveDogfoodReport {
        var events: [String] = ["scan_start ledger_active=\(ledger.activeCount())"]
        do {
            let remaining = try await countActiveMarkerRecords(events: &events)
            events.append("scan_done remaining=\(remaining)")
            return report(
                true,
                remaining == 0
                    ? "扫描完成 · 活跃残留 0"
                    : "扫描完成 · 活跃残留 \(remaining)",
                events,
                remaining
            )
        } catch {
            events.append("scan_error category=\(sanitized(error))")
            return report(false, "扫描未完成 · 状态未知", events, -1)
        }
    }

    func run() async -> LiveDogfoodReport {
        let runToken = Self.marker + UUID().uuidString
        var events: [String] = ["dogfood_start ledger_active=\(ledger.activeCount())"]

        do {
            let pre = await cleanupAll()
            events.append(contentsOf: pre.events)
            guard pre.remaining == 0 else {
                return report(false, "Dogfood 预清理未闭环 · 剩余 \(pre.remaining)", events, pre.remaining)
            }

            let vocabulary: VocabularyRecord
            do {
                vocabulary = try await selectTarget(events: &events)
            } catch {
                events.append("target_selection=blocked")
                return report(
                    false,
                    "无安全候选词 · 已阻断真实写入",
                    events,
                    0
                )
            }
            events.append("target=\(vocabulary.spelling)")

            let baseline = try await snapshot(vocabularyID: vocabulary.id)
            events.append("baseline interpretations=\(baseline.interpretationIDs.count) phrases=\(baseline.phraseIDs.count)")

            let createdInterpretation = try await createInterpretation(
                vocabularyID: vocabulary.id,
                runToken: runToken,
                events: &events
            )
            ledger.recordActive(
                runID: runToken,
                kind: "interpretation",
                recordID: createdInterpretation,
                spelling: vocabulary.spelling
            )
            events.append("interpretation_create=confirmed")

            try await updateInterpretation(
                recordID: createdInterpretation,
                vocabularyID: vocabulary.id,
                runToken: runToken,
                events: &events
            )
            events.append("interpretation_update=confirmed")

            let createdPhrase = try await createPhrase(
                vocabularyID: vocabulary.id,
                runToken: runToken,
                events: &events
            )
            ledger.recordActive(
                runID: runToken,
                kind: "phrase",
                recordID: createdPhrase,
                spelling: vocabulary.spelling
            )
            events.append("phrase_create=confirmed")

            let cleanup = await cleanupAll()
            events.append(contentsOf: cleanup.events)
            guard cleanup.remaining == 0 else {
                return report(false, "Dogfood 写入完成但撤回不完整 · 剩余 \(cleanup.remaining)", events, cleanup.remaining)
            }

            let restored = try await snapshot(vocabularyID: vocabulary.id)
            guard restored == baseline else {
                events.append("baseline_restore=mismatch")
                return report(false, "Dogfood 已删除测试记录，但基线校验不一致", events, 0)
            }
            events.append("baseline_restore=exact")
            return report(true, "Dogfood 验证通过 · 数据已恢复原样 · 剩余 0", events, 0)
        } catch {
            events.append("run_error category=\(sanitized(error))")
            let cleanup = await cleanupAll()
            events.append(contentsOf: cleanup.events)
            let suffix = cleanup.remaining == 0 ? "；已自动撤回" : "；仍有 \(cleanup.remaining) 条活跃残留"
            return report(false, "Dogfood 验证失败\(suffix)", events, cleanup.remaining)
        }
    }

    func cleanup() async -> LiveDogfoodReport {
        let result = await cleanupAll()
        return report(
            result.remaining == 0,
            result.remaining == 0
                ? "Dogfood 已清理 · 剩余 0"
                : "Dogfood 清理未闭环 · 剩余 \(result.remaining)",
            result.events,
            result.remaining
        )
    }

    private struct Baseline: Equatable {
        let interpretationIDs: Set<String>
        let phraseIDs: Set<String>
    }

    /// Exact marker ownership for a phrase record: either the underscore
    /// interpretation-family marker or the hyphen phrase-family marker, in the
    /// sentence or in the origin. Cleanup deletes only these records.
    private func isMarkerOwnedPhrase(_ record: PhraseRecord) -> Bool {
        let owned = record.phrase.contains(Self.marker)
            || record.origin.contains(Self.marker)
            || record.phrase.contains(Self.phraseMarker)
            || record.origin.contains(Self.phraseMarker)
        return owned
    }

    /// Read-only selection over the bounded allowlist. Every check is an
    /// authenticated GET; an unreadable or self-authored candidate is skipped,
    /// never altered. Exhausting the allowlist blocks the live subtest.
    private func selectTarget(events: inout [String]) async throws -> VocabularyRecord {
        for spelling in Self.candidateSpellings {
            guard let vocabulary = try? await api.vocabulary(spelling: spelling) else {
                events.append("candidate \(spelling) unresolved")
                continue
            }
            guard let interpretations = try? await api.interpretations(vocabularyID: vocabulary.id),
                  let phrases = try? await api.phrases(vocabularyID: vocabulary.id)
            else {
                events.append("candidate \(spelling) unreadable")
                continue
            }
            let activeInterpretations = interpretations.filter { $0.status != "DELETED" }
            let activePhrases = phrases.filter { $0.status != "DELETED" }
            guard activeInterpretations.isEmpty else {
                events.append("candidate \(spelling) skip interpretation=\(activeInterpretations.count)")
                continue
            }
            guard activePhrases.count <= Self.phraseHeadroomLimit else {
                events.append("candidate \(spelling) skip phrases=\(activePhrases.count)")
                continue
            }
            return vocabulary
        }
        throw CompanionError.blocked
    }

    /// Every spelling this app's dogfood could ever have touched: the whole
    /// allowlist (a crashed run's target is always inside it) plus whatever
    /// the ledger and the #183 round-2 experiment manifest remember.
    private var scanSpellings: Set<String> {
        Set(Self.candidateSpellings)
            .union(ledger.spellings())
            .union(DogfoodExperimentStore.shared.baselines().map(\.spelling))
    }

    private func countActiveMarkerRecords(events: inout [String]) async throws -> Int {
        var total = 0
        var visibleActiveRecordIDs = Set<String>()
        for spelling in scanSpellings.sorted() {
            guard let vocabulary = try? await api.vocabulary(spelling: spelling) else { continue }
            guard let interpretations = try? await api.interpretations(vocabularyID: vocabulary.id),
                  let phrases = try? await api.phrases(vocabularyID: vocabulary.id)
            else {
                // An unreadable spelling cannot prove zero, so it counts as an
                // unresolved residue rather than a quiet pass.
                events.append("scan \(spelling) unreadable")
                total += 1
                continue
            }
            for record in interpretations where record.status != "DELETED" {
                visibleActiveRecordIDs.insert(record.id)
            }
            for record in phrases where record.status != "DELETED" {
                visibleActiveRecordIDs.insert(record.id)
            }
            let activeMarkerInterpretations = interpretations.count {
                $0.status != "DELETED" && $0.interpretation.contains(Self.marker)
            }
            let activeMarkerPhrases = phrases.count {
                $0.status != "DELETED" && isMarkerOwnedPhrase($0)
            }
            total += activeMarkerInterpretations + activeMarkerPhrases
        }
        // GET-only ledger reconciliation (#183 E3): a stale active entry whose
        // record is provably absent from the fresh lists retires here. Never a
        // mutation, never a blind repeat.
        ledger.retireAbsent(visibleActiveRecordIDs: visibleActiveRecordIDs)
        return total
    }

    private func snapshot(vocabularyID: String) async throws -> Baseline {
        let interpretations = try await api.interpretations(vocabularyID: vocabularyID)
        let phrases = try await api.phrases(vocabularyID: vocabularyID)
        return Baseline(
            interpretationIDs: Set(
                interpretations
                    .filter { $0.status != "DELETED" && !$0.interpretation.contains(Self.marker) }
                    .map(\.id)
            ),
            phraseIDs: Set(
                phrases
                    .filter {
                        $0.status != "DELETED" && !isMarkerOwnedPhrase($0)
                    }
                    .map(\.id)
            )
        )
    }

    /// The provider's authenticated list reads are eventually consistent: a
    /// record proven written — or just deleted — can lag one or two list GETs.
    /// This bounded, GET-only settle window re-reads until the expected state
    /// is visible or the attempts run out; it never repeats a mutation.
    private func settleReadback<T>(
        attempts: Int = 4,
        intervalNanoseconds: UInt64 = 3_000_000_000,
        _ read: () async throws -> T?
    ) async throws -> T {
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
            if let value = try await read() {
                return value
            }
        }
        throw CompanionError.uncertainWriteOutcome
    }

    /// Content-free dispatch stage for the diagnostic: status codes only, no
    /// record identity or content.
    private func dispatchEvent(_ dispatch: PostDispatchResult) -> String {
        switch dispatch {
        case .notDispatched:
            return "notDispatched"
        case let .clean2xx(status):
            return "clean2xx(\(status))"
        case let .httpRejected(status):
            return "httpRejected(\(status))"
        case let .transportFailure(category):
            return "transportFailure(\(category.rawValue))"
        }
    }

    private func createInterpretation(
        vocabularyID: String,
        runToken: String,
        events: inout [String]
    ) async throws -> String {
        let proposed = "n. \(runToken) create"
        let body = try JSONSerialization.data(
            withJSONObject: [
                "interpretation": [
                    "voc_id": vocabularyID,
                    "interpretation": proposed,
                    "tags": [String](),
                    "status": "UNPUBLISHED",
                ],
            ],
            options: [.sortedKeys]
        )
        let control = ExecutionControl()
        let dispatch = await api.post(route: .createInterpretation, body: body, control: control)
        events.append("interpretation_create dispatch=\(dispatchEvent(dispatch))")
        guard dispatch.isClean2xx else {
            control.finishPostResolution()
            throw CompanionError.uncertainWriteOutcome
        }
        defer { control.finishPostResolution() }
        return try await settleReadback {
            let records = try await api.interpretations(
                vocabularyID: vocabularyID,
                control: control,
                readback: true
            )
            let matches = records.filter {
                $0.status != "DELETED" && $0.interpretation == proposed
            }
            return matches.count == 1 ? matches[0].id : nil
        }
    }

    private func updateInterpretation(
        recordID: String,
        vocabularyID: String,
        runToken: String,
        events: inout [String]
    ) async throws {
        let proposed = "n. \(runToken) updated"
        let body = try JSONSerialization.data(
            withJSONObject: [
                "interpretation": [
                    "interpretation": proposed,
                    "tags": [String](),
                    "status": "UNPUBLISHED",
                ],
            ],
            options: [.sortedKeys]
        )
        let control = ExecutionControl()
        let dispatch = await api.post(
            route: .updateInterpretation(recordID: recordID),
            body: body,
            control: control
        )
        events.append("interpretation_update dispatch=\(dispatchEvent(dispatch))")
        guard dispatch.isClean2xx else {
            control.finishPostResolution()
            throw CompanionError.uncertainWriteOutcome
        }
        defer { control.finishPostResolution() }
        _ = try await settleReadback {
            let records = try await api.interpretations(
                vocabularyID: vocabularyID,
                control: control,
                readback: true
            )
            let confirmed = records.contains {
                $0.id == recordID && $0.status != "DELETED" && $0.interpretation == proposed
            }
            return confirmed ? true : nil
        }
    }

    private func createPhrase(
        vocabularyID: String,
        runToken: String,
        events: inout [String]
    ) async throws -> String {
        let uniquePhraseMarker = Self.phraseMarker + runSuffix(runToken)
        let english = "I ate an apple today. (\(uniquePhraseMarker))"
        let chinese = "小黑鸟回滚测试例句。"
        let body = try JSONSerialization.data(
            withJSONObject: [
                "phrase": [
                    "voc_id": vocabularyID,
                    "phrase": english,
                    "interpretation": chinese,
                    "tags": [String](),
                    "origin": "",
                ],
            ],
            options: [.sortedKeys]
        )
        let control = ExecutionControl()
        let dispatch = await api.createPhrase(body: body, control: control)
        events.append("phrase_create dispatch=\(dispatchEvent(dispatch.dispatch))")
        guard dispatch.dispatch.isClean2xx else {
            control.finishPostResolution()
            throw CompanionError.uncertainWriteOutcome
        }
        defer { control.finishPostResolution() }
        return try await settleReadback(attempts: 6) {
            let records = try await api.phrases(
                vocabularyID: vocabularyID,
                control: control,
                readback: true
            )
            let matches = records.filter {
                $0.status != "DELETED" && $0.phrase == english
            }
            return matches.count == 1 ? matches[0].id : nil
        }
    }

    /// The run-unique tail of a marker token (everything after the shared
    /// marker literal), reused to build the phrase-family marker.
    private func runSuffix(_ runToken: String) -> String {
        runToken.count > Self.marker.count
            ? String(runToken.dropFirst(Self.marker.count))
            : runToken
    }

    /// One bounded delete sweep over every scan spelling. Deletion authority is
    /// the live marker content itself: only records whose just-read content
    /// carries the exact marker are ever passed to the documented DELETE. Each
    /// clean DELETE is followed by an authenticated GET settle window that must
    /// show the record absent or a `DELETED` tombstone — never an active marker.
    private func sweepDeletes(
        events: inout [String]
    ) async -> (verified: Set<String>, dispatchedDeletes: Int) {
        var verifiedRecordIDs = Set<String>()
        var dispatchedDeletes = 0
        for spelling in scanSpellings.sorted() {
            guard let vocabulary = try? await api.vocabulary(spelling: spelling) else { continue }
            guard let interpretations = try? await api.interpretations(vocabularyID: vocabulary.id),
                  let phrases = try? await api.phrases(vocabularyID: vocabulary.id)
            else {
                events.append("cleanup \(spelling) unreadable")
                continue
            }

            let interpretationIDs = interpretations
                .filter { $0.status != "DELETED" && $0.interpretation.contains(Self.marker) }
                .map(\.id)
            let phraseIDs = phrases
                .filter { $0.status != "DELETED" && isMarkerOwnedPhrase($0) }
                .map(\.id)

            if !interpretationIDs.isEmpty || !phraseIDs.isEmpty {
                events.append("cleanup_found \(spelling) interpretations=\(interpretationIDs.count) phrases=\(phraseIDs.count)")
            }

            for id in interpretationIDs {
                let control = ExecutionControl()
                let dispatch = await api.deleteDogfoodInterpretation(recordID: id, control: control)
                if dispatch.isClean2xx { dispatchedDeletes += 1 }
                events.append("delete interpretation dispatch=\(dispatchEvent(dispatch))")
                var verified = false
                if dispatch.isClean2xx {
                    verified = (try? await settleReadback(attempts: 3) {
                        let records = try await api.interpretations(
                            vocabularyID: vocabulary.id,
                            control: control,
                            readback: true
                        )
                        return !records.contains {
                            $0.id == id && $0.status != "DELETED"
                        } ? true : nil
                    }) ?? false
                }
                control.finishPostResolution()
                if verified { verifiedRecordIDs.insert(id) }
            }

            for id in phraseIDs {
                let control = ExecutionControl()
                let dispatch = await api.deleteDogfoodPhrase(recordID: id, control: control)
                if dispatch.isClean2xx { dispatchedDeletes += 1 }
                events.append("delete phrase dispatch=\(dispatchEvent(dispatch))")
                var verified = false
                if dispatch.isClean2xx {
                    verified = (try? await settleReadback(attempts: 3) {
                        let records = try await api.phrases(
                            vocabularyID: vocabulary.id,
                            control: control,
                            readback: true
                        )
                        return !records.contains {
                            $0.id == id && $0.status != "DELETED"
                        } ? true : nil
                    }) ?? false
                }
                control.finishPostResolution()
                if verified { verifiedRecordIDs.insert(id) }
            }
        }
        return (verifiedRecordIDs, dispatchedDeletes)
    }

    private func cleanupAll() async -> (remaining: Int, events: [String]) {
        var events: [String] = ["cleanup_start ledger_active=\(ledger.activeCount())"]
        do {
            let (verifiedRecordIDs, dispatchedDeletes) = await sweepDeletes(events: &events)
#if DEBUG
            // #183 E3: one-shot crash after a clean provider DELETE, before the
            // ledger retire. Gated on this sweep having dispatched at least one
            // clean DELETE on marker-owned records, so an empty sweep never
            // fires and readback lag cannot suppress the boundary.
            if dispatchedDeletes > 0,
               DogfoodExperimentStore.shared.consumeFault(
                   .afterDogfoodDelete2xxBeforeLedgerRetire,
                   markerIn: Self.marker
               ) {
                exit(0)
            }
#endif
            ledger.retire(recordIDs: verifiedRecordIDs)

            var remainingEvents: [String] = []
            var remaining = try await countActiveMarkerRecords(events: &remainingEvents)
            // The authenticated list is eventually consistent: a just-deleted
            // marker can still surface in the first recount. One bounded settle
            // plus one fresh evidence-based re-sweep — each DELETE still only
            // fires on a live GET that shows the exact marker active; nothing
            // here is a blind mutation retry.
            if remaining > 0 {
                events.append("cleanup_settle remaining=\(remaining)")
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                let (reverified, _) = await sweepDeletes(events: &events)
                ledger.retire(recordIDs: reverified)
                remaining = try await countActiveMarkerRecords(events: &remainingEvents)
                events.append("cleanup_recount remaining=\(remaining)")
            }
            events.append("cleanup_done remaining=\(remaining)")
            return (remaining, events)
        } catch {
            events.append("cleanup_error category=\(sanitized(error))")
            return (1, events)
        }
    }

    private func report(
        _ succeeded: Bool,
        _ message: String,
        _ events: [String],
        _ remaining: Int
    ) -> LiveDogfoodReport {
        LiveDogfoodReport(
            succeeded: succeeded,
            message: message,
            diagnostic: (["小黑鸟伴侣 Live Dogfood Diagnostic v1"] + events).joined(separator: "\n"),
            remainingActiveRecords: remaining
        )
    }

    private func sanitized(_ error: Error) -> String {
        (error as? CompanionError)?.rawValue ?? "other"
    }
}

// MARK: - High-level live state matrix (#183 round 2)

/// DEBUG-only, in-memory mutation audit. Counts dispatched mutating requests by
/// fixed route name only — never a Token, record ID or request body. Blocked /
/// no-op UI paths must show a delta of zero here.
enum LiveMutationAudit {
    static let interpretationCreate = "interpretation_create_post"
    static let interpretationUpdate = "interpretation_update_post"
    static let phraseCreate = "phrase_create_post"
    static let dogfoodDeleteInterpretation = "dogfood_delete_interpretation"
    static let dogfoodDeletePhrase = "dogfood_delete_phrase"

    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    static func noteDispatched(route: InterpretationRoute) {
        let name: String
        switch route {
        case .createInterpretation: name = interpretationCreate
        case .updateInterpretation: name = interpretationUpdate
        case .createPhrase: name = phraseCreate
        case .dogfoodDeleteInterpretation: name = dogfoodDeleteInterpretation
        case .dogfoodDeletePhrase: name = dogfoodDeletePhrase
        default: return
        }
        lock.lock()
        counts[name, default: 0] += 1
        lock.unlock()
    }

    static func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[name, default: 0]
    }

    static func snapshotText() -> String {
        lock.lock()
        defer { lock.unlock() }
        return [
            interpretationCreate,
            interpretationUpdate,
            phraseCreate,
            dogfoodDeleteInterpretation,
            dogfoodDeletePhrase,
        ]
        .map { "\($0)=\(counts[$0, default: 0])" }
        .joined(separator: "\n")
    }

    static func reset() {
        lock.lock()
        counts.removeAll()
        lock.unlock()
    }
}

/// The three crash boundaries this round attacks (#183 Part E / pilot §D/§E).
enum DogfoodFaultBoundary: String, Codable, CaseIterable {
    case afterInterpretationMutation2xxBeforeReadback = "I1"
    case afterPhraseCreate2xxBeforeReadbackOrJournalClose = "P1"
    case afterDogfoodDelete2xxBeforeLedgerRetire = "D1"

    var armLabel: String {
        switch self {
        case .afterInterpretationMutation2xxBeforeReadback:
            return "武装：释义写入后崩溃"
        case .afterPhraseCreate2xxBeforeReadbackOrJournalClose:
            return "武装：例句写入后崩溃"
        case .afterDogfoodDelete2xxBeforeLedgerRetire:
            return "武装：清理删除后崩溃"
        }
    }
}

/// One registered scenario word's pre-mutation truth: every NON-marker active
/// record ID, so after cleanup the exact baseline can be verified.
struct DogfoodScenarioBaseline: Codable, Equatable {
    var spelling: String
    var nonMarkerInterpretationIDs: Set<String>
    var nonMarkerPhraseIDs: Set<String>
}

/// DEBUG-only experiment state, persisted beside the dogfood ledger: the armed
/// one-shot fault plus every registered scenario baseline. Marker content is
/// never persisted — only spelling + record-ID sets.
final class DogfoodExperimentStore: @unchecked Sendable {
    static let shared = DogfoodExperimentStore()

    private struct State: Codable {
        var armedFault: String?
        var baselines: [DogfoodScenarioBaseline] = []
        var usedWords: [String] = []
    }

    private let fileURL: URL
    private let lock = NSLock()
    private var state: State

    init(applicationSupportDirectory: URL? = nil) {
        let base = applicationSupportDirectory ?? (try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? FileManager.default.temporaryDirectory
        fileURL = base.appendingPathComponent("DogfoodExperiment-v1.json")
        lock.lock()
        defer { lock.unlock() }
        if let data = try? Data(contentsOf: fileURL),
           let loaded = try? JSONDecoder().decode(State.self, from: data) {
            state = loaded
        } else {
            state = State(armedFault: nil)
        }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: fileURL, options: .atomic)
        var url = fileURL
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? url.setResourceValues(values)
    }

    func arm(_ boundary: DogfoodFaultBoundary) {
        lock.lock()
        state.armedFault = boundary.rawValue
        persistLocked()
        lock.unlock()
    }

    func cancelArm() {
        lock.lock()
        state.armedFault = nil
        persistLocked()
        lock.unlock()
    }

    var armedDescription: String {
        lock.lock()
        defer { lock.unlock() }
        return state.armedFault ?? "none"
    }

    /// One-shot, marker-gated fault consumption. Fires only when the armed
    /// boundary matches AND the just-dispatched content carries this app's
    /// dogfood marker family, so a non-marker Owner write can never be killed.
    @discardableResult
    func consumeFault(_ boundary: DogfoodFaultBoundary, markerIn content: String) -> Bool {
        let owned = content.contains(LiveDogfoodRunner.marker)
            || content.contains(LiveDogfoodRunner.phraseMarker)
        lock.lock()
        defer { lock.unlock() }
        guard state.armedFault == boundary.rawValue, owned else { return false }
        state.armedFault = nil
        persistLocked()
        return true
    }

    func register(_ baseline: DogfoodScenarioBaseline) {
        lock.lock()
        state.baselines.removeAll { $0.spelling == baseline.spelling }
        state.baselines.append(baseline)
        if !state.usedWords.contains(baseline.spelling) {
            state.usedWords.append(baseline.spelling)
        }
        persistLocked()
        lock.unlock()
    }

    func baselines() -> [DogfoodScenarioBaseline] {
        lock.lock()
        defer { lock.unlock() }
        return state.baselines
    }

    func usedWords() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return state.usedWords
    }
}

/// Prepares and verifies the #183 round-2 state-matrix scenarios. Setup
/// mutations are marker-owned only and go through the same transport; the
/// mutations under test are NOT performed here — they must run through the
/// normal product UI. Reports are machine-readable so a physical UI test can
/// parse the exact editor document to type.
struct LiveExperimentRunner {
    static let allowlist = [
        "apple", "banana", "national", "ocean", "river", "garden", "window",
        "market", "silver", "corner", "teacher", "coffee", "bright", "quiet",
        "hammer", "meadow", "planet", "tunnel", "velvet", "copper", "ladder",
        "marble", "ribbon", "saddle", "walnut",
    ]
    /// A spelling the real provider cannot resolve (nonsense string, never a
    /// real word, so it can never collide with Owner data).
    static let unresolvableSpelling = "qzxwvjkq"

    let api: MaimemoTransport
    let ledger: DogfoodLedger
    let experiment: DogfoodExperimentStore

    init(
        api: MaimemoTransport,
        ledger: DogfoodLedger = DogfoodLedger(),
        experiment: DogfoodExperimentStore = .shared
    ) {
        self.api = api
        self.ledger = ledger
        self.experiment = experiment
    }

    // MARK: Scenario prep

    func prepare(_ code: String) async -> LiveDogfoodReport {
        var events = ["exp_start scenario=\(code)"]
        do {
            // Recovery-first: never build a precondition on top of a residue.
            let pre = await LiveDogfoodRunner(api: api, ledger: ledger).cleanup()
            events.append(contentsOf: pre.diagnostic.components(separatedBy: "\n").dropFirst())
            guard pre.remainingActiveRecords == 0 else {
                return report(false, "EXP BLOCKED \(code) 预清理未闭环", events, pre.remainingActiveRecords)
            }
            let nonce = Self.nonce()
            switch code {
            case "B1", "F2A", "F2B":
                return try await prepareInterpretationCreate(
                    code: code, nonce: nonce, events: &events,
                    requireToday: code == "F2A" ? true : (code == "F2B" ? false : nil)
                )
            case "B2":
                return try await prepareB2(nonce: nonce, events: &events)
            case "B3":
                return try await prepareB3(nonce: nonce, events: &events)
            case "B4":
                return try await prepareB4(nonce: nonce, events: &events)
            case "B5":
                return try await prepareB5(nonce: nonce, events: &events)
            case "C1", "E2":
                return try await preparePhraseCreate(code: code, nonce: nonce, events: &events)
            case "C2":
                return try await preparePhraseTop(code: code, nonce: nonce, target: 1, events: &events)
            case "C3":
                return try await preparePhraseTop(code: code, nonce: nonce, target: 4, events: &events)
            case "C4":
                return try await preparePhraseTop(code: code, nonce: nonce, target: 5, events: &events)
            case "C5":
                return try await prepareC5(nonce: nonce, events: &events)
            case "D":
                return try await prepareD(nonce: nonce, events: &events)
            case "E1":
                return try await prepareE1(nonce: nonce, events: &events)
            case "E3":
                return try await prepareE3(nonce: nonce, events: &events)
            default:
                return report(false, "EXP UNKNOWN scenario=\(code)", events, 0)
            }
        } catch {
            events.append("exp_error category=\(sanitized(error))")
            return report(false, "EXP FAILED \(code)", events, -1)
        }
    }

    // MARK: Baseline verification

    func verifyBaselines() async -> LiveDogfoodReport {
        var events = ["verify_start"]
        var mismatches: [String] = []
        for baseline in experiment.baselines() {
            do {
                let vocabulary = try await api.vocabulary(spelling: baseline.spelling)
                let interpretations = try await api.interpretations(vocabularyID: vocabulary.id)
                let phrases = try await api.phrases(vocabularyID: vocabulary.id)
                let currentInterp = Set(
                    interpretations
                        .filter { $0.status != "DELETED" && !$0.interpretation.contains(LiveDogfoodRunner.marker) }
                        .map(\.id)
                )
                let currentPhrase = Set(
                    phrases
                        .filter { $0.status != "DELETED" && !isMarkerOwnedPhrase($0) }
                        .map(\.id)
                )
                if currentInterp == baseline.nonMarkerInterpretationIDs,
                   currentPhrase == baseline.nonMarkerPhraseIDs {
                    events.append("baseline_ok \(baseline.spelling)")
                } else {
                    let missingInterp = baseline.nonMarkerInterpretationIDs.subtracting(currentInterp).count
                    let extraInterp = currentInterp.subtracting(baseline.nonMarkerInterpretationIDs).count
                    let missingPhrase = baseline.nonMarkerPhraseIDs.subtracting(currentPhrase).count
                    let extraPhrase = currentPhrase.subtracting(baseline.nonMarkerPhraseIDs).count
                    mismatches.append(
                        "\(baseline.spelling) interp-\(missingInterp)+\(extraInterp) phrase-\(missingPhrase)+\(extraPhrase)"
                    )
                }
            } catch {
                mismatches.append("\(baseline.spelling) unreadable")
            }
        }
        if mismatches.isEmpty {
            events.append("verify_done exact=\(experiment.baselines().count)")
            return report(true, "基线核对一致 · \(experiment.baselines().count) 个词", events, 0)
        }
        events.append("verify_done mismatch=\(mismatches.joined(separator: ","))")
        return report(false, "基线不一致 · \(mismatches.joined(separator: "、"))", events, -1)
    }

    // MARK: F2 study-membership classification (read-only)

    func classifyStudyMembership() async -> LiveDogfoodReport {
        var events = ["classify_start"]
        do {
            let words = experiment.usedWords() + Self.allowlist
            let unique = Array(Set(words)).sorted()
            var lines: [String] = []
            var inPlan: [String] = []
            var outPlan: [String] = []
            for word in unique where word != Self.unresolvableSpelling {
                guard let vocabulary = try? await api.vocabulary(spelling: word) else {
                    lines.append("word=\(word) resolved=no")
                    continue
                }
                let interpretations = (try? await api.interpretations(vocabularyID: vocabulary.id)) ?? []
                let phrases = (try? await api.phrases(vocabularyID: vocabulary.id)) ?? []
                let activeInterp = interpretations.filter { $0.status != "DELETED" }.count
                let activePhrase = phrases.filter { $0.status != "DELETED" }.count
                let today = try await api.studyTodayItems(spellings: [word])
                let inToday = !today.isEmpty
                if inToday { inPlan.append(word) } else { outPlan.append(word) }
                lines.append(
                    "word=\(word) resolved=yes today=\(inToday ? "yes" : "no") interp=\(activeInterp) phrase=\(activePhrase)"
                )
            }
            events.append(contentsOf: lines)
            events.append("classify_done in=\(inPlan.count) out=\(outPlan.count)")
            return report(true, "分类完成 · in=\(inPlan.count) out=\(outPlan.count)", events, 0)
        } catch {
            events.append("classify_error category=\(sanitized(error))")
            return report(false, "分类失败", events, -1)
        }
    }

    // MARK: - Scenario implementations

    private func prepareInterpretationCreate(
        code: String,
        nonce: String,
        events: inout [String],
        requireToday: Bool?
    ) async throws -> LiveDogfoodReport {
        let content = "n. \(LiveDogfoodRunner.marker) \(code) \(nonce)"
        let word = try await pickWord(
            requireCleanInterpretations: true,
            requireToday: requireToday,
            events: &events
        )
        try await registerBaseline(word: word, events: &events)
        let doc = "\(word)\n\(content)"
        events.append("exp_ready scenario=\(code) word=\(word)")
        return report(
            true,
            "EXP READY \(code) word=\(word)",
            events + ["doc>>", doc, "<<doc"],
            0
        )
    }

    private func prepareB2(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        let old = "n. \(LiveDogfoodRunner.marker) B2old \(nonce)"
        let proposed = "n. \(LiveDogfoodRunner.marker) B2new \(nonce)"
        let word = try await pickWord(requireCleanInterpretations: true, events: &events)
        try await registerBaseline(word: word, events: &events)
        let vocabulary = try await api.vocabulary(spelling: word)
        _ = try await createMarkerInterpretation(vocabularyID: vocabulary.id, content: old)
        events.append("setup_interpretation=1 word=\(word)")
        let doc = "\(word)\n\(proposed)"
        events.append("exp_ready scenario=B2 word=\(word)")
        return report(true, "EXP READY B2 word=\(word)", events + ["doc>>", doc, "<<doc"], 0)
    }

    private func prepareB3(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        let content = "n. \(LiveDogfoodRunner.marker) B3 \(nonce)"
        let word = try await pickWord(requireCleanInterpretations: true, events: &events)
        try await registerBaseline(word: word, events: &events)
        let vocabulary = try await api.vocabulary(spelling: word)
        _ = try await createMarkerInterpretation(vocabularyID: vocabulary.id, content: content)
        events.append("setup_interpretation=1 word=\(word)")
        let doc = "\(word)\n\(content)"
        events.append("exp_ready scenario=B3 word=\(word)")
        return report(true, "EXP READY B3 word=\(word)", events + ["doc>>", doc, "<<doc"], 0)
    }

    private func prepareB4(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        let word = try await pickWord(requireCleanInterpretations: true, events: &events)
        try await registerBaseline(word: word, events: &events)
        let vocabulary = try await api.vocabulary(spelling: word)
        _ = try await createMarkerInterpretation(
            vocabularyID: vocabulary.id,
            content: "n. \(LiveDogfoodRunner.marker) B4a \(nonce)"
        )
        do {
            _ = try await createMarkerInterpretation(
                vocabularyID: vocabulary.id,
                content: "n. \(LiveDogfoodRunner.marker) B4b \(nonce)"
            )
        } catch {
            // If the provider refuses a second self-authored interpretation on
            // one word, the ambiguity state is unreachable on this account —
            // report it honestly instead of forcing the state.
            let cleanup = await LiveDogfoodRunner(api: api, ledger: ledger).cleanup()
            events.append("second_interpretation=refused provider_single_interp")
            return report(
                false,
                "EXP N/A B4 provider 拒绝同一词条的第二条自建释义",
                events + ["note=ambiguity unreachable on this account"],
                cleanup.remainingActiveRecords
            )
        }
        events.append("setup_interpretation=2 word=\(word)")
        let doc = "\(word)\nn. \(LiveDogfoodRunner.marker) B4new \(nonce)"
        events.append("exp_ready scenario=B4 word=\(word)")
        return report(true, "EXP READY B4 word=\(word)", events + ["doc>>", doc, "<<doc"], 0)
    }

    private func prepareB5(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        // No setup, no baseline: the provider itself must prove the word
        // unresolvable, and the product path must fail closed with zero writes.
        let doc = "\(Self.unresolvableSpelling)\nn. \(LiveDogfoodRunner.marker) B5 \(nonce)"
        events.append("exp_ready scenario=B5 word=\(Self.unresolvableSpelling)")
        return report(true, "EXP READY B5 word=\(Self.unresolvableSpelling)", events + ["doc>>", doc, "<<doc"], 0)
    }

    private func preparePhraseCreate(
        code: String,
        nonce: String,
        events: inout [String]
    ) async throws -> LiveDogfoodReport {
        let word = try await pickWord(requireCleanInterpretations: false, maxOwnerPhrases: 0, events: &events)
        try await registerBaseline(word: word, events: &events)
        let doc = Self.phraseDoc(word: word, nonce: nonce, suffix: code)
        events.append("exp_ready scenario=\(code) word=\(word)")
        return report(true, "EXP READY \(code) word=\(word)", events + ["doc>>", doc, "<<doc"], 0)
    }

    private func preparePhraseTop(
        code: String,
        nonce: String,
        target: Int,
        events: inout [String]
    ) async throws -> LiveDogfoodReport {
        let word = try await pickWord(
            requireCleanInterpretations: false,
            maxOwnerPhrases: target,
            events: &events
        )
        try await registerBaseline(word: word, events: &events)
        let vocabulary = try await api.vocabulary(spelling: word)
        let phrases = try await api.phrases(vocabularyID: vocabulary.id)
        let ownerActive = phrases.filter { $0.status != "DELETED" && !isMarkerOwnedPhrase($0) }.count
        let needed = target - ownerActive
        for index in 0..<max(needed, 0) {
            let origin = "\(LiveDogfoodRunner.phraseMarker)\(nonce)-\(code)\(index)"
            _ = try await createMarkerPhrase(
                vocabularyID: vocabulary.id,
                english: "The \(word) waits here. (setup \(index) \(nonce))",
                chinese: "矩阵预置例句。",
                origin: origin
            )
        }
        events.append("setup_phrase_topup=\(max(needed, 0)) word=\(word) target=\(target)")
        let doc = Self.phraseDoc(word: word, nonce: nonce, suffix: "\(code)main")
        events.append("exp_ready scenario=\(code) word=\(word)")
        return report(true, "EXP READY \(code) word=\(word)", events + ["doc>>", doc, "<<doc"], 0)
    }

    private func prepareC5(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        let word = try await pickWord(requireCleanInterpretations: false, maxOwnerPhrases: 0, events: &events)
        try await registerBaseline(word: word, events: &events)
        let origin = "\(LiveDogfoodRunner.phraseMarker)\(nonce)-C5"
        let base = "She said the \(word)'s 'rule' was \"fair\"."
        // Variant 2: only smart quotes differ; the product canonicalizes them,
        // so it must classify the row as already matching, never a new CREATE.
        let smart = "She said the \(word)\u{2019}s \u{2018}rule\u{2019} was \u{201C}fair\u{201D}."
        let doc = Self.phraseDoc(word: word, english: base, chinese: "矩阵引号例句。", origin: origin)
        let doc2 = Self.phraseDoc(word: word, english: smart, chinese: "矩阵引号例句。", origin: origin)
        let doc3 = Self.phraseDoc(word: word, english: base, chinese: "不同的中文翻译。", origin: origin)
        events.append("exp_ready scenario=C5 word=\(word)")
        return report(
            true,
            "EXP READY C5 word=\(word)",
            events + ["doc>>", doc, "<<doc", "doc2>>", doc2, "<<doc", "doc3>>", doc3, "<<doc"],
            0
        )
    }

    private func prepareD(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        let createWord = try await pickWord(requireCleanInterpretations: true, events: &events)
        let updateWord = try await pickWord(requireCleanInterpretations: true, events: &events)
        let matchWord = try await pickWord(requireCleanInterpretations: true, events: &events)
        try await registerBaseline(word: createWord, events: &events)
        try await registerBaseline(word: updateWord, events: &events)
        try await registerBaseline(word: matchWord, events: &events)

        let updateVocabulary = try await api.vocabulary(spelling: updateWord)
        _ = try await createMarkerInterpretation(
            vocabularyID: updateVocabulary.id,
            content: "n. \(LiveDogfoodRunner.marker) Dold \(nonce)"
        )
        let matchContent = "n. \(LiveDogfoodRunner.marker) Dmatch \(nonce)"
        let matchVocabulary = try await api.vocabulary(spelling: matchWord)
        _ = try await createMarkerInterpretation(
            vocabularyID: matchVocabulary.id,
            content: matchContent
        )
        events.append("setup_interpretation=2")

        let doc = [
            "\(createWord)\nn. \(LiveDogfoodRunner.marker) Dcreate \(nonce)",
            "\(updateWord)\nn. \(LiveDogfoodRunner.marker) Dnew \(nonce)",
            "\(matchWord)\n\(matchContent)",
            "\(Self.unresolvableSpelling)\nn. \(LiveDogfoodRunner.marker) Dblock \(nonce)",
        ].joined(separator: "\n")
        events.append("exp_ready scenario=D create=\(createWord) update=\(updateWord) match=\(matchWord)")
        return report(
            true,
            "EXP READY D create=\(createWord) update=\(updateWord) match=\(matchWord)",
            events + ["doc>>", doc, "<<doc"],
            0
        )
    }

    private func prepareE1(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        try await prepareInterpretationCreate(code: "E1", nonce: nonce, events: &events, requireToday: nil)
    }

    private func prepareE3(nonce: String, events: inout [String]) async throws -> LiveDogfoodReport {
        let word = try await pickWord(requireCleanInterpretations: true, events: &events)
        try await registerBaseline(word: word, events: &events)
        let vocabulary = try await api.vocabulary(spelling: word)
        let recordID = try await createMarkerInterpretation(
            vocabularyID: vocabulary.id,
            content: "n. \(LiveDogfoodRunner.marker) E3 \(nonce)"
        )
        ledger.recordActive(
            runID: LiveDogfoodRunner.marker + nonce,
            kind: "interpretation",
            recordID: recordID,
            spelling: word
        )
        events.append("exp_ready scenario=E3 word=\(word)")
        return report(true, "EXP READY E3 word=\(word)", events, 0)
    }

    // MARK: - Shared helpers

    static func phraseDoc(
        word: String,
        english: String? = nil,
        chinese: String,
        origin: String
    ) -> String {
        let sentence = english ?? "The \(word) hums a quiet tune here."
        return "## \(word)\nEN: \(sentence)\nZH: \(chinese)\nSOURCE: \(origin)"
    }

    /// The normal-path phrase document for a scenario: a natural sentence
    /// containing the actual headword, with the run marker in SOURCE/origin.
    static func phraseDoc(word: String, nonce: String, suffix: String) -> String {
        phraseDoc(
            word: word,
            english: nil,
            chinese: "矩阵测试例句。",
            origin: "\(LiveDogfoodRunner.phraseMarker)\(nonce)-\(suffix)"
        )
    }

    static func nonce() -> String {
        String(UUID().uuidString.prefix(6))
    }

    private func isMarkerOwnedPhrase(_ record: PhraseRecord) -> Bool {
        record.phrase.contains(LiveDogfoodRunner.marker)
            || record.origin.contains(LiveDogfoodRunner.marker)
            || record.phrase.contains(LiveDogfoodRunner.phraseMarker)
            || record.origin.contains(LiveDogfoodRunner.phraseMarker)
    }

    /// Read-only word selection. `requireToday` filters by the exact-spelling
    /// today-items read (F2). Words are freely reusable across scenarios: every
    /// prep begins with a marker cleanup and registers a fresh non-marker
    /// baseline, so a previously used word is exactly as safe as a fresh one.
    private func pickWord(
        requireCleanInterpretations: Bool,
        maxOwnerPhrases: Int = .max,
        requireToday: Bool? = nil,
        events: inout [String]
    ) async throws -> String {
        // A transient 429 right after a burst would otherwise make every
        // candidate look unresolvable; retry the whole bounded scan a couple
        // of times with a settle gap before concluding no candidate exists.
        for passIndex in 0..<3 {
            if passIndex > 0 {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                events.append("pick_retry pass=\(passIndex)")
            }
            if let word = try await pickWordOnce(
                requireCleanInterpretations: requireCleanInterpretations,
                maxOwnerPhrases: maxOwnerPhrases,
                requireToday: requireToday,
                events: &events
            ) {
                return word
            }
        }
        events.append("pick_failed")
        throw CompanionError.blocked
    }

    private func pickWordOnce(
        requireCleanInterpretations: Bool,
        maxOwnerPhrases: Int,
        requireToday: Bool?,
        events: inout [String]
    ) async throws -> String? {
        for word in Self.allowlist {
            guard let vocabulary = try? await api.vocabulary(spelling: word) else { continue }
            guard let interpretations = try? await api.interpretations(vocabularyID: vocabulary.id),
                  let phrases = try? await api.phrases(vocabularyID: vocabulary.id)
            else { continue }
            let activeInterp = interpretations.filter { $0.status != "DELETED" }
            let ownerActivePhrases = phrases.filter { $0.status != "DELETED" && !isMarkerOwnedPhrase($0) }
            if requireCleanInterpretations, !activeInterp.isEmpty { continue }
            if ownerActivePhrases.count > maxOwnerPhrases { continue }
            if let requireToday {
                let today = try await api.studyTodayItems(spellings: [word])
                if !today.isEmpty != requireToday { continue }
            }
            events.append("picked \(word)")
            return word
        }
        return nil
    }

    /// Durable registration BEFORE any scenario mutation (global recovery
    /// invariant): non-marker active IDs are captured and persisted first.
    private func registerBaseline(word: String, events: inout [String]) async throws {
        let vocabulary = try await api.vocabulary(spelling: word)
        let interpretations = try await api.interpretations(vocabularyID: vocabulary.id)
        let phrases = try await api.phrases(vocabularyID: vocabulary.id)
        let baseline = DogfoodScenarioBaseline(
            spelling: word,
            nonMarkerInterpretationIDs: Set(
                interpretations
                    .filter { $0.status != "DELETED" && !$0.interpretation.contains(LiveDogfoodRunner.marker) }
                    .map(\.id)
            ),
            nonMarkerPhraseIDs: Set(
                phrases
                    .filter { $0.status != "DELETED" && !isMarkerOwnedPhrase($0) }
                    .map(\.id)
            )
        )
        experiment.register(baseline)
        events.append("baseline_registered \(word) interp=\(baseline.nonMarkerInterpretationIDs.count) phrase=\(baseline.nonMarkerPhraseIDs.count)")
    }

    private func settleReadback<T>(
        attempts: Int = 4,
        intervalNanoseconds: UInt64 = 3_000_000_000,
        _ read: () async throws -> T?
    ) async throws -> T {
        for attempt in 0..<attempts {
            if attempt > 0 {
                try? await Task.sleep(nanoseconds: intervalNanoseconds)
            }
            if let value = try await read() {
                return value
            }
        }
        throw CompanionError.uncertainWriteOutcome
    }

    @discardableResult
    private func createMarkerInterpretation(
        vocabularyID: String,
        content: String,
        status: String = "PUBLISHED"
    ) async throws -> String {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "interpretation": [
                    "voc_id": vocabularyID,
                    "interpretation": content,
                    "tags": [String](),
                    "status": status,
                ],
            ],
            options: [.sortedKeys]
        )
        let control = ExecutionControl()
        let dispatch = await api.post(route: .createInterpretation, body: body, control: control)
        guard dispatch.isClean2xx else {
            control.finishPostResolution()
            throw CompanionError.uncertainWriteOutcome
        }
        defer { control.finishPostResolution() }
        return try await settleReadback {
            let records = try await api.interpretations(
                vocabularyID: vocabularyID,
                control: control,
                readback: true
            )
            let matches = records.filter { $0.status != "DELETED" && $0.interpretation == content }
            return matches.count == 1 ? matches[0].id : nil
        }
    }

    @discardableResult
    private func createMarkerPhrase(
        vocabularyID: String,
        english: String,
        chinese: String,
        origin: String
    ) async throws -> String {
        let body = try JSONSerialization.data(
            withJSONObject: [
                "phrase": [
                    "voc_id": vocabularyID,
                    "phrase": english,
                    "interpretation": chinese,
                    "tags": [String](),
                    "origin": origin,
                ],
            ],
            options: [.sortedKeys]
        )
        let control = ExecutionControl()
        let dispatch = await api.createPhrase(body: body, control: control)
        guard dispatch.dispatch.isClean2xx else {
            control.finishPostResolution()
            throw CompanionError.uncertainWriteOutcome
        }
        defer { control.finishPostResolution() }
        return try await settleReadback {
            let records = try await api.phrases(
                vocabularyID: vocabularyID,
                control: control,
                readback: true
            )
            let matches = records.filter { $0.status != "DELETED" && $0.phrase == english }
            return matches.count == 1 ? matches[0].id : nil
        }
    }

    private func report(
        _ succeeded: Bool,
        _ message: String,
        _ events: [String],
        _ remaining: Int
    ) -> LiveDogfoodReport {
        LiveDogfoodReport(
            succeeded: succeeded,
            message: message,
            diagnostic: (["小黑鸟伴侣 Live Experiment Diagnostic v1"] + events).joined(separator: "\n"),
            remainingActiveRecords: remaining
        )
    }

    private func sanitized(_ error: Error) -> String {
        (error as? CompanionError)?.rawValue ?? "other"
    }
}

#endif
