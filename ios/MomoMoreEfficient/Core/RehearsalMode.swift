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
    static func makeRehearsal() -> CompanionViewModel {
        let transport = RehearsalTransport()
        return CompanionViewModel(
            tokenStore: RehearsalTokenStore(),
            historyStore: FileHistoryStore(),
            transportFactory: { transport },
            sleeperFactory: { RehearsalSleeper() }
        )
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
    private let lock = NSLock()
    private var vocabularyIDs: [String: String] = [:]
    private var stored: [String: String] = [:]
    private var nextVocabularyNumber = 1
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
                  let text = payload["interpretation"] as? String
            else {
                return TransportResponse(status: 400, body: Data("{}".utf8))
            }
            store(text, for: vocabularyID)
            return try json([:], status: 201)

        case let .updateInterpretation(recordID):
            let payload = try interpretationPayload(request.body)
            guard let text = payload["interpretation"] as? String,
                  let vocabularyID = vocabularyID(forRecord: recordID)
            else {
                return TransportResponse(status: 400, body: Data("{}".utf8))
            }
            store(text, for: vocabularyID)
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
            stored[identifier] = "n. 演练用旧释义"
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
        guard let text = stored[vocabularyID] else { return [] }
        let number = vocabularyID.dropFirst("REHEARSAL_VOC_".count)
        return [
            [
                "id": "REHEARSAL_REC_\(number)",
                "interpretation": text,
                "tags": CompanionConstants.tags,
                "status": CompanionConstants.status,
            ],
        ]
    }

    private func store(_ text: String, for vocabularyID: String) {
        lock.lock()
        stored[vocabularyID] = text
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

    private func json(_ object: [String: Any], status: Int = 200) throws -> TransportResponse {
        TransportResponse(
            status: status,
            body: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    }
}

#endif
