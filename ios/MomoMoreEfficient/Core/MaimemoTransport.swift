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

    private let documentedStatuses = ["PUBLISHED", "UNPUBLISHED", "DELETED"]
    private let documentedTags = [
        "简明", "详细", "英英", "小学", "初中", "高中", "四级", "六级", "专升本",
        "专四", "专八", "考研", "考博", "雅思", "托福", "托业", "新概念", "法学",
        "医学", "GRE", "GMAT", "BEC", "MBA", "SAT", "ACT",
    ]
}
