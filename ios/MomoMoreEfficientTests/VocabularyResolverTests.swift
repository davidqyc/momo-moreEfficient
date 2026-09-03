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
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([(id: "VOC_A", spelling: "apple")]),
            // The batch miss now gets one exact-GET attempt, which proves nothing.
            unresolvableVocabularyResponse(),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "ghostword"])

        XCTAssertEqual(
            resolution.outcomes,
            [.resolved(vocabularyID: "VOC_A"), .blocked(.notFound)]
        )
        XCTAssertEqual(transport.getCount, 1, "only the missed spelling is retried")
        XCTAssertEqual(
            transport.requests.last?.route,
            .vocabulary(spelling: "ghostword")
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
            // A batch answered only with another word is a true miss, so the
            // exact GET is attempted — and it must not bind that word either.
            vocabularyResponse("VOC_OTHER", "banana"),
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
            transport.requests.map { requestedSpellings(in: $0).count },
            [1_000, 1]
        )
        XCTAssertTrue(resolution.outcomes.allSatisfy { $0.vocabularyID != nil })
    }

    /// The spellings a recorded request actually asked for. Reading them through
    /// optionals keeps a stub-shape mistake a readable failure instead of a
    /// runtime trap that would take the whole test host down with it (#164 R1).
    private func requestedSpellings(in request: TransportRequest) -> [String] {
        guard let body = request.body,
              let payload = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let spellings = payload["spellings"] as? [String]
        else {
            XCTFail("a vocabulary-query request must carry a spellings payload")
            return []
        }
        return spellings
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

    /// #168: pacing goes through the shared aggregate-window scheduler now,
    /// not a fixed per-request floor. The second chunk request stays far
    /// under every documented window, so it pays no artificial wait either —
    /// but it still calls through the sleeper (with 0 seconds), same as the
    /// old fixed-floor pacing always did for every request after the first.
    func testResolutionIsPacedLikeEveryOtherRequest() async throws {
        let spellings = (0..<1_001).map { "word\($0)" }
        let (resolver, _, sleeper) = try makeResolver([
            resolvedQueryResponse(Array(spellings.prefix(1_000))),
            resolvedQueryResponse(Array(spellings.suffix(1))),
        ])

        _ = try await resolver.resolve(spellings: spellings)

        XCTAssertEqual(sleeper.seconds, [0])
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
        let record = ["id": "VOC_A", "spelling": "apple"]
        let malformed: [Any] = [
            ["unexpected": "shape"],
            [String: String](),
            // `voc` present but not a list.
            ["voc": "not an array"],
            ["data": ["voc": ["id": "VOC_A", "spelling": "apple"]]],
            // Envelope present, `voc` missing.
            ["data": ["errors": [], "success": true]],
            ["errors": [], "success": true],
            // Wrapper nested more deeply than the first-party contract.
            ["data": ["data": ["voc": [record]]]],
            // Shapes the earlier draft guessed at; no first-party source shows
            // them, so they must now fail closed rather than bind a target.
            ["voc_list": [record]],
            ["vocabularies": [record]],
            ["data": ["items": [record]]],
            ["data": [record]],
            [record],
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
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([]),
            unresolvableVocabularyResponse(),
            unresolvableVocabularyResponse(),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "banana"])

        XCTAssertEqual(resolution.outcomes, [.blocked(.notFound), .blocked(.notFound)])
        XCTAssertEqual(transport.getCount, 2, "one exact GET per missed spelling")
    }

    /// The exact raw body the official `maimemo/memo-api-cli` vocabulary-query
    /// integration test models — `wrap({ voc: [...] })` — plus the unwrapped
    /// `voc` form this project's existing one-level `data` tolerance already
    /// covers for the single-vocabulary, interpretation and phrase reads.
    func testFirstPartyRawWrapperShapeIsDecoded() async throws {
        let voc = [
            ["id": "VOC_A", "spelling": "apple"],
            ["id": "VOC_B", "spelling": "banana"],
        ]
        let envelopes: [Any] = [
            ["data": ["voc": voc], "errors": [], "success": true],
            ["voc": voc],
        ]
        for envelope in envelopes {
            let (resolver, transport, _) = try makeResolver([jsonResponse(envelope)])
            let resolution = try await resolver.resolve(spellings: ["apple", "banana"])
            XCTAssertEqual(
                resolution.outcomes,
                [.resolved(vocabularyID: "VOC_A"), .resolved(vocabularyID: "VOC_B")]
            )
            XCTAssertEqual(transport.vocabularyQueryCount, 1)
            XCTAssertEqual(transport.getCount, 0)
        }
    }

    /// The envelope correction must not soften record-level validation: the
    /// resolver, not the decoder, still owns identity safety.
    func testFirstPartyWrapperStillFailsClosedOnUnsafeOrAmbiguousIdentity() async throws {
        let unsafe: [Any] = [
            // Malformed record inside a well-formed wrapper: whole response bad.
            ["data": ["voc": [["id": "VOC_A"]]], "errors": [], "success": true],
            ["data": ["voc": [["id": 7, "spelling": "apple"]]], "errors": [], "success": true],
        ]
        for envelope in unsafe {
            let (resolver, _, _) = try makeResolver([jsonResponse(envelope)])
            do {
                _ = try await resolver.resolve(spellings: ["apple"])
                XCTFail("a malformed record must abort the whole read plan")
            } catch {
                XCTAssertEqual(error as? CompanionError, .responseRejected)
            }
        }

        // Per-item anomalies stay per-item, inside the first-party wrapper. Only
        // the true miss is allowed a fallback attempt; the anomalies must not
        // reach one at all, so they are stubbed with no second response.
        let cases: [(String, [[String: String]], VocabularyTargetOutcome, [StubbedResult])] = [
            ("unsafe id", [["id": "bad/id", "spelling": "apple"]], .blocked(.matchAnomaly), []),
            (
                "two identities",
                [["id": "VOC_A", "spelling": "apple"], ["id": "VOC_B", "spelling": "Apple"]],
                .blocked(.matchAnomaly),
                []
            ),
            (
                "mismatched spelling",
                [["id": "VOC_A", "spelling": "apricot"]],
                .blocked(.notFound),
                [unresolvableVocabularyResponse()]
            ),
        ]
        for (label, voc, expected, fallback) in cases {
            let envelope: [String: Any] = ["data": ["voc": voc], "errors": [], "success": true]
            let (resolver, transport, _) = try makeResolver([jsonResponse(envelope)] + fallback)
            let resolution = try await resolver.resolve(spellings: ["apple"])
            XCTAssertEqual(resolution.outcomes, [expected], label)
            XCTAssertEqual(transport.getCount, fallback.count, label)
        }
    }
}

