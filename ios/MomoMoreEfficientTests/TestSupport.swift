import Foundation
import XCTest
@testable import MomoMoreEfficient

let fakeToken = "FAKE_IOS_TEST_TOKEN_NOT_VALID"

enum StubbedResult {
    case response(TransportResponse)
    case failure(CompanionError)
}

final class FakeHTTPTransport: HTTPTransport, @unchecked Sendable {
    var results: [StubbedResult]
    private(set) var requests: [TransportRequest] = []
    var onSend: ((TransportRequest) -> Void)?

    init(_ results: [StubbedResult]) {
        self.results = results
    }

    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse {
        requests.append(request)
        onSend?(request)
        guard !results.isEmpty else {
            XCTFail("unexpected fake transport request")
            throw CompanionError.transport
        }
        switch results.removeFirst() {
        case let .response(response): return response
        case let .failure(error): throw error
        }
    }

    var postCount: Int { requests.filter { $0.route.method == .post }.count }
    var getCount: Int { requests.filter { $0.route.method == .get }.count }
}

final class RecordingSleeper: RequestSleeper, @unchecked Sendable {
    private(set) var seconds: [Double] = []

    func sleep(seconds: Double) async throws {
        self.seconds.append(seconds)
    }
}

actor GateSleeper: RequestSleeper {
    private var entered = false
    private var sleepContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func sleep(seconds: Double) async throws {
        await withCheckedContinuation { continuation in
            sleepContinuation = continuation
            entered = true
            observers.forEach { $0.resume() }
            observers.removeAll()
        }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }

    func resume() {
        sleepContinuation?.resume()
        sleepContinuation = nil
    }
}

func jsonResponse(_ object: Any, status: Int = 200) -> StubbedResult {
    .response(
        TransportResponse(
            status: status,
            body: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        )
    )
}

func vocabularyResponse(_ id: String, _ spelling: String) -> StubbedResult {
    jsonResponse(["voc": ["id": id, "spelling": spelling]])
}

func interpretation(
    _ id: String,
    _ text: String,
    tags: [String] = ["GMAT", "MBA", "BEC"],
    status: String = "PUBLISHED"
) -> [String: Any] {
    ["id": id, "interpretation": text, "tags": tags, "status": status]
}

func interpretationsResponse(_ records: [[String: Any]]) -> StubbedResult {
    jsonResponse(["interpretations": records])
}

func credentialLease(_ token: String = fakeToken) throws -> OperationCredentialLease {
    try InMemoryCredential(token: token).makeOperationLease()
}

func makeSnapshot(
    document: String,
    results: [StubbedResult],
    token: String = fakeToken
) async throws -> (PreviewSnapshot, FakeHTTPTransport, RecordingSleeper) {
    let batch = try BatchParser.parseDailyInput(document)
    let transport = FakeHTTPTransport(results)
    let sleeper = RecordingSleeper()
    let lease = try credentialLease(token)
    let api = MaimemoTransport(transport: transport, credential: lease, sleeper: sleeper)
    let snapshot = try await PreflightPlanner(api: api).buildSnapshot(
        entries: batch.entries,
        credentialFingerprint: lease.fingerprint
    )
    lease.clear()
    return (snapshot, transport, sleeper)
}

struct GoldenFile: Decodable {
    let fakeToken: String
    let credentialFingerprint: String
    let vectors: [GoldenVector]

    enum CodingKeys: String, CodingKey {
        case fakeToken = "fake_token"
        case credentialFingerprint = "credential_fingerprint"
        case vectors
    }
}

struct GoldenVector: Decodable {
    let name: String
    let group: String
    let items: [GoldenItem]
    let batchDigest: String
    let bindingDigest: String
    let confirmation: String

    enum CodingKeys: String, CodingKey {
        case name, group, items, confirmation
        case batchDigest = "batch_digest"
        case bindingDigest = "binding_digest"
    }
}

struct GoldenItem: Decodable {
    let spelling: String
    let interpretation: String
    let vocabularyID: String
    let baseline: GoldenBaseline?

    enum CodingKeys: String, CodingKey {
        case spelling, interpretation, baseline
        case vocabularyID = "vocabulary_id"
    }
}

struct GoldenBaseline: Decodable {
    let recordID: String
    let interpretation: String
    let tags: [String]
    let status: String

    enum CodingKeys: String, CodingKey {
        case interpretation, tags, status
        case recordID = "record_id"
    }
}
