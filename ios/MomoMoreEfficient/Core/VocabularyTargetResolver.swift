import Foundation

/// Why a requested spelling produced no safe write target.
///
/// Only the two causes the resolver can prove deterministically exist. Anything
/// it cannot classify is not given a reason here at all: a whole-response or
/// transport-level failure stays a global abort, exactly as the per-item read
/// path already behaves.
enum VocabularyResolutionFailure: String, Equatable, Sendable {
    /// The provider returned no record for this exact spelling.
    case notFound
    /// A record came back but could not be uniquely and safely attributed to
    /// this spelling — duplicate identities, or an unsafe identifier.
    case matchAnomaly

    /// The blocked reason stored on a preflight item for this failure.
    var blockedReason: String {
        switch self {
        case .notFound: return "VOCABULARY_NOT_FOUND"
        case .matchAnomaly: return "VOCABULARY_MATCH_ANOMALY"
        }
    }
}

enum VocabularyTargetOutcome: Equatable, Sendable {
    case resolved(vocabularyID: String)
    case blocked(VocabularyResolutionFailure)

    var vocabularyID: String? {
        if case let .resolved(vocabularyID) = self { return vocabularyID }
        return nil
    }

    var blockedReason: String? {
        if case let .blocked(failure) = self { return failure.blockedReason }
        return nil
    }
}

struct VocabularyResolution: Equatable, Sendable {
    /// One outcome per requested spelling, in the caller's own request order.
    /// Provider response order never participates in this alignment.
    let outcomes: [VocabularyTargetOutcome]
}

/// The one shared, fail-closed vocabulary target resolver (#164).
///
/// Interpretation and phrase preflight both resolve their whole batch here
/// before any per-item content read, so a normal N-item Preview costs
/// `ceil(unique spellings / 1000)` vocabulary requests instead of N. Future
/// note/mnemonic support reuses this resolver rather than starting a second
/// target-resolution stack.
///
/// Resolution is batch-first with a bounded single-spelling repair, which is
/// exactly how the official `maimemo/memo-api-cli` splits the two public
/// read-only surfaces (batch query for many spellings, exact GET for one):
///
/// ```text
/// POST /vocabulary/query for every unique spelling
/// -> every safe batch hit is final
/// -> every batch match anomaly stays blocked
/// -> only true batch misses attempt GET /vocabulary?spelling=
/// -> at most one such GET per unique normalized spelling
/// ```
///
/// The fallback exists because a batch-query miss is not proof that the word
/// is unavailable on every public surface: a real, already-existing self-added
/// vocabulary item blocked in an authenticated physical Preview on the
/// query-only design. An all-hit batch — the ordinary Preview — issues no
/// fallback GET at all, so the #167/#168 request shape is unchanged.
///
/// Safety shape — the official resolver's spelling-map pattern, made stricter
/// where this product's write targets require it:
///
/// - targets are bound by validated spelling identity, never by zipping request
///   positions to response positions;
/// - a target is accepted only when exactly one safe identifier is attributable
///   to the requested spelling under the project's normalization;
/// - missing, duplicated, mismatched or unsafe identities fail closed as a
///   blocked item, and no ID is ever guessed;
/// - the fallback may only ever turn a block into a *proven* target; it can
///   never relax one the batch already contradicted, and never invents a
///   provider-specific reason for its own failure;
/// - global transport/auth/rate-limit/server failures still abort the whole
///   read plan exactly as the per-item path does.
///
/// Nothing here classifies a word as built-in or self-added: the public
/// vocabulary shape exposes only `id` and `spelling`, so a safely resolvable
/// self-added word reaches the same write flows as any other word.
struct VocabularyTargetResolver {
    let api: MaimemoTransport

    func resolve(
        spellings: [String],
        control: ExecutionControl? = nil
    ) async throws -> VocabularyResolution {
        guard !spellings.isEmpty else {
            return VocabularyResolution(outcomes: [])
        }

        // Deduplicate by the project's normalization so one provider request
        // never asks for the same target twice, and so two input rows naming the
        // same word can never bind to two different targets.
        var requestOrder: [String] = []
        var requested = Set<String>()
        for spelling in spellings where requested.insert(normalize(spelling)).inserted {
            requestOrder.append(spelling)
        }

        // Transport, authentication, rate-limit, server and whole-response
        // failures propagate, so a broken read still aborts the entire plan
        // exactly as the per-item path does. Nothing here downgrades a global
        // failure into per-item blocks.
        var byNormalized: [String: VocabularyTargetOutcome] = [:]
        for chunk in chunks(of: requestOrder) {
            let records = try await api.vocabularyQuery(spellings: chunk, control: control)
            reconcile(records, requested: chunk, into: &byNormalized)
        }

        // Only a true batch miss may reach the exact GET. A batch hit keeps the
        // target it already proved, and `.matchAnomaly` is a contradiction the
        // batch established: a second read must never be allowed to overwrite it
        // with a more convenient answer. Deduplication above means at most one
        // fallback request per unique normalized spelling, however many input
        // rows named it. A malformed batch response never gets here at all —
        // it threw above, and the whole plan aborted with it.
        for spelling in requestOrder
        where byNormalized[normalize(spelling)] == .blocked(.notFound) {
            byNormalized[normalize(spelling)] = try await exactMatch(
                for: spelling,
                control: control
            )
        }

        return VocabularyResolution(
            outcomes: spellings.map { byNormalized[normalize($0)] ?? .blocked(.notFound) }
        )
    }