/// Issue #164: the batch-miss exact-GET fallback.
///
/// An authenticated physical-iPhone Preview on the query-only design blocked a
/// real, already-existing self-added vocabulary item, so a batch-query miss is
/// no longer treated as proof that the word is unresolvable. These tests pin
/// the repair's two halves: the ordinary all-hit batch must not pay for it, and
/// the fallback must never bind a target it cannot prove. Each one fails under
/// the old query-only resolver.
final class VocabularyExactGETFallbackTests: XCTestCase {
    private func makeResolver(
        _ results: [StubbedResult]
    ) throws -> (VocabularyTargetResolver, FakeHTTPTransport) {
        let transport = FakeHTTPTransport(results)
        let api = MaimemoTransport(
            transport: transport,
            credential: try credentialLease(),
            sleeper: RecordingSleeper()
        )
        return (VocabularyTargetResolver(api: api), transport)
    }

    /// The self-added word the batch query omits. Nothing in the resolver knows
    /// or cares that it is self-added; it is simply the spelling the batch has
    /// no record for.
    private let selfAdded = "ownwordonly"

    // MARK: - 1 / 8. The fast path must not move

    func testAllHitBatchIssuesNoFallbackGET() async throws {
        for count in [1, 8, 15, 31] {
            let spellings = (0..<count).map { "word\($0)" }
            let (resolver, transport) = try makeResolver([resolvedQueryResponse(spellings)])

            let resolution = try await resolver.resolve(spellings: spellings)

            XCTAssertEqual(
                resolution.outcomes,
                spellings.map { .resolved(vocabularyID: "VOC_\($0.uppercased())") },
                "\(count) items"
            )
            XCTAssertEqual(transport.vocabularyQueryCount, 1, "\(count) items")
            XCTAssertEqual(transport.getCount, 0, "an all-hit batch pays for no fallback")
            XCTAssertEqual(transport.requests.count, 1, "\(count) items")
        }
    }

    /// Request-shape regression guard: only genuine misses add requests, and
    /// they add exactly one each.
    func testOnlyActualMissesAddFallbackRequests() async throws {
        for (count, missCount) in [(8, 1), (15, 2), (15, 0)] {
            let spellings = (0..<count).map { "word\($0)" }
            let hits = spellings.dropLast(missCount)
            let (resolver, transport) = try makeResolver(
                [resolvedQueryResponse(Array(hits))]
                    + Array(repeating: unresolvableVocabularyResponse(), count: missCount)
            )

            _ = try await resolver.resolve(spellings: spellings)

            XCTAssertEqual(transport.vocabularyQueryCount, 1, "\(count)/\(missCount)")
            XCTAssertEqual(transport.getCount, missCount, "\(count)/\(missCount)")
            XCTAssertEqual(transport.requests.count, 1 + missCount, "\(count)/\(missCount)")
        }
    }

