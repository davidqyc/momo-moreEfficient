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

/// The narrow read seam the root owner hands to read-only subsystems.
///
/// Batch Query (#161) and the study word export (#155) are each given a
/// transport built from the root owner's credential lease and the *shared*
/// request-window scheduler, plus the account identity the truth they produce
/// belongs to. They deliberately get nothing else: no Keychain access, no
/// `CredentialSession`, no second scheduler, no write authority, and no second
/// transport factory stack. Both take the same `.query` lane, so their reads
/// can never overlap each other or a write.
///
/// `finish()` returns the operation lane and clears the lease. It is idempotent,
/// so the runner can release it on every exit path.
///
/// `reportAuthenticationRejection()` is the other direction of the same seam: a
/// 401 is not a subsystem-local fact, it is the root session's credential being
/// rejected, so the run reports it back to the one root owner instead of holding
/// a failure the root cannot see.
@MainActor
final class QueryReadLease {
    let api: MaimemoTransport
    /// The stable credential fingerprint this run's results belong to. A result
    /// produced under one fingerprint is never shown under another.
    let credentialFingerprint: String

    private let lease: OperationCredentialLease
    private var onFinish: (() -> Void)?
    private var onAuthenticationRejected: (() -> Void)?

    init(
        api: MaimemoTransport,
        credentialFingerprint: String,
        lease: OperationCredentialLease,
        onAuthenticationRejected: @escaping () -> Void = {},
        onFinish: @escaping () -> Void
    ) {
        self.api = api
        self.credentialFingerprint = credentialFingerprint
        self.lease = lease
        self.onAuthenticationRejected = onAuthenticationRejected
        self.onFinish = onFinish
    }

    /// Tells the root session owner that this run's credential was rejected.
    ///
    /// A lease is minted once per run, and this fires at most once per lease, so
    /// one failing run reaches the existing root session-failure path exactly
    /// once. It does not release the lane: the run is still unwinding, and
    /// `finish()` stays the single place that returns it.
    func reportAuthenticationRejection() {
        guard let onAuthenticationRejected else { return }
        self.onAuthenticationRejected = nil
        onAuthenticationRejected()
    }

    func finish() {
        guard let onFinish else { return }
        self.onFinish = nil
        onAuthenticationRejected = nil
        lease.clear()
        onFinish()
    }

    deinit { lease.clear() }
}
