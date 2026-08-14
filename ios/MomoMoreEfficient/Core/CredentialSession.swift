import CryptoKit
import Foundation

final class InMemoryCredential: CustomDebugStringConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    let fingerprint: String

    init(token: String) throws {
        let normalized = Self.normalize(token)
        guard !normalized.isEmpty,
              normalized.unicodeScalars.count <= CompanionConstants.maxTokenCharacters,
              !containsDisallowedControlCharacter(normalized, allowingNewline: false)
        else {
            throw CompanionError.credentialRejected
        }
        self.token = normalized
        self.fingerprint = SHA256.hash(data: Data(normalized.utf8)).hexPrefix(16)
    }

    static func normalize(_ token: String) -> String {
        token.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func makeOperationLease() throws -> OperationCredentialLease {
        lock.lock()
        defer { lock.unlock() }
        guard let token else { throw CompanionError.notConnected }
        return OperationCredentialLease(token: token, fingerprint: fingerprint)
    }

    func clear() {
        lock.lock()
        token = nil
        lock.unlock()
    }

    var isValid: Bool {
        lock.lock()
        defer { lock.unlock() }
        return token != nil
    }
    var debugDescription: String { "InMemoryCredential(<redacted>)" }
}

final class OperationCredentialLease: CustomDebugStringConvertible, @unchecked Sendable {
    private let lock = NSLock()
    private var token: String?
    let fingerprint: String

    fileprivate init(token: String, fingerprint: String) {
        self.token = token
        self.fingerprint = fingerprint
    }

    func authorizationValue() throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let token else { throw CompanionError.notConnected }
        return "Bearer \(token)"
    }

    func clear() {
        lock.lock()
        token = nil
        lock.unlock()
    }

    var debugDescription: String { "OperationCredentialLease(<redacted>)" }
}

final class CredentialSession: CustomDebugStringConvertible {
    private var credential: InMemoryCredential?

    func connect(token: String) throws {
        replace(with: try InMemoryCredential(token: token))
    }

    func replace(with replacement: InMemoryCredential) {
        let previous = credential
        credential = replacement
        previous?.clear()
    }

    func disconnect() {
        credential?.clear()
        credential = nil
    }

    func makeOperationLease() throws -> OperationCredentialLease {
        guard let credential else { throw CompanionError.notConnected }
        return try credential.makeOperationLease()
    }

    var fingerprint: String? { credential?.fingerprint }
    var isConnected: Bool { credential?.isValid == true }
    var debugDescription: String { "CredentialSession(<memory-only>)" }
}

extension SHA256.Digest {
    func hexPrefix(_ count: Int) -> String {
        prefix(count / 2).map { String(format: "%02x", $0) }.joined()
    }
}