    // MARK: - 2. A batch miss the exact GET can prove

    func testBatchMissResolvesThroughExactlyOneExactGET() async throws {
        let (resolver, transport) = try makeResolver([
            vocabularyQueryResponse([
                (id: "VOC_A", spelling: "apple"),
                (id: "VOC_B", spelling: "banana"),
            ]),
            vocabularyResponse("VOC_SELF", selfAdded),
        ])

        let resolution = try await resolver.resolve(
            spellings: ["apple", selfAdded, "banana"]
        )

        XCTAssertEqual(
            resolution.outcomes,
            [
                .resolved(vocabularyID: "VOC_A"),
                .resolved(vocabularyID: "VOC_SELF"),
                .resolved(vocabularyID: "VOC_B"),
            ],
            "the missed spelling binds the exact GET's own id; batch hits are untouched"
        )
        XCTAssertEqual(transport.getCount, 1)
        XCTAssertEqual(
            transport.requests.map(\.route),
            [.vocabularyQuery, .vocabulary(spelling: selfAdded)],
            "only the missed spelling is asked for again"
        )
        XCTAssertEqual(transport.postCount, 0, "the fallback consumes no write authority")
    }

    /// The fallback is a GET on the public exact route, so it stays read-only
    /// and keeps drawing from the one shared aggregate-window ledger (#168).
    func testFallbackIsAReadOnlyGETOnThePublicExactRoute() async throws {
        let (resolver, transport) = try makeResolver([
            vocabularyQueryResponse([]),
            vocabularyResponse("VOC_SELF", selfAdded),
        ])

        _ = try await resolver.resolve(spellings: [selfAdded])

        let route = try XCTUnwrap(transport.requests.last?.route)
        XCTAssertEqual(route.method, .get)
        XCTAssertFalse(route.isMutating)
        XCTAssertEqual(route.reviewedPath, "/open/api/v1/vocabulary")
        XCTAssertNil(transport.requests.last?.body)
    }

    func testFallbackNeverConsumesTheOnePOSTPerItemAllowance() async throws {
        let (resolver, _) = try makeResolver([
            vocabularyQueryResponse([]),
            vocabularyResponse("VOC_SELF", selfAdded),
        ])
        let control = ExecutionControl()

        _ = try await resolver.resolve(spellings: [selfAdded], control: control)

        XCTAssertTrue(control.beginPostIfAllowed(), "the write allowance is untouched")
    }

    // MARK: - 3. Duplicate input rows naming one missed spelling

    func testDuplicateMissedSpellingsShareOneFallbackGETAndOneProvenTarget() async throws {
        let (resolver, transport) = try makeResolver([
            vocabularyQueryResponse([]),
            vocabularyResponse("VOC_SELF", selfAdded),
        ])

        let resolution = try await resolver.resolve(
            spellings: [selfAdded, selfAdded.uppercased(), selfAdded]
        )

        XCTAssertEqual(
            resolution.outcomes,
            Array(repeating: .resolved(vocabularyID: "VOC_SELF"), count: 3),
            "every row naming the same word aligns to the same proven target"
        )
        XCTAssertEqual(transport.getCount, 1, "one GET per unique normalized spelling")
        XCTAssertEqual(transport.requests.count, 2)
    }

    // MARK: - 4. A contradiction the batch already proved

    func testBatchMatchAnomalyIsNeverRetriedOrOverridden() async throws {
        let anomalies: [(String, [(id: String, spelling: String)])] = [
            ("unsafe identifier", [(id: "VOC/../SELF", spelling: "ownword")]),
            (
                "two identities for one spelling",
                [(id: "VOC_1", spelling: "ownword"), (id: "VOC_2", spelling: "OwnWord")]
            ),
        ]
        for (label, records) in anomalies {
            // No fallback response is stubbed: reaching the GET at all fails.
            let (resolver, transport) = try makeResolver([vocabularyQueryResponse(records)])

            let resolution = try await resolver.resolve(spellings: ["ownword"])

            XCTAssertEqual(resolution.outcomes, [.blocked(.matchAnomaly)], label)
            XCTAssertEqual(transport.getCount, 0, label)
        }
    }

    // MARK: - 5. A batch response this build cannot decode

