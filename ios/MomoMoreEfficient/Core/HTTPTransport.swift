import Foundation

enum HTTPMethod: String, Equatable, Sendable {
    case get = "GET"
    case post = "POST"
}

enum InterpretationRoute: Equatable, Sendable {
    case credentialValidation
    case vocabulary(spelling: String)
    case interpretations(vocabularyID: String)
    case createInterpretation
    case updateInterpretation(recordID: String)
    case phrases(vocabularyID: String)
    case createPhrase

    var method: HTTPMethod {
        switch self {
        case .credentialValidation, .vocabulary, .interpretations, .phrases:
            return .get
        case .createInterpretation, .updateInterpretation, .createPhrase:
            return .post
        }
    }

    var reviewedPath: String {
        switch self {
        case .credentialValidation:
            // Current official OpenAPI bundle (2026-08-14):
            // GET /open/api/v1/memo/vocabulary?spelling=<word>.
            return "/open/api/v1/memo/vocabulary"
        case .vocabulary:
            return "/open/api/v1/vocabulary"
        case .interpretations:
            return "/open/api/v1/interpretations"
        case .createInterpretation:
            return "/open/api/v1/interpretations"
        case let .updateInterpretation(recordID):
            return "/open/api/v1/interpretations/\(recordID)"
        case .phrases, .createPhrase:
            return "/open/api/v1/phrases"
        }
    }

    func url() throws -> URL {
        var components = URLComponents(
            url: CompanionConstants.productionBaseURL,
            resolvingAgainstBaseURL: false
        )!
        components.path = reviewedPath
        switch self {
        case .credentialValidation:
            // "apple" is the vocabulary example in the official schema. A valid
            // response is checked just as strictly as an ordinary vocabulary read.
            components.queryItems = [URLQueryItem(name: "spelling", value: "apple")]
        case let .vocabulary(spelling):
            guard !spelling.isEmpty else { throw CompanionError.inputRejected }
            components.queryItems = [URLQueryItem(name: "spelling", value: spelling)]
        case let .interpretations(vocabularyID):
            guard isSafeIdentifier(vocabularyID) else { throw CompanionError.responseRejected }
            components.queryItems = [URLQueryItem(name: "voc_id", value: vocabularyID)]
        case let .phrases(vocabularyID):
            guard isSafeIdentifier(vocabularyID) else { throw CompanionError.responseRejected }
            components.queryItems = [URLQueryItem(name: "voc_id", value: vocabularyID)]
        case .createInterpretation, .createPhrase:
            break
        case let .updateInterpretation(recordID):
            guard isSafeIdentifier(recordID) else { throw CompanionError.responseRejected }
        }
        guard let url = components.url,
              url.scheme == "https",
              url.host == "open.maimemo.com",
              url.port == nil
        else {
            throw CompanionError.responseRejected
        }
        return url
    }
}
struct TransportRequest: Equatable, Sendable {
    let route: InterpretationRoute
    let body: Data?

    init(route: InterpretationRoute, body: Data? = nil) throws {
        if route.method == .get, body != nil { throw CompanionError.responseRejected }
        if route.method == .post, body == nil { throw CompanionError.responseRejected }
        _ = try route.url()
        self.route = route
        self.body = body
    }
}

struct TransportResponse: Equatable, Sendable {
    let status: Int
    let body: Data
}

protocol HTTPTransport: AnyObject {
    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse
}

struct ProductionSessionPolicy: Equatable, Sendable {
    let isEphemeral: Bool
    let hasURLCache: Bool
    let hasCookieStorage: Bool
    let hasCredentialStorage: Bool
    let allowsCookies: Bool
    let usesBackgroundSession: Bool
}

private final class LockedRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

final class URLSessionHTTPTransport: HTTPTransport {
    private let delegate: LockedRedirectDelegate
    private let session: URLSession
    let sessionPolicy: ProductionSessionPolicy

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.waitsForConnectivity = false
        delegate = LockedRedirectDelegate()
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        sessionPolicy = ProductionSessionPolicy(
            isEphemeral: configuration.identifier == nil,
            hasURLCache: configuration.urlCache != nil,
            hasCookieStorage: configuration.httpCookieStorage != nil,
            hasCredentialStorage: configuration.urlCredentialStorage != nil,
            allowsCookies: configuration.httpShouldSetCookies,
            usesBackgroundSession: configuration.identifier != nil
        )
    }

    func send(
        _ request: TransportRequest,
        credential: OperationCredentialLease
    ) async throws -> TransportResponse {
        var urlRequest = URLRequest(url: try request.route.url())
        urlRequest.httpMethod = request.route.method.rawValue
        urlRequest.timeoutInterval = 10
        urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.setValue(try credential.authorizationValue(), forHTTPHeaderField: "Authorization")
        if let body = request.body {
            urlRequest.httpBody = body
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        do {
            let (data, response) = try await session.data(for: urlRequest)
            guard data.count <= 1_048_576,
                  let http = response as? HTTPURLResponse,
                  http.url?.scheme == "https",
                  http.url?.host == "open.maimemo.com"
            else {
                throw CompanionError.responseRejected
            }
            return TransportResponse(status: http.statusCode, body: data)
        } catch let error as CompanionError {
            throw error
        } catch {
            throw CompanionError.transport
        }
    }
}
