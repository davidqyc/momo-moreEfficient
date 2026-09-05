import Foundation

/// What currently owns the one application-level provider operation lane.
///
/// The shared `RequestWindowScheduler` enforces the documented aggregate request
/// windows. It is a *rate ledger*, not a single-flight proof: two independent
/// callers can each reserve a slot and dispatch concurrently without ever
/// exceeding a window. Batch Query (#161) is the first subsystem that dispatches
/// provider reads outside the write path, so the boundary has to be explicit.
///
/// The rule is simply that these four never overlap:
///
/// ```text
/// credentialValidation   candidate/restored Token validation
/// preview                read-only Preview planning
/// write                  an authorized, already-confirmed write run
/// query                  batch Query's sequential read loop
/// ```
enum ProviderOperationKind: String, Equatable, Sendable {
    case credentialValidation
    case preview
    case write
    case query
}

/// The stable account identity account-derived truth is keyed to.
///
/// Two dimensions, because a fingerprint alone cannot express both rules the
/// adjudication requires:
///
/// - `fingerprint` — the credential currently saved in the Keychain. A
///   background credential suspension, a foreground restore of the same Token,
///   and a 401 that disconnects the session all leave it unchanged, so none of
///   them is an account change.
/// - `authorityGeneration` — advanced only by an **explicit, successful**
///   credential mutation: connect, replacement, or removal. This is what makes
///   a deliberate reconnect after a 401 clear the old Query result even when the
///   Owner re-enters the very same Token, while a failed candidate (which
///   mutates nothing) changes neither dimension.
struct AccountIdentity: Equatable, Sendable {
    var fingerprint: String?
    var authorityGeneration: Int

    static let disconnected = AccountIdentity(fingerprint: nil, authorityGeneration: 0)
}

/// The narrow read seam the root owner hands to the Query subsystem.
///
/// Query is given a transport built from the root owner's credential lease and
/// the *shared* request-window scheduler, plus the account identity the truth it
/// produces belongs to. It deliberately gets nothing else: no Keychain access,
/// no `CredentialSession`, no second scheduler, no write authority, and no
/// second transport factory stack.
///
/// `finish()` returns the operation lane and clears the lease. It is idempotent,
/// so the runner can release it on every exit path.
@MainActor
final class QueryReadLease {
    let api: MaimemoTransport
    /// The stable credential fingerprint this run's results belong to. A result
    /// produced under one fingerprint is never shown under another.
    let credentialFingerprint: String

    private let lease: OperationCredentialLease
    private var onFinish: (() -> Void)?

    init(
        api: MaimemoTransport,
        credentialFingerprint: String,
        lease: OperationCredentialLease,
        onFinish: @escaping () -> Void
    ) {
        self.api = api
        self.credentialFingerprint = credentialFingerprint
        self.lease = lease
        self.onFinish = onFinish
    }

    func finish() {
        guard let onFinish else { return }
        self.onFinish = nil
        lease.clear()
        onFinish()
    }

    deinit { lease.clear() }
}
