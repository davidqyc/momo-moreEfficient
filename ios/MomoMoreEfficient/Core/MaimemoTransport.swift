import Foundation

protocol RequestSleeper: Sendable {
    func sleep(seconds: Double) async throws
}

struct ProductionRequestSleeper: RequestSleeper {
    func sleep(seconds: Double) async throws {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

enum PostDispatchResult: Equatable {
    case notDispatched
    case clean2xx(status: Int)
    case httpRejected(status: Int)
    case transportFailure(errorCategory: PostSendFailureCategory)

    var isClean2xx: Bool {
        if case .clean2xx = self { return true }
        return false
    }

    var diagnosticCategory: PostDispatchCategory {
        switch self {
        case .notDispatched: return .notDispatched
        case let .clean2xx(status): return .clean2xx(status: status)
        case let .httpRejected(status): return .httpRejected(status: status)
        case let .transportFailure(category):
            return .transportFailure(errorCategory: category)
        }
    }
}

final class MaimemoTransport {
    private let transport: HTTPTransport
    private let credential: OperationCredentialLease
    private let sleeper: RequestSleeper
    private let scheduler: RequestWindowScheduler

    init(
        transport: HTTPTransport,
        credential: OperationCredentialLease,
        sleeper: RequestSleeper = ProductionRequestSleeper(),
        scheduler: RequestWindowScheduler = RequestWindowScheduler()
    ) {
        self.transport = transport
        self.credential = credential
        self.sleeper = sleeper
        self.scheduler = scheduler
    }

    /// Reuse the production-proven vocabulary route and decoder. "apple" is a
    /// stable probe only for credential validation; no second route/schema exists.
    func validateCredential() async throws {
        do {
            _ = try await vocabulary(spelling: "apple")
        } catch CompanionError.itemResponseRejected {
            // A missing/malformed probe record does not prove a bad Token, but it
            // also cannot establish authenticated connection truth.
            throw CompanionError.responseRejected
        }
    }

    func vocabulary(
        spelling: String,
        control: ExecutionControl? = nil
    ) async throws -> VocabularyRecord {
        let response = try await read(
            route: .vocabulary(spelling: spelling),
            control: control,
            readback: false
        )
        let object = try jsonObject(response.body)
        let container: [String: Any]
        if object["voc"] != nil {
            container = object
        } else if let data = object["data"] as? [String: Any] {
            container = data
        } else if object.isEmpty {
            throw CompanionError.itemResponseRejected
        } else {
            throw CompanionError.responseRejected
        }
        guard let voc = container["voc"] as? [String: Any],
              let id = voc["id"] as? String,
              let returned = voc["spelling"] as? String,
              isSafeIdentifier(id),
              BatchParser.normalizeSpelling(returned) == BatchParser.normalizeSpelling(spelling)
        else {
            throw CompanionError.itemResponseRejected
        }
        return VocabularyRecord(id: id, spelling: returned)
    }

    /// The public batch vocabulary lookup used by #164's shared target resolver.
    ///
    /// HTTP POST with read/query semantics: it resolves existing vocabulary
    /// targets and writes nothing, so it goes through `read` and is excluded
    /// from mutating-POST accounting by `InterpretationRoute.isMutating`.
    ///
    /// Only response *schema* is judged here. Identity safety — exact spelling
    /// attribution, uniqueness and a safe identifier — belongs to the resolver,
    /// so an unsafe identifier stays a distinguishable per-item anomaly instead
    /// of collapsing into "malformed response".
    func vocabularyQuery(
        spellings: [String],
        control: ExecutionControl? = nil
    ) async throws -> [VocabularyRecord] {
        guard !spellings.isEmpty,
              spellings.count <= CompanionConstants.vocabularyQueryChunkSize
        else {
            throw CompanionError.inputRejected
        }
        let body = try JSONSerialization.data(
            withJSONObject: ["spellings": spellings, "ids": []],
            options: [.sortedKeys]
        )
        let response = try await read(
            route: .vocabularyQuery,
            body: body,
            control: control,
            readback: false
        )
        return try decodeVocabularyList(response.body)
    }

    private func decodeVocabularyList(_ data: Data) throws -> [VocabularyRecord] {
        guard data.count <= 1_048_576,
              let root = try? JSONSerialization.jsonObject(with: data)
        else {
            throw CompanionError.responseRejected
        }
        guard let values = Self.vocabularyArray(in: root),
              values.count <= CompanionConstants.vocabularyQueryChunkSize
        else {
            throw CompanionError.responseRejected
        }
        return try values.map { value in
            guard let record = value as? [String: Any],
                  let id = record["id"] as? String,
                  let spelling = record["spelling"] as? String
            else {
                throw CompanionError.responseRejected
            }
            return VocabularyRecord(id: id, spelling: spelling)
        }
    }

    /// Locates the vocabulary array in the first-party batch-query envelope.
    ///
    /// The official `maimemo/memo-api-cli` transport (`src/client.ts`) reads a
    /// successful body as `{ errors, data, success }` and returns `data`, and its
    /// vocabulary-query test models the raw body as `{ data: { voc: [...] } }`.
    /// So the list lives at `data.voc`; the unwrapped `voc` form is the same
    /// one-level `data` tolerance the production vocabulary, interpretation and
    /// phrase decoders already apply. No other key or shape is accepted, so an
    /// unrecognised envelope stays a malformed response and can never let a
    /// record be synthesised from a guess.
    private static func vocabularyArray(in root: Any) -> [Any]? {
        guard let object = root as? [String: Any] else { return nil }
        let container = (object["voc"] != nil ? object : object["data"] as? [String: Any])
        return container?["voc"] as? [Any]
    }

    func interpretations(
        vocabularyID: String,
        control: ExecutionControl? = nil,
        readback: Bool = false
    ) async throws -> [InterpretationRecord] {
        let response = try await read(
            route: .interpretations(vocabularyID: vocabularyID),
            control: control,
            readback: readback
        )
        let object = try jsonObject(response.body)
        let container = (object["interpretations"] != nil
            ? object
            : object["data"] as? [String: Any])
        guard let records = container?["interpretations"] as? [[String: Any]] else {
            throw CompanionError.responseRejected
        }
        var seen = Set<String>()
        return try records.map { value in
            guard let id = value["id"] as? String,
                  isSafeIdentifier(id),
                  seen.insert(id).inserted,
                  let interpretation = value["interpretation"] as? String,
                  !interpretation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  interpretation.unicodeScalars.count <= CompanionConstants.maxInterpretationCharacters,
                  !containsDisallowedControlCharacter(interpretation, allowingNewline: true),
                  let tags = value["tags"] as? [String],
                  tags.count <= documentedTags.count,
                  tags.allSatisfy({ documentedTags.contains($0) }),
                  let status = value["status"] as? String,
                  documentedStatuses.contains(status)
            else {
                throw CompanionError.itemResponseRejected
            }
            return InterpretationRecord(
                id: id,
                interpretation: interpretation,
                tags: tags,
                status: status
            )
        }
    }

    func phrases(
        vocabularyID: String,
        control: ExecutionControl? = nil,
        readback: Bool = false
    ) async throws -> [PhraseRecord] {
        let response = try await read(
            route: .phrases(vocabularyID: vocabularyID),
            control: control,
            readback: readback
        )
        let object = try jsonObject(response.body)
        let container = (object["phrases"] != nil
            ? object
            : object["data"] as? [String: Any])
        guard let values = container?["phrases"] as? [[String: Any]] else {
            throw CompanionError.responseRejected
        }

        var seen = Set<String>()
        return try values.map { value in
            guard let id = value["id"] as? String,
                  isSafeIdentifier(id),
                  seen.insert(id).inserted,
                  let phrase = safeSingleLine(
                    value["phrase"],
                    maximumCharacters: CompanionConstants.maxInterpretationCharacters
                  ),
                  let interpretation = safeSingleLine(
                    value["interpretation"],
                    maximumCharacters: CompanionConstants.maxInterpretationCharacters
                  ),
                  let origin = safeOrigin(value["origin"]),
                  let status = value["status"] as? String,
                  reviewedPhraseStatuses.contains(status)
            else {
                throw CompanionError.itemResponseRejected
            }
            return PhraseRecord(
                id: id,
                phrase: phrase,
                interpretation: interpretation,
                tags: try phraseTags(value),
                origin: origin,
                status: status,
                highlight: try phraseHighlight(value, phraseLength: phrase.unicodeScalars.count)
            )
        }
    }

    /// The strict read-only notes list used by batch Query (#161).
    ///
    /// Deliberately the smallest possible extension of this transport family: the
    /// same authenticated path, the same shared scheduler, the same one-level
    /// `data` envelope tolerance the vocabulary/interpretation/phrase decoders
    /// already apply, and the same fail-closed rule — an unrecognised envelope is
    /// a whole-response rejection, and an unrecognised record is an item
    /// rejection. There is no notes mutation route, and nothing here is ever
    /// guessed or synthesised.
    ///
    /// Records are returned *whole*, including `DELETED` ones. Deciding what
    /// counts is Query's own pure projection, never this shared transport
    /// (adjudication finding 7).
    func notes(
        vocabularyID: String,
        control: ExecutionControl? = nil
    ) async throws -> [NoteRecord] {
        let response = try await read(
            route: .notes(vocabularyID: vocabularyID),
            control: control,
            readback: false
        )
        let object = try jsonObject(response.body)
        let container = (object["notes"] != nil
            ? object
            : object["data"] as? [String: Any])
        guard let values = container?["notes"] as? [[String: Any]] else {
            throw CompanionError.responseRejected
        }

        var seen = Set<String>()
        return try values.map { value in
            guard let id = value["id"] as? String,
                  isSafeIdentifier(id),
                  seen.insert(id).inserted,
                  let noteType = safeSingleLine(value["note_type"], maximumCharacters: 64),
                  let note = value["note"] as? String,
                  !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  note.unicodeScalars.count <= CompanionConstants.maxInterpretationCharacters,
                  !containsDisallowedControlCharacter(note, allowingNewline: true),
                  let status = value["status"] as? String,
                  NoteRecord.documentedStatuses.contains(status)
            else {
                throw CompanionError.itemResponseRejected
            }
            return NoteRecord(id: id, noteType: noteType, note: note, status: status)
        }
    }

    func post(
        route: InterpretationRoute,
        body: Data,
        control: ExecutionControl
    ) async -> PostDispatchResult {
        do {
            // Mutation semantics, not the HTTP verb: a read-semantic POST such
            // as the batch vocabulary query must never reach one-POST-per-item
            // accounting, approval authorization or write retry policy.
            guard route.isMutating else { return .notDispatched }
            let ticket = try await pace { control.isCancellationRequested }
            // Every exit below this point must resolve `ticket`: `confirmDispatch`
            // right before the real send, or (via this defer) `cancelReservation`
            // for any path that ends up not dispatching after all.
            var dispatched = false
            defer { if !dispatched { scheduler.cancelReservation(ticket) } }
            guard control.beginPostIfAllowed() else { return .notDispatched }
            let request = try TransportRequest(route: route, body: body)
            dispatched = true
            scheduler.confirmDispatch(ticket)
            do {
                let response = try await transport.send(request, credential: credential)
                return (200..<300).contains(response.status)
                    ? .clean2xx(status: response.status)
                    : .httpRejected(status: response.status)
            } catch {
                return .transportFailure(
                    errorCategory: PostSendFailureCategory(error: error)
                )
            }
        } catch {
            return .notDispatched
        }
    }

    private func read(
        route: InterpretationRoute,
        body: Data? = nil,
        control: ExecutionControl?,
        readback: Bool
    ) async throws -> TransportResponse {
        guard !route.isMutating else { throw CompanionError.responseRejected }
        if let control {
            let allowed = readback
                ? control.allowsInFlightReadback()
                : control.allowsPreflightRequest()
            guard allowed else { throw CompanionError.cancelled }
        }
        let ticket = try await pace {
            guard let control else { return false }
            return readback ? !control.allowsInFlightReadback() : !control.allowsPreflightRequest()
        }
        // Every exit below this point must resolve `ticket`: `confirmDispatch`
        // right before the real send, or (via this defer) `cancelReservation`
        // for any path that ends up not dispatching after all.
        var dispatched = false
        defer { if !dispatched { scheduler.cancelReservation(ticket) } }
        if let control {
            let allowed = readback
                ? control.allowsInFlightReadback()
                : control.allowsPreflightRequest()
            guard allowed else { throw CompanionError.cancelled }
        }
        let request = try TransportRequest(route: route, body: body)
        dispatched = true
        scheduler.confirmDispatch(ticket)
        let response = try await transport.send(request, credential: credential)
        try Self.validateReadStatus(response.status)
        return response
    }

    private static func validateReadStatus(_ status: Int) throws {
        if status == 200 { return }
        if (200..<300).contains(status) { throw CompanionError.responseRejected }
        switch status {
        case 401:
            throw CompanionError.authenticationRejected
        case 429:
            throw CompanionError.rateLimited
        case 500...599:
            throw CompanionError.serverFailure
        default:
            throw CompanionError.globalHTTPFailure
        }
    }

    /// The largest single wait `pace()` performs before re-checking
    /// `shouldAbort`. A real aggregate-window wait can run as long as the
    /// longest configured window (currently Maimemo's 5-hour ceiling);
    /// chunking keeps a cancellation or background timeout from going
    /// unnoticed that long.
    private static let maxPaceCheckInterval: TimeInterval = 1

    /// This transport instance's very first paced call never sleeps when the
    /// real window has room (`wait == 0`), matching the pre-#168 behavior a
    /// fresh `MaimemoTransport` always had for its opening request. A real
    /// window constraint (`wait > 0`) still waits even on that first call —
    /// only the artificial, unconditional floor is gone.
    private var dispatchedRequest = false

    /// `shouldAbort` must mirror the exact allowance check the caller already
    /// makes right after `pace()` returns (`allowsInFlightReadback()` for a
    /// readback, `allowsPreflightRequest()` for an ordinary read, plain
    /// `isCancellationRequested` for a not-yet-dispatched POST) — never a
    /// bare cancellation flag, or a mandatory post-POST readback that must
    /// proceed despite cancellation would be wrongly aborted mid-wait.
    ///
    /// Returns the scheduler's reservation ticket for the caller to resolve:
    /// `confirmDispatch(_:)` right before the real send, `cancelReservation(_:)`
    /// if it turns out not to send after all. A wait aborted here (`shouldAbort`,
    /// or the sleeper itself throwing) already cancels the reservation before
    /// rethrowing, so it never reaches the caller with a live ticket to resolve.
    private func pace(shouldAbort: () -> Bool) async throws -> RequestWindowScheduler.ReservationTicket {
        let (wait, ticket) = scheduler.reserveNextSlot()
        let isOpeningRequest = !dispatchedRequest
        dispatchedRequest = true
        guard !isOpeningRequest || wait > 0 else { return ticket }
        var remaining = wait
        do {
            repeat {
                if shouldAbort() {
                    throw CompanionError.cancelled
                }
                let step = min(remaining, Self.maxPaceCheckInterval)
                try await sleeper.sleep(seconds: step)
                remaining -= step
            } while remaining > 0
        } catch {
            scheduler.cancelReservation(ticket)
            throw error
        }
        return ticket
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576 else {
            throw CompanionError.responseRejected
        }
        do {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw CompanionError.responseRejected
            }
            return object
        } catch let error as CompanionError {
            throw error
        } catch {
            throw CompanionError.responseRejected
        }
    }

    private func safeSingleLine(_ value: Any?, maximumCharacters: Int) -> String? {
        guard let value = value as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.unicodeScalars.count <= maximumCharacters,
              !containsDisallowedControlCharacter(value, allowingNewline: false)
        else {
            return nil
        }
        return value
    }

    /// The documented origin field must always be present and String-typed. An
    /// exact empty string is the no-source representation from Issue #87; other
    /// non-empty values retain the existing safe single-line validation.
    private func safeOrigin(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        if value.isEmpty { return value }
        return safeSingleLine(value, maximumCharacters: 256)
    }

    private func phraseTags(_ record: [String: Any]) throws -> [String]? {
        guard let raw = record["tags"] else { return nil }
        guard let tags = raw as? [String],
              tags.count <= documentedTags.count,
              tags.allSatisfy({ documentedTags.contains($0) })
        else {
            throw CompanionError.itemResponseRejected
        }
        return tags
    }

    private func phraseHighlight(
        _ record: [String: Any],
        phraseLength: Int
    ) throws -> PhraseHighlight {
        guard let raw = record["highlight"] else { return .missing }
        guard let values = raw as? [Any] else { throw CompanionError.itemResponseRejected }
        if values.isEmpty {
            return .ranges(shape: .emptyArray, values: [])
        }

        if values.allSatisfy({ $0 is [String: Any] }) {
            let ranges = try values.map { value -> PhraseRange in
                guard let object = value as? [String: Any] else {
                    throw CompanionError.itemResponseRejected
                }
                return try checkedRange(
                    start: object["start"],
                    end: object["end"],
                    phraseLength: phraseLength
                )
            }
            return .ranges(shape: .objectRangeArray, values: ranges)
        }

        if values.allSatisfy({ $0 is [Any] }) {
            let ranges = try values.map { value -> PhraseRange in
                guard let pair = value as? [Any], pair.count == 2 else {
                    throw CompanionError.itemResponseRejected
                }
                return try checkedRange(
                    start: pair[0],
                    end: pair[1],
                    phraseLength: phraseLength
                )
            }
            return .ranges(shape: .integerPairArray, values: ranges)
        }

        throw CompanionError.itemResponseRejected
    }

    private func checkedRange(
        start: Any?,
        end: Any?,
        phraseLength: Int
    ) throws -> PhraseRange {
        guard let start = strictInteger(start),
              let end = strictInteger(end),
              0 <= start,
              start < end,
              end <= phraseLength
        else {
            throw CompanionError.itemResponseRejected
        }
        return PhraseRange(start: start, end: end)
    }

    private func strictInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else {
            return nil
        }
        let integerTypes = Set(["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"])
        guard integerTypes.contains(String(cString: number.objCType)) else { return nil }
        return number.intValue
    }

    private let documentedStatuses = ["PUBLISHED", "UNPUBLISHED", "DELETED"]
    private let reviewedPhraseStatuses = ["PUBLISHED", "DELETED"]
    private let documentedTags = [
        "简明", "详细", "英英", "小学", "初中", "高中", "四级", "六级", "专升本",
        "专四", "专八", "考研", "考博", "雅思", "托福", "托业", "新概念", "法学",
        "医学", "GRE", "GMAT", "BEC", "MBA", "SAT", "ACT",
    ]
}
