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
    /// The app's real view model, unless a DEBUG build was explicitly launched in
    /// rehearsal mode.
    @MainActor
    static func makeDefault() -> CompanionViewModel {
        #if DEBUG
        if RehearsalMode.isEnabled { return makeRehearsal() }
        #endif
        return CompanionViewModel()
    }
}

#if DEBUG

extension RehearsalMode {
    /// Long enough that the Owner can leave the app, take a call, and come back
    /// while the batch is still running.
    static let perRequestDelaySeconds = 2.5

    /// Obviously not a credential. Never leaves the process.
    static let placeholderToken = "REHEARSAL_ONLY_NOT_A_REAL_TOKEN"

    /// Spellings the rehearsal server pretends already have one self-authored
    /// interpretation, so a mixed CREATE/UPDATE batch can be rehearsed.
    static let seededExistingSpellings = ["manning", "certified"]
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

/// Hands out a placeholder token so the app is "connected" without ever reading
/// the Keychain. Nothing is persisted anywhere.
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

        case let .interpretations(vocabularyID):
            return try json(["interpretations": records(for: vocabularyID)])

        case .createInterpretation:
            let payload = try interpretationPayload(request.body)
            guard let vocabularyID = payload["voc_id"] as? String,
                  let text = payload["interpretation"] as? String,
                  let tags = payload["tags"] as? [String]
            else {
                return TransportResponse(status: 400, body: Data("{}".utf8))
            }
            store(text, tags: tags, for: vocabularyID)
            return try json([:], status: 201)

        case let .updateInterpretation(recordID):
            let payload = try interpretationPayload(request.body)
            guard let text = payload["interpretation"] as? String,
                  let tags = payload["tags"] as? [String],
                  let vocabularyID = vocabularyID(forRecord: recordID)
            else {
                return TransportResponse(status: 400, body: Data("{}".utf8))
            }
            store(text, tags: tags, for: vocabularyID)
            return try json([:])

        case let .phrases(vocabularyID):
            return try json(["phrases": phraseRecords(for: vocabularyID)])

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
                tags: ["考研"]
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
                "status": CompanionConstants.status,
            ],
        ]
    }

    private func store(_ text: String, tags: [String], for vocabularyID: String) {
        lock.lock()
        stored[vocabularyID] = StoredInterpretation(text: text, tags: tags)
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

#endif
