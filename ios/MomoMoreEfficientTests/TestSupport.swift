import Foundation
import XCTest
@testable import MomoMoreEfficient

let fakeToken = "FAKE_IOS_TEST_TOKEN_NOT_VALID"
let legacyTestTags = ["MBA", "BEC", "GMAT"]

func successfulCredentialValidationTransport() -> HTTPTransport {
    FakeHTTPTransport([vocabularyResponse("INVALID_VALIDATION_VOC", "apple")])
}

final class FakeTokenStore: TokenStore, CustomDebugStringConvertible {
    private var token: String?
    private(set) var saveCount = 0
    private(set) var deleteCount = 0

    init(token: String? = nil) {
        self.token = token
    }

    func loadToken() throws -> String? { token }

    func saveToken(_ token: String) throws {
        self.token = token
        saveCount += 1
    }

    func deleteToken() throws {
        token = nil
        deleteCount += 1
    }

    var hasStoredToken: Bool { token != nil }
    var storedTokenForTesting: String? { token }
    var debugDescription: String { "FakeTokenStore(<redacted>)" }
}

enum FakeHistoryStoreError: Error {
    case requestedFailure
}

final class InMemoryHistoryStore: HistoryStore {
    private(set) var receipts: [ExecutionReceipt]
    private(set) var saveCount = 0
    private(set) var clearCount = 0
    private(set) var encodedData: Data?
    var failLoad = false
    var failSave = false
    var failClear = false

    init(receipts: [ExecutionReceipt] = []) {
        self.receipts = receipts
    }

    func loadReceipts() throws -> [ExecutionReceipt] {
        if failLoad { throw FakeHistoryStoreError.requestedFailure }
        return receipts
    }

    func saveReceipts(_ receipts: [ExecutionReceipt]) throws {
        saveCount += 1
        if failSave { throw FakeHistoryStoreError.requestedFailure }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(receipts)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.receipts = try decoder.decode([ExecutionReceipt].self, from: encoded)
        encodedData = encoded
    }

    func clearReceipts() throws {
        clearCount += 1
        if failClear { throw FakeHistoryStoreError.requestedFailure }
        receipts.removeAll()
        encodedData = nil
    }
}

/// Stands in for the OS background-time assertion so lifecycle behaviour can be
/// driven deterministically: `expire()` is the system reclaiming the app.
@MainActor
final class FakeBackgroundExecutionAssertion: BackgroundExecutionAssertion {
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private(set) var reasons: [String] = []
    private var onExpiration: (@Sendable () -> Void)?

    func begin(reason: String, onExpiration: @escaping @Sendable () -> Void) {
        beginCount += 1
        reasons.append(reason)
        self.onExpiration = onExpiration
    }

    func end() {
        endCount += 1
        onExpiration = nil
    }

    /// Simulates iOS reclaiming the granted background time.
    func expire() {
        onExpiration?()
    }

    var isHeld: Bool { onExpiration != nil }
}

/// Captures every `ExecutionStage` an executor reports, in order.
final class StageRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ExecutionStage] = []

    func record(_ stage: ExecutionStage) {
        lock.lock()
        recorded.append(stage)
        lock.unlock()
    }

    var stages: [ExecutionStage] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

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

/// Holds one HTTP response until a test explicitly releases it. This makes the
/// credential-validation UI state observable without timers or real networking.
actor GatedHTTPTransport: HTTPTransport {
    private let result: StubbedResult
    private var responseContinuation: CheckedContinuation<TransportResponse, Error>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var requests: [TransportRequest] = []

    init(_ result: StubbedResult) {
        self.result = result
    }

    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse {
        requests.append(request)
        return try await withCheckedThrowingContinuation { continuation in
            responseContinuation = continuation
            requestWaiters.forEach { $0.resume() }
            requestWaiters.removeAll()
        }
    }

    func waitUntilRequested() async {
        if !requests.isEmpty { return }
        await withCheckedContinuation { requestWaiters.append($0) }
    }

    func resume() {
        guard let continuation = responseContinuation else { return }
        responseContinuation = nil
        switch result {
        case let .response(response): continuation.resume(returning: response)
        case let .failure(error): continuation.resume(throwing: error)
        }
    }

    var getCount: Int { requests.filter { $0.route.method == .get }.count }
    var postCount: Int { requests.filter { $0.route.method == .post }.count }
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

/// Blocks the first paced request until `resume()`, then lets every later request
/// through. `GateSleeper` holds a single continuation, so it can only gate a
/// one-entry run; this variant lets a multi-entry Preview be interrupted part-way
/// and then continue to completion.
actor FirstPauseGateSleeper: RequestSleeper {
    private var entered = false
    private var released = false
    private var sleepContinuation: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []

    func sleep(seconds: Double) async throws {
        if released { return }
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
        released = true
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
    tags: [String] = [],
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
    token: String = fakeToken,
    tags: [String] = []
) async throws -> (PreviewSnapshot, FakeHTTPTransport, RecordingSleeper) {
    let batch = try BatchParser.parseDailyInput(document)
    let transport = FakeHTTPTransport(results)
    let sleeper = RecordingSleeper()
    let lease = try credentialLease(token)
    let api = MaimemoTransport(transport: transport, credential: lease, sleeper: sleeper)
    let snapshot = try await PreflightPlanner(api: api).buildSnapshot(
        entries: batch.entries,
        tags: tags,
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

actor PausingPOSTTransport: HTTPTransport {
    private var results: [StubbedResult]
    private var requests: [TransportRequest] = []
    private var postWasDispatched = false
    private var postWaiters: [CheckedContinuation<Void, Never>] = []
    private var postContinuation: CheckedContinuation<Void, Never>?

    init(_ results: [StubbedResult]) {
        self.results = results
    }

    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse {
        requests.append(request)
        if request.route.method == .post {
            postWasDispatched = true
            postWaiters.forEach { $0.resume() }
            postWaiters.removeAll()
            await withCheckedContinuation { postContinuation = $0 }
        }
        guard !results.isEmpty else {
            XCTFail("unexpected pausing transport request")
            throw CompanionError.transport
        }
        switch results.removeFirst() {
        case let .response(response): return response
        case let .failure(error): throw error
        }
    }

    func waitUntilPOSTDispatched() async {
        if postWasDispatched { return }
        await withCheckedContinuation { postWaiters.append($0) }
    }

    func resumePOST() {
        postContinuation?.resume()
        postContinuation = nil
    }

    var postCount: Int { requests.filter { $0.route.method == .post }.count }
    var getCount: Int { requests.filter { $0.route.method == .get }.count }
}