    func testMalformedBatchResponseStillAbortsGloballyWithNoSilentFallback() async throws {
        let malformed: [Any] = [
            ["unexpected": "shape"],
            ["data": ["errors": [], "success": true]],
            ["data": ["voc": [["id": "VOC_A"]]]],
        ]
        for envelope in malformed {
            let (resolver, transport) = try makeResolver([jsonResponse(envelope)])
            do {
                _ = try await resolver.resolve(spellings: ["apple", selfAdded])
                XCTFail("a malformed batch response must abort the whole read plan")
            } catch {
                XCTAssertEqual(error as? CompanionError, .responseRejected)
            }
            XCTAssertEqual(transport.getCount, 0, "no silent fallback after a broken batch")
        }
    }

    // MARK: - 6. A fallback answer that proves nothing

    func testFallbackNeverBindsAnIdentityItCannotProve() async throws {
        let unprovable: [(String, StubbedResult)] = [
            ("no record at all", unresolvableVocabularyResponse()),
            ("another word's record", vocabularyResponse("VOC_OTHER", "someotherword")),
            ("unsafe identifier", vocabularyResponse("VOC/../SELF", "ownwordonly")),
            ("record without a spelling", jsonResponse(["voc": ["id": "VOC_SELF"]])),
            ("record without an id", jsonResponse(["voc": ["spelling": "ownwordonly"]])),
            ("non-string identifier", jsonResponse(["voc": ["id": 7, "spelling": "ownwordonly"]])),
        ]
        for (label, response) in unprovable {
            let (resolver, transport) = try makeResolver([
                vocabularyQueryResponse([(id: "VOC_A", spelling: "apple")]),
                response,
            ])

            let resolution = try await resolver.resolve(spellings: ["apple", selfAdded])

            XCTAssertEqual(
                resolution.outcomes,
                [.resolved(vocabularyID: "VOC_A"), .blocked(.notFound)],
                label
            )
            XCTAssertNil(resolution.outcomes[1].vocabularyID, label)
            XCTAssertEqual(
                resolution.outcomes[1].blockedReason,
                "VOCABULARY_NOT_FOUND",
                "\(label): the truthful generic outcome, not a guessed provider cause"
            )
            XCTAssertEqual(transport.getCount, 1, label)
        }
    }

    // MARK: - 7. Global failures during the fallback

    func testAuthRateLimitServerAndTransportFailuresDuringFallbackStayGlobal() async throws {
        let failures: [(StubbedResult, CompanionError)] = [
            (jsonResponse([:], status: 401), .authenticationRejected),
            (jsonResponse([:], status: 429), .rateLimited),
            (jsonResponse([:], status: 503), .serverFailure),
            (jsonResponse([:], status: 404), .globalHTTPFailure),
            (.failure(.transport), .transport),
            // An envelope this build cannot decode is not a per-spelling fact.
            (jsonResponse(["errors": ["nope"], "success": false]), .responseRejected),
        ]
        for (response, expected) in failures {
            let (resolver, transport) = try makeResolver([
                vocabularyQueryResponse([(id: "VOC_A", spelling: "apple")]),
                response,
                // A second miss must never be reached once the plan is aborted.
                vocabularyResponse("VOC_SELF", "anotherownword"),
            ])
            do {
                _ = try await resolver.resolve(
                    spellings: ["apple", selfAdded, "anotherownword"]
                )
                XCTFail("\(expected) during fallback must abort the whole read plan")
            } catch {
                XCTAssertEqual(error as? CompanionError, expected)
            }
            XCTAssertEqual(transport.getCount, 1, "\(expected) stops the remaining fallbacks")
        }
    }