    /// Binds returned identities to requested spellings.
    ///
    /// A record whose normalized spelling was not requested is ignored: it
    /// cannot bind any input row, and treating an unknown extra record as a
    /// batch-wide failure would block safe targets on provider behaviour this
    /// project has no evidence about. A requested spelling that no record
    /// matches — including one answered only with a different spelling — simply
    /// stays unresolved and blocks.
    private func reconcile(
        _ records: [VocabularyRecord],
        requested: [String],
        into byNormalized: inout [String: VocabularyTargetOutcome]
    ) {
        let requestedSet = Set(requested.map(normalize))
        for record in records {
            let normalized = normalize(record.spelling)
            guard requestedSet.contains(normalized) else { continue }
            guard isSafeIdentifier(record.id) else {
                byNormalized[normalized] = .blocked(.matchAnomaly)
                continue
            }
            switch byNormalized[normalized] {
            case nil:
                byNormalized[normalized] = .resolved(vocabularyID: record.id)
            case .resolved(let existing) where existing == record.id:
                // An exactly repeated identity is still one unambiguous target.
                continue
            default:
                byNormalized[normalized] = .blocked(.matchAnomaly)
            }
        }
        for normalized in requestedSet where byNormalized[normalized] == nil {
            byNormalized[normalized] = .blocked(.notFound)
        }
    }

    /// One public exact `GET /vocabulary?spelling=`, for one spelling the batch
    /// query returned no record for.
    ///
    /// The transport's existing production validation is the entire acceptance
    /// test: it yields a record only when the response carries a safe
    /// identifier *and* a spelling that normalizes to the one requested. So this
    /// path cannot zip a position, synthesize an id, or bind another word's
    /// record — anything it fails to prove leaves the batch's own `.notFound`
    /// verdict standing, which is the same generic fail-closed outcome the
    /// caller would have shown without the fallback. No new provider-specific
    /// cause is invented, because this build genuinely cannot distinguish "the
    /// provider has no such record" from "the record it sent cannot be safely
    /// attributed": both are `itemResponseRejected`, so both keep the existing
    /// generic `VOCABULARY_NOT_FOUND` presentation rather than a guessed reason.
    private func exactMatch(
        for spelling: String,
        control: ExecutionControl?
    ) async throws -> VocabularyTargetOutcome {
        do {
            let record = try await api.vocabulary(spelling: spelling, control: control)
            return .resolved(vocabularyID: record.id)
        } catch let error as CompanionError where Self.isSpellingScoped(error) {
            return .blocked(.notFound)
        }
    }

    /// Whether a failed exact-GET probe is a fact about this one spelling
    /// rather than about the read plan.
    ///
    /// This is deliberately the same split the per-item vocabulary GET already
    /// used in production before the batch query replaced it (#167): an
    /// item-local rejection blocked that one row, and every `abortsReadPlan`
    /// error stopped the plan. Reusing it verbatim means the fallback adds no
    /// new failure semantics to a route this project has already shipped, and it
    /// keeps every session-wide failure global — a rejected Token, an exhausted
    /// rate-limit window, a server outage, a dead connection, an HTTP refusal,
    /// an envelope this build cannot decode, or cancellation all invalidate
    /// every remaining read, so none of them may be downgraded into a guessed
    /// per-item target.
    private static func isSpellingScoped(_ error: CompanionError) -> Bool {
        switch error {
        case .itemResponseRejected:
            // A 200 whose record is absent, malformed, mismatched or unsafe —
            // the shape this route has always answered an unknown spelling with.
            return true
        case .inputRejected:
            // This spelling cannot even form a legal request URL.
            return true
        default:
            return false
        }
    }

    private func normalize(_ spelling: String) -> String {
        BatchParser.normalizeSpelling(spelling)
    }

    private func chunks(of spellings: [String]) -> [[String]] {
        let size = CompanionConstants.vocabularyQueryChunkSize
        return stride(from: 0, to: spellings.count, by: size).map {
            Array(spellings[$0..<min($0 + size, spellings.count)])
        }
    }
}
