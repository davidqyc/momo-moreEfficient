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
    case clean
    case uncertain
}

final class MaimemoTransport {
    private let transport: HTTPTransport
    private let credential: OperationCredentialLease
    private let sleeper: RequestSleeper
    private var dispatchedRequest = false

    init(
        transport: HTTPTransport,
        credential: OperationCredentialLease,
        sleeper: RequestSleeper = ProductionRequestSleeper()
    ) {
        self.transport = transport
        self.credential = credential
        self.sleeper = sleeper
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

    func post(
        route: InterpretationRoute,
        body: Data,
        control: ExecutionControl
    ) async -> PostDispatchResult {
        do {
            guard route.method == .post else { return .notDispatched }
            try await pace()
            guard control.beginPostIfAllowed() else { return .notDispatched }
            let request = try TransportRequest(route: route, body: body)
            do {
                let response = try await transport.send(request, credential: credential)
                return (200..<300).contains(response.status) ? .clean : .uncertain
            } catch {
                return .uncertain
            }
        } catch {
            return .notDispatched
        }
    }

    private func read(
        route: InterpretationRoute,
        control: ExecutionControl?,
        readback: Bool
    ) async throws -> TransportResponse {
        guard route.method == .get else { throw CompanionError.responseRejected }
        if let control {
            let allowed = readback
                ? control.allowsInFlightReadback()
                : control.allowsPreflightRequest()
            guard allowed else { throw CompanionError.cancelled }
        }
        try await pace()
        if let control {
            let allowed = readback
                ? control.allowsInFlightReadback()
                : control.allowsPreflightRequest()
            guard allowed else { throw CompanionError.cancelled }
        }
        let request = try TransportRequest(route: route)
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

    private func pace() async throws {
        if dispatchedRequest {
            try await sleeper.sleep(seconds: CompanionConstants.pacingSeconds)
        }
        dispatchedRequest = true
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