    func testCancellationDuringFallbackStopsWithoutFabricatingATarget() async throws {
        let (resolver, transport) = try makeResolver([
            vocabularyQueryResponse([(id: "VOC_A", spelling: "apple")]),
            vocabularyResponse("VOC_SELF", selfAdded),
        ])
        let control = ExecutionControl()
        // Cancel the moment the batch query is dispatched, so cancellation lands
        // between the batch and the fallback GET.
        transport.onSend = { request in
            if request.route == .vocabularyQuery { control.requestCancellation() }
        }

        do {
            _ = try await resolver.resolve(spellings: ["apple", selfAdded], control: control)
            XCTFail("cancellation must propagate")
        } catch {
            XCTAssertEqual(error as? CompanionError, .cancelled)
        }
        XCTAssertEqual(transport.getCount, 0, "a cancelled plan sends no fallback GET")
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
            // #168: pacing goes through the shared aggregate-window scheduler
            // now, but the opening request on a fresh transport is still free
            // (same as the old fixed-floor pacing). This only holds exactly
            // for counts that stay under the real 20-request/10s window; once
            // a real wait is chunked, `sleeper.sleep()` is called more than
            // once per paced request, which is exactly what
            // RequestWindowSchedulerTests covers, not this request-cost test.
            if count < 20 {
                XCTAssertEqual(sleeper.seconds.count, count, "\(count) items")
            }
        }
    }

    /// #168 acceptance fixtures, run through the real Preview pipeline (not
    /// the isolated scheduler): an 8-item interpretation Preview costs 9
    /// requests and a 15-item one costs 16 — both previously paid the old
    /// blanket `1.6s * (requestCount - 1)` floor (~12.8s / ~24.0s per the
    /// Issue's own #167 measurement). Both now stay under the 20-request/10s
    /// window, so real Preview traffic pays zero artificial wait.
    func testRepresentative8And15ItemPreviewsMaterializeTheThroughputFix() async throws {
        for count in [8, 15] {
            let (_, transport, sleeper) = try await plan(interpretationDocument(count)) { _ in
                interpretationsResponse([])
            }
            XCTAssertEqual(transport.requests.count, count + 1, "\(count) items")
            let totalWait = sleeper.seconds.reduce(0, +)
            let oldFixedFloor = 1.6 * Double(count)
            XCTAssertEqual(totalWait, 0, "\(count) items")
            XCTAssertLessThan(totalWait, oldFixedFloor, "\(count) items")
        }
    }

    /// #164 repair, end to end through both real preflight pipelines: a spelling
    /// the batch query misses but the exact GET can prove becomes an ordinary,
    /// executable row — and both modes get that from the one shared resolver, so
    /// no mode-specific fallback implementation exists to drift apart.
    func testBothPreflightModesResolveABatchMissThroughTheOneSharedResolver() async throws {
        let lease = try credentialLease()
        defer { lease.clear() }

        // Interpretation: "word1" is missing from the batch answer.
        let entries = try BatchParser.parseDailyInput(interpretationDocument(3)).entries
        let interpretationTransport = FakeHTTPTransport([
            vocabularyQueryResponse([
                (id: "INVALID_VOC_0", spelling: "word0"),
                (id: "INVALID_VOC_2", spelling: "word2"),
            ]),
            vocabularyResponse("INVALID_VOC_SELF", "word1"),
            interpretationsResponse([]),
            interpretationsResponse([]),
            interpretationsResponse([]),
        ])
        let snapshot = try await PreflightPlanner(
            api: MaimemoTransport(
                transport: interpretationTransport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).buildSnapshot(entries: entries, tags: [], credentialFingerprint: lease.fingerprint)

        XCTAssertEqual(
            snapshot.items.map(\.classification),
            [.create, .create, .create],
            "the batch-missed row is no longer blocked"
        )
        XCTAssertEqual(
            snapshot.items.map(\.vocabularyID),
            ["INVALID_VOC_0", "INVALID_VOC_SELF", "INVALID_VOC_2"]
        )
        XCTAssertEqual(
            interpretationTransport.requests.prefix(2).map(\.route),
            [.vocabularyQuery, .vocabulary(spelling: "word1")]
        )
        XCTAssertEqual(
            interpretationTransport.requests.dropFirst(2).map(\.route),
            [
                .interpretations(vocabularyID: "INVALID_VOC_0"),
                .interpretations(vocabularyID: "INVALID_VOC_SELF"),
                .interpretations(vocabularyID: "INVALID_VOC_2"),
            ],
            "each row reads content through its own resolved target"
        )
        XCTAssertEqual(interpretationTransport.postCount, 0)

        // Phrase: the same repair, through the same resolver, no second stack.
        let phraseEntries = try PhraseBatchParser.parse(phraseDocument(2))
        let phraseTransport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC_0", spelling: "word0")]),
            vocabularyResponse("INVALID_VOC_SELF", "word1"),
            emptyPhrases(),
            emptyPhrases(),
        ])
        let phraseSnapshot = try await PhrasePreflightPlanner(
            api: MaimemoTransport(
                transport: phraseTransport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        ).buildSnapshot(
            entries: phraseEntries,
            tags: [],
            credentialFingerprint: lease.fingerprint
        )

        XCTAssertEqual(phraseSnapshot.items.map(\.classification), [.create, .create])
        XCTAssertEqual(
            phraseSnapshot.items.map(\.vocabularyID),
            ["INVALID_VOC_0", "INVALID_VOC_SELF"]
        )
        XCTAssertEqual(
            phraseTransport.requests.prefix(2).map(\.route),
            [.vocabularyQuery, .vocabulary(spelling: "word1")]
        )
        XCTAssertEqual(phraseTransport.postCount, 0)
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

