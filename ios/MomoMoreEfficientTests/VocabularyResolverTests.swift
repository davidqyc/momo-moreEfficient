import XCTest
@testable import MomoMoreEfficient

/// Issue #164: the one shared batch vocabulary target resolver.
///
/// These tests are the resolver-level half of the frozen #164 contract — safe
/// identity binding, provider-sized chunking, and read-semantic POST accounting.
final class VocabularyResolverTests: XCTestCase {
    private func makeResolver(
        _ results: [StubbedResult]
    ) throws -> (VocabularyTargetResolver, FakeHTTPTransport, RecordingSleeper) {
        let transport = FakeHTTPTransport(results)
        let sleeper = RecordingSleeper()
        let lease = try credentialLease()
        let api = MaimemoTransport(transport: transport, credential: lease, sleeper: sleeper)
        return (VocabularyTargetResolver(api: api), transport, sleeper)
    }

    // MARK: - Identity binding

    func testReorderedResponseStillBindsEachSpellingToItsOwnTarget() async throws {
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([
                (id: "VOC_C", spelling: "cherry"),
                (id: "VOC_A", spelling: "apple"),
                (id: "VOC_B", spelling: "banana"),
            ]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "banana", "cherry"])

        XCTAssertEqual(
            resolution.outcomes,
            [
                .resolved(vocabularyID: "VOC_A"),
                .resolved(vocabularyID: "VOC_B"),
                .resolved(vocabularyID: "VOC_C"),
            ]
        )
        XCTAssertEqual(transport.vocabularyQueryCount, 1)
    }

    func testInputOrderIsPreservedAcrossChunkBoundaries() async throws {
        let spellings = (0..<1_500).map { "word\($0)" }
        let first = spellings.prefix(1_000).map { (id: "VOC_\($0)", spelling: $0) }
        let second = spellings.suffix(500).map { (id: "VOC_\($0)", spelling: $0) }
        let (resolver, transport, _) = try makeResolver([
            // Both chunks answer in reverse order; binding must ignore that.
            vocabularyQueryResponse(first.reversed()),
            vocabularyQueryResponse(second.reversed()),
        ])

        let resolution = try await resolver.resolve(spellings: spellings)

        XCTAssertEqual(
            resolution.outcomes,
            spellings.map { .resolved(vocabularyID: "VOC_\($0)") }
        )
        XCTAssertEqual(transport.vocabularyQueryCount, 2)
    }

    func testMissingSpellingBlocksOnlyThatItem() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([(id: "VOC_A", spelling: "apple")]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "ghostword"])

        XCTAssertEqual(
            resolution.outcomes,
            [.resolved(vocabularyID: "VOC_A"), .blocked(.notFound)]
        )
    }

    func testDuplicateReturnedIdentitiesForOneSpellingBlockIt() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([
                (id: "VOC_A1", spelling: "apple"),
                (id: "VOC_A2", spelling: "Apple"),
            ]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple"])

        XCTAssertEqual(resolution.outcomes, [.blocked(.matchAnomaly)])
    }

    func testRepeatedIdenticalIdentityIsStillOneUnambiguousTarget() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([
                (id: "VOC_A", spelling: "apple"),
                (id: "VOC_A", spelling: "apple"),
            ]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple"])

        XCTAssertEqual(resolution.outcomes, [.resolved(vocabularyID: "VOC_A")])
    }

    func testMismatchedReturnedSpellingNeverBindsTheRequestedRow() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([(id: "VOC_OTHER", spelling: "banana")]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple"])

        XCTAssertEqual(resolution.outcomes, [.blocked(.notFound)])
        XCTAssertNil(resolution.outcomes[0].vocabularyID)
    }

    func testUnsafeIdentifierIsADistinguishableAnomalyNotASilentMiss() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([(id: "VOC/../A", spelling: "apple")]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple"])

        XCTAssertEqual(resolution.outcomes, [.blocked(.matchAnomaly)])
    }

    func testDuplicateRequestedSpellingsResolveToTheSameTargetInOneRequest() async throws {
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([(id: "VOC_A", spelling: "apple")]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "APPLE"])

        XCTAssertEqual(
            resolution.outcomes,
            [.resolved(vocabularyID: "VOC_A"), .resolved(vocabularyID: "VOC_A")]
        )
        XCTAssertEqual(transport.vocabularyQueryCount, 1)
        let body = try XCTUnwrap(transport.requests.first?.body)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(payload["spellings"] as? [String], ["apple"])
        XCTAssertEqual((payload["ids"] as? [String])?.isEmpty, true)
    }

    // MARK: - Chunking

    func testSingleItemUsesExactlyOneQueryRequest() async throws {
        let (resolver, transport, _) = try makeResolver([resolvedQueryResponse(["apple"])])

        _ = try await resolver.resolve(spellings: ["apple"])

        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.vocabularyQueryCount, 1)
        XCTAssertEqual(transport.getCount, 0)
    }

    func testProviderMaximumStillUsesOneRequest() async throws {
        let spellings = (0..<1_000).map { "word\($0)" }
        let (resolver, transport, _) = try makeResolver([resolvedQueryResponse(spellings)])

        let resolution = try await resolver.resolve(spellings: spellings)

        XCTAssertEqual(transport.vocabularyQueryCount, 1)
        XCTAssertEqual(resolution.outcomes.count, 1_000)
        XCTAssertTrue(resolution.outcomes.allSatisfy { $0.vocabularyID != nil })
    }

    func testOneOverProviderMaximumUsesTwoChunkedRequests() async throws {
        let spellings = (0..<1_001).map { "word\($0)" }
        let (resolver, transport, _) = try makeResolver([
            resolvedQueryResponse(Array(spellings.prefix(1_000))),
            resolvedQueryResponse(Array(spellings.suffix(1))),
        ])

        let resolution = try await resolver.resolve(spellings: spellings)

        XCTAssertEqual(transport.vocabularyQueryCount, 2)
        XCTAssertEqual(
            transport.requests.map { request -> Int in
                let payload = try! JSONSerialization.jsonObject(with: request.body!)
                return ((payload as! [String: Any])["spellings"] as! [String]).count
            },
            [1_000, 1]
        )
        XCTAssertTrue(resolution.outcomes.allSatisfy { $0.vocabularyID != nil })
    }

    func testResolutionScalesByChunkNotByItemCount() async throws {
        for (itemCount, expectedRequests) in [(1, 1), (8, 1), (15, 1), (31, 1), (2_500, 3)] {
            let spellings = (0..<itemCount).map { "word\($0)" }
            let responses = stride(from: 0, to: itemCount, by: 1_000).map { start in
                resolvedQueryResponse(
                    Array(spellings[start..<min(start + 1_000, itemCount)])
                )
            }
            let (resolver, transport, _) = try makeResolver(responses)

            _ = try await resolver.resolve(spellings: spellings)

            XCTAssertEqual(
                transport.requests.count,
                expectedRequests,
                "\(itemCount) items must cost \(expectedRequests) vocabulary requests"
            )
            XCTAssertEqual(transport.getCount, 0, "no per-item vocabulary GET fallback")
        }
    }

    // MARK: - Read semantics

    func testVocabularyQueryIsReadSemanticAndNeverAMutatingPOST() async throws {
        let (resolver, transport, _) = try makeResolver([resolvedQueryResponse(["apple"])])

        _ = try await resolver.resolve(spellings: ["apple"])

        let route = try XCTUnwrap(transport.requests.first?.route)
        XCTAssertEqual(route.method, .post)
        XCTAssertFalse(route.isMutating)
        XCTAssertEqual(route.reviewedPath, "/open/api/v1/vocabulary/query")
        XCTAssertEqual(transport.httpPOSTCount, 1)
        XCTAssertEqual(transport.postCount, 0, "a read-semantic POST is never a write")
    }

    func testVocabularyQueryNeverConsumesTheOnePOSTPerItemAllowance() async throws {
        let (resolver, _, _) = try makeResolver([resolvedQueryResponse(["apple"])])
        let control = ExecutionControl()

        _ = try await resolver.resolve(spellings: ["apple"], control: control)

        XCTAssertTrue(control.beginPostIfAllowed(), "the write allowance is untouched")
    }

    func testResolutionIsPacedLikeEveryOtherRequest() async throws {
        let spellings = (0..<1_001).map { "word\($0)" }
        let (resolver, _, sleeper) = try makeResolver([
            resolvedQueryResponse(Array(spellings.prefix(1_000))),
            resolvedQueryResponse(Array(spellings.suffix(1))),
        ])

        _ = try await resolver.resolve(spellings: spellings)

        XCTAssertEqual(sleeper.seconds, [CompanionConstants.pacingSeconds])
    }

    func testCancellationStopsResolutionWithoutFabricatingTargets() async throws {
        let (resolver, transport, _) = try makeResolver([resolvedQueryResponse(["apple"])])
        let control = ExecutionControl()
        control.requestCancellation()

        do {
            _ = try await resolver.resolve(spellings: ["apple"], control: control)
            XCTFail("cancellation must propagate")
        } catch {
            XCTAssertEqual(error as? CompanionError, .cancelled)
        }
        XCTAssertEqual(transport.requests.count, 0)
    }

    // MARK: - Global vs. item-local failure

    func testAuthenticationFailureStaysGlobal() async throws {
        let (resolver, _, _) = try makeResolver([jsonResponse([:], status: 401)])

        do {
            _ = try await resolver.resolve(spellings: ["apple", "banana"])
            XCTFail("a 401 must abort the whole read plan")
        } catch {
            XCTAssertEqual(error as? CompanionError, .authenticationRejected)
        }
    }

    func testRateLimitAndServerFailuresStayGlobal() async throws {
        for (status, expected) in [(429, CompanionError.rateLimited), (503, .serverFailure)] {
            let (resolver, _, _) = try makeResolver([jsonResponse([:], status: status)])
            do {
                _ = try await resolver.resolve(spellings: ["apple"])
                XCTFail("HTTP \(status) must abort the whole read plan")
            } catch {
                XCTAssertEqual(error as? CompanionError, expected)
            }
        }
    }

    func testTransportFailureStaysGlobal() async throws {
        let (resolver, _, _) = try makeResolver([.failure(.transport)])

        do {
            _ = try await resolver.resolve(spellings: ["apple"])
            XCTFail("a transport failure must abort the whole read plan")
        } catch {
            XCTAssertEqual(error as? CompanionError, .transport)
        }
    }

    // MARK: - Response envelope

    func testMalformedResponseStaysGlobalAndNeverFallsBackToPerItemGETs() async throws {
        let malformed: [Any] = [
            ["unexpected": "shape"],
            [String: String](),
            ["voc_list": "not an array"],
        ]
        for envelope in malformed {
            let (resolver, transport, _) = try makeResolver([jsonResponse(envelope)])
            do {
                _ = try await resolver.resolve(spellings: ["apple", "banana"])
                XCTFail("a malformed query response must abort the whole read plan")
            } catch {
                XCTAssertEqual(error as? CompanionError, .responseRejected)
            }
            XCTAssertEqual(transport.getCount, 0, "no silent per-item GET fallback")
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    func testEmptyResultSetBlocksEveryRequestedSpelling() async throws {
        let (resolver, _, _) = try makeResolver([vocabularyQueryResponse([])])

        let resolution = try await resolver.resolve(spellings: ["apple", "banana"])

        XCTAssertEqual(resolution.outcomes, [.blocked(.notFound), .blocked(.notFound)])
    }

    func testDocumentedEnvelopeVariantsAreAccepted() async throws {
        let record = ["id": "VOC_A", "spelling": "apple"]
        let envelopes: [Any] = [
            ["voc_list": [record]],
            ["vocabularies": [record]],
            ["data": ["voc_list": [record]]],
            ["data": [record]],
            [record],
        ]
        for envelope in envelopes {
            let (resolver, _, _) = try makeResolver([jsonResponse(envelope)])
            let resolution = try await resolver.resolve(spellings: ["apple"])
            XCTAssertEqual(resolution.outcomes, [.resolved(vocabularyID: "VOC_A")])
            }
    }
}

/// Issue #164: what the shared resolver changes for a real Preview — request
/// cost, target binding, and the write-safety floor that must not move.
final class PreflightThroughputTests: XCTestCase {
    private func interpretationDocument(_ count: Int) -> String {
        (0..<count).map { "word\($0)\nn. 释义\($0)" }.joined(separator: "\n\n")
    }

    private func phraseDocument(_ count: Int) -> String {
        (0..<count).map {
            "word\($0)\nThe word\($0) appeared again\n第\($0)个词又出现了"
        }.joined(separator: "\n\n")
    }

    private func emptyPhrases() -> StubbedResult { jsonResponse(["phrases": [Any]()]) }

    private func targets(_ spellings: [String]) -> StubbedResult {
        vocabularyQueryResponse(spellings.map { (id: "INVALID_VOC_\($0)", spelling: $0) })
    }

    private func plan(
        _ document: String,
        contentReads: (Int) -> StubbedResult
    ) async throws -> (PreviewSnapshot, FakeHTTPTransport, RecordingSleeper) {
        let entries = try BatchParser.parseDailyInput(document).entries
        let transport = FakeHTTPTransport(
            [targets(entries.map(\.spelling))] + entries.indices.map(contentReads)
        )
        let sleeper = RecordingSleeper()
        let lease = try credentialLease()
        defer { lease.clear() }
        let snapshot = try await PreflightPlanner(
            api: MaimemoTransport(transport: transport, credential: lease, sleeper: sleeper)
        ).buildSnapshot(entries: entries, tags: [], credentialFingerprint: lease.fingerprint)
        return (snapshot, transport, sleeper)
    }

    // MARK: - Request cost

    /// The acceptance measurement: vocabulary resolution costs
    /// `ceil(unique spellings / 1000)` requests, not one per item. Total
    /// preflight cost therefore drops from `2N` to `N + 1`.
    func testInterpretationPreflightCostsOneVocabularyRequestPlusOneReadPerItem() async throws {
        for count in [1, 8, 15, 31, 120] {
            let (snapshot, transport, sleeper) = try await plan(interpretationDocument(count)) { _ in
                interpretationsResponse([])
            }

            XCTAssertEqual(snapshot.presentation.counts.create, count)
            XCTAssertEqual(transport.vocabularyQueryCount, 1, "\(count) items")
            XCTAssertEqual(transport.getCount, count, "one content read per item")
            XCTAssertEqual(transport.requests.count, count + 1, "\(count) items")
            XCTAssertEqual(transport.postCount, 0, "Preview dispatches no mutation")
            // Pacing policy is unchanged: every request after the first still
            // waits the existing 1.6s floor.
            XCTAssertEqual(sleeper.seconds, Array(repeating: 1.6, count: count))
        }
    }

    func testPhrasePreflightUsesTheSameSharedResolver() async throws {
        for count in [1, 8, 15, 31] {
            let entries = try PhraseBatchParser.parse(phraseDocument(count))
            let transport = FakeHTTPTransport(
                [targets(entries.map(\.spelling))] + entries.map { _ in emptyPhrases() }
            )
            let lease = try credentialLease()
            defer { lease.clear() }
            let snapshot = try await PhrasePreflightPlanner(
                api: MaimemoTransport(
                    transport: transport,
                    credential: lease,
                    sleeper: RecordingSleeper()
                )
            ).buildSnapshot(entries: entries, tags: [], credentialFingerprint: lease.fingerprint)

            XCTAssertEqual(snapshot.items.map(\.classification), Array(repeating: .create, count: count))
            XCTAssertEqual(transport.vocabularyQueryCount, 1, "\(count) items")
            XCTAssertEqual(transport.requests.count, count + 1, "\(count) items")
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    /// A batch past the old 30-item cap now runs the whole way from pasted text
    /// to a bound, executable plan.
    func testBatchBeyondTheOldCapPreflightsAndBindsEveryTarget() async throws {
        let count = 45
        let (snapshot, transport, _) = try await plan(interpretationDocument(count)) { _ in
            interpretationsResponse([])
        }

        XCTAssertEqual(snapshot.items.count, count)
        XCTAssertEqual(
            snapshot.items.map(\.vocabularyID),
            (0..<count).map { "INVALID_VOC_word\($0)" },
            "each row keeps its own resolved target, in input order"
        )
        XCTAssertEqual(transport.requests.count, count + 1)

        let plan = try ConfirmationBinding.makePlan(snapshot: snapshot, group: .create)
        XCTAssertEqual(plan.items.count, count)
        XCTAssertEqual(plan.items.map(\.spelling), (0..<count).map { "word\($0)" })
    }

    // MARK: - Target binding and write safety

    func testEachRowBindsItsOwnTargetEvenWhenTheProviderReordersTheResponse() async throws {
        let entries = try BatchParser.parseDailyInput(interpretationDocument(3)).entries
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([
                (id: "INVALID_VOC_C", spelling: "word2"),
                (id: "INVALID_VOC_A", spelling: "word0"),
                (id: "INVALID_VOC_B", spelling: "word1"),
            ]),
            interpretationsResponse([]),
            interpretationsResponse([]),
            interpretationsResponse([]),
        ])
        let lease = try credentialLease()
        defer { lease.clear() }
        let snapshot = try await PreflightPlanner(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).buildSnapshot(entries: entries, tags: [], credentialFingerprint: lease.fingerprint)

        XCTAssertEqual(
            snapshot.items.map(\.vocabularyID),
            ["INVALID_VOC_A", "INVALID_VOC_B", "INVALID_VOC_C"]
        )
        // Each content read used its own row's resolved target.
        XCTAssertEqual(
            transport.requests.dropFirst().map(\.route),
            [
                .interpretations(vocabularyID: "INVALID_VOC_A"),
                .interpretations(vocabularyID: "INVALID_VOC_B"),
                .interpretations(vocabularyID: "INVALID_VOC_C"),
            ]
        )
    }

    func testResolverBlockedItemCannotGainWriteAuthorization() async throws {
        let entries = try BatchParser.parseDailyInput(interpretationDocument(2)).entries
        let transport = FakeHTTPTransport([
            // "word1" comes back with an unsafe identifier; "word0" resolves.
            vocabularyQueryResponse([
                (id: "INVALID_VOC_A", spelling: "word0"),
                (id: "INVALID/../VOC", spelling: "word1"),
            ]),
            interpretationsResponse([]),
        ])
        let lease = try credentialLease()
        defer { lease.clear() }
        let snapshot = try await PreflightPlanner(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).buildSnapshot(entries: entries, tags: [], credentialFingerprint: lease.fingerprint)

        XCTAssertEqual(snapshot.items.map(\.classification), [.create, .blocked])
        XCTAssertEqual(snapshot.items[1].reason, "VOCABULARY_MATCH_ANOMALY")
        XCTAssertNil(snapshot.items[1].vocabularyID)
        XCTAssertEqual(
            snapshot.presentation.rows[1].compactBlockedReason,
            "词条目标匹配异常"
        )

        // The blocked row is absent from every authorizable plan.
        let plan = try ConfirmationBinding.makePlan(snapshot: snapshot, group: .create)
        XCTAssertEqual(plan.items.map(\.spelling), ["word0"])
        XCTAssertThrowsError(try ConfirmationBinding.makePlan(snapshot: snapshot, group: .update))
        XCTAssertEqual(transport.postCount, 0)
    }

    func testUnknownBlockedReasonsFallBackToTheGenericWording() {
        let row = PreviewRow(
            ordinal: 1,
            spelling: "word",
            classification: .blocked,
            current: nil,
            proposed: "n. 释义",
            currentTags: nil,
            proposedTags: nil,
            reason: "SOMETHING_THIS_BUILD_CANNOT_EXPLAIN"
        )
        XCTAssertEqual(row.compactBlockedReason, "其他无法安全读取")
    }

    /// The execution-time fresh preflight goes through the same resolver, so a
    /// target that no longer resolves to the approved ID stops the run.
    func testFreshPreflightRequiresTheExactApprovedTarget() async throws {
        let entries = try BatchParser.parseDailyInput(interpretationDocument(1)).entries
        let lease = try credentialLease()
        defer { lease.clear() }
        let previewTransport = FakeHTTPTransport([
            targets(["word0"]),
            interpretationsResponse([]),
        ])
        let snapshot = try await PreflightPlanner(
            api: MaimemoTransport(
                transport: previewTransport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).buildSnapshot(entries: entries, tags: [], credentialFingerprint: lease.fingerprint)
        let approval = try ConfirmationBinding.makeApproval(snapshot: snapshot, group: .create)

        let executionTransport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC_MOVED", spelling: "word0")]),
            interpretationsResponse([]),
        ])
        let summary = await WriteExecutor(
            api: MaimemoTransport(
                transport: executionTransport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).execute(
            group: .create,
            displayedSnapshot: snapshot,
            approval: approval,
            control: ExecutionControl()
        )

        XCTAssertTrue(summary.stalePreview)
        XCTAssertEqual(executionTransport.postCount, 0, "a moved target sends no write")
    }
}

