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
/// Safety shape — the official resolver's spelling-map pattern, made stricter
/// where this product's write targets require it:
///
/// - targets are bound by validated spelling identity, never by zipping request
///   positions to response positions;
/// - a target is accepted only when exactly one safe identifier is attributable
///   to the requested spelling under the project's normalization;
/// - missing, duplicated, mismatched or unsafe identities fail closed as a
///   blocked item, and no ID is ever guessed;
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
