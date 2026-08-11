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

    var credentialFingerprint: String { credential.fingerprint }

    init(
        transport: HTTPTransport,
        credential: OperationCredentialLease,
        sleeper: RequestSleeper = ProductionRequestSleeper()
    ) {
        self.transport = transport
        self.credential = credential
        self.sleeper = sleeper
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
        let container = (object["voc"] != nil ? object : object["data"] as? [String: Any])
        guard let voc = container?["voc"] as? [String: Any],
              let id = voc["id"] as? String,
              let returned = voc["spelling"] as? String,
              isSafeIdentifier(id),
              BatchParser.normalizeSpelling(returned) == BatchParser.normalizeSpelling(spelling)
        else {
            throw CompanionError.responseRejected
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
                throw CompanionError.responseRejected
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
                  let origin = safeSingleLine(value["origin"], maximumCharacters: 256),
                  let status = value["status"] as? String,
                  documentedPhraseStatuses.contains(status)
            else {
                throw CompanionError.responseRejected
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
        guard (200..<300).contains(response.status) else {
            throw CompanionError.responseRejected
        }
        return response
    }

    private func pace() async throws {
        if dispatchedRequest {
            try await sleeper.sleep(seconds: CompanionConstants.pacingSeconds)
        }
        dispatchedRequest = true
    }

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= 1_048_576,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CompanionError.responseRejected
        }
        return object
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

    private func phraseTags(_ record: [String: Any]) throws -> [String]? {
        guard let raw = record["tags"] else { return nil }
        guard let tags = raw as? [String],
              tags.count <= documentedTags.count,
              tags.allSatisfy({ documentedTags.contains($0) })
        else {
            throw CompanionError.responseRejected
        }
        return tags
    }

    private func phraseHighlight(
        _ record: [String: Any],
        phraseLength: Int
    ) throws -> PhraseHighlight {
        guard let raw = record["highlight"] else { return .missing }
        guard let values = raw as? [Any] else { throw CompanionError.responseRejected }
        if values.isEmpty {
            return .ranges(shape: .emptyArray, values: [])
        }

        if values.allSatisfy({ $0 is [String: Any] }) {
            let ranges = try values.map { value -> PhraseRange in
                guard let object = value as? [String: Any] else {
                    throw CompanionError.responseRejected
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
                    throw CompanionError.responseRejected
                }
                return try checkedRange(
                    start: pair[0],
                    end: pair[1],
                    phraseLength: phraseLength
                )
            }
            return .ranges(shape: .integerPairArray, values: ranges)
        }

        throw CompanionError.responseRejected
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
            throw CompanionError.responseRejected
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
    private let documentedPhraseStatuses = ["PUBLISHED", "DELETED"]
    private let documentedTags = [
        "简明", "详细", "英英", "小学", "初中", "高中", "四级", "六级", "专升本",
        "专四", "专八", "考研", "考博", "雅思", "托福", "托业", "新概念", "法学",
        "医学", "GRE", "GMAT", "BEC", "MBA", "SAT", "ACT",
    ]
}
