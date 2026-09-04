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
            // #164: the true miss gets one Study repair, which proves nothing.
            studyRecordsResponse([]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "ghostword"])

        XCTAssertEqual(
            resolution.outcomes,
            [.resolved(vocabularyID: "VOC_A"), .blocked(.notFound)]
        )
        XCTAssertEqual(transport.studyRecordsQueryCount, 1)
        XCTAssertEqual(
            transport.studyRecordsBodies.first?["spellings"] as? [String],
            ["ghostword"],
            "the resolved spelling must never be re-asked on the Study surface"
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
            studyRecordsResponse([]),
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
            XCTAssertEqual(
                transport.studyRecordsQueryCount,
                0,
                "an all-hit batch adds no Study traffic"
            )
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

    // MARK: - Study-Records repair (#164)

    /// The ordinary Preview. An all-hit batch must stay exactly the #167/#168
    /// shape: no Study request exists to be paid for.
    func testAllHitBatchesIssueZeroStudyRequests() async throws {
        for count in [1, 8, 15, 31] {
            let spellings = (0..<count).map { "word\($0)" }
            let (resolver, transport, _) = try makeResolver([resolvedQueryResponse(spellings)])

            let resolution = try await resolver.resolve(spellings: spellings)

            XCTAssertTrue(resolution.outcomes.allSatisfy { $0.vocabularyID != nil })
            XCTAssertEqual(transport.requests.count, 1, "\(count) all-hit items cost one request")
            XCTAssertEqual(
                transport.studyRecordsQueryCount,
                0,
                "an all-hit batch must never touch the Study surface"
            )
        }
    }

    /// The whole point of the repair: a spelling the vocabulary batch has no
    /// record for can still carry a unique safe identity in Study data.
    func testTrueMissResolvesToTheUniqueSafeStudyIdentity() async throws {
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([(id: "VOC_A", spelling: "apple")]),
            studyRecordsResponse([(id: "VOC_STUDY", spelling: "selfaddedword")]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "selfaddedword"])

        XCTAssertEqual(
            resolution.outcomes,
            [.resolved(vocabularyID: "VOC_A"), .resolved(vocabularyID: "VOC_STUDY")]
        )
        XCTAssertEqual(transport.studyRecordsQueryCount, 1)
    }

    /// Binding is by the project's normalization, exactly as on the batch
    /// surface — never by response position.
    func testStudySpellingIsMatchedUnderTheProjectNormalization() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([
                (id: "VOC_OTHER", spelling: "banana"),
                (id: "VOC_STUDY", spelling: "SelfAddedWord"),
            ]),
        ])

        let resolution = try await resolver.resolve(spellings: ["selfaddedword"])

        XCTAssertEqual(resolution.outcomes, [.resolved(vocabularyID: "VOC_STUDY")])
    }

    /// The frozen request contract. All four documented fields are sent
    /// explicitly, `as_count` is a real JSON `false` (not an omitted or numeric
    /// stand-in), and `limit` is the provider maximum rather than the official
    /// CLI's smaller interactive default — either of which could silently
    /// suppress or truncate the identity rows this route exists to read.
    func testStudyRequestSendsAllFourExplicitFields() async throws {
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([]),
        ])

        _ = try await resolver.resolve(spellings: ["ghostword"])

        let request = try XCTUnwrap(
            transport.requests.first { $0.route == .studyRecordsQuery }
        )
        XCTAssertEqual(request.route.method, .post)
        XCTAssertFalse(request.route.isMutating, "a read-semantic POST is never a write")
        XCTAssertEqual(
            request.route.reviewedPath,
            "/open/api/v1/study/query_study_records"
        )
        // Bodies are serialized with sorted keys, so the exact text is stable —
        // and it proves the boolean is a JSON `false`, which an `as? Bool` cast
        // could not distinguish from a numeric zero.
        XCTAssertEqual(
            String(data: try XCTUnwrap(request.body), encoding: .utf8),
            #"{"as_count":false,"limit":1000,"spellings":["ghostword"],"voc_ids":[]}"#
        )
        XCTAssertEqual(transport.postCount, 0)
    }

    func testStudyRepairNeverConsumesTheOnePOSTPerItemAllowance() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([]),
        ])
        let control = ExecutionControl()

        _ = try await resolver.resolve(spellings: ["ghostword"], control: control)

        XCTAssertTrue(control.beginPostIfAllowed(), "the write allowance is untouched")
    }

    /// Many misses cost one Study request, not one per miss.
    func testManyMissesShareOneStudyRequest() async throws {
        let spellings = (0..<15).map { "ghost\($0)" }
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([(id: "VOC_G7", spelling: "ghost7")]),
        ])

        let resolution = try await resolver.resolve(spellings: spellings)

        XCTAssertEqual(transport.studyRecordsQueryCount, 1)
        XCTAssertEqual(
            transport.studyRecordsBodies.first?["spellings"] as? [String],
            spellings
        )
        XCTAssertEqual(resolution.outcomes[7], .resolved(vocabularyID: "VOC_G7"))
        XCTAssertTrue(
            resolution.outcomes.enumerated()
                .filter { $0.offset != 7 }
                .allSatisfy { $0.element == .blocked(.notFound) }
        )
    }

    /// Beyond the provider maximum the repair chunks sequentially, and a record
    /// answered in one chunk can never bind a spelling from another.
    func testMissesBeyondTheProviderMaximumChunkWithoutCrossBinding() async throws {
        let spellings = (0..<1_001).map { "ghost\($0)" }
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([]),
            vocabularyQueryResponse([]),
            // The second Study chunk answers with a first-chunk spelling as well
            // as its own; only its own may bind.
            studyRecordsResponse([]),
            studyRecordsResponse([
                (id: "VOC_LEAK", spelling: "ghost0"),
                (id: "VOC_LAST", spelling: "ghost1000"),
            ]),
        ])

        let resolution = try await resolver.resolve(spellings: spellings)

        XCTAssertEqual(transport.vocabularyQueryCount, 2)
        XCTAssertEqual(transport.studyRecordsQueryCount, 2)
        XCTAssertEqual(
            transport.studyRecordsBodies.map { ($0["spellings"] as? [String])?.count },
            [1_000, 1]
        )
        XCTAssertEqual(
            resolution.outcomes[0],
            .blocked(.notFound),
            "a record returned by another chunk must never bind this spelling"
        )
        XCTAssertEqual(resolution.outcomes[1_000], .resolved(vocabularyID: "VOC_LAST"))
    }

    /// Duplicate input rows naming one word cost exactly one identity lookup on
    /// each surface, and can never bind two different targets.
    func testDuplicateMissedSpellingsCostOneStudyLookup() async throws {
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([(id: "VOC_STUDY", spelling: "ghost")]),
        ])

        let resolution = try await resolver.resolve(spellings: ["ghost", "GHOST", "Ghost"])

        XCTAssertEqual(
            resolution.outcomes,
            Array(repeating: .resolved(vocabularyID: "VOC_STUDY"), count: 3)
        )
        XCTAssertEqual(transport.vocabularyQueryCount, 1)
        XCTAssertEqual(transport.studyRecordsQueryCount, 1)
        XCTAssertEqual(
            transport.studyRecordsBodies.first?["spellings"] as? [String],
            ["ghost"]
        )
    }

    /// A contradiction the batch already established is final. Study data must
    /// never be allowed to overwrite it with a more convenient answer.
    func testBatchMatchAnomalyIsNeverReopenedByStudy() async throws {
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([
                (id: "VOC_A1", spelling: "apple"),
                (id: "VOC_A2", spelling: "Apple"),
            ]),
            // Even a clean, unique Study identity for "apple" must not bind.
            studyRecordsResponse([
                (id: "VOC_STUDY_APPLE", spelling: "apple"),
                (id: "VOC_STUDY_GHOST", spelling: "ghostword"),
            ]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "ghostword"])

        XCTAssertEqual(
            resolution.outcomes,
            [.blocked(.matchAnomaly), .resolved(vocabularyID: "VOC_STUDY_GHOST")]
        )
        XCTAssertEqual(
            transport.studyRecordsBodies.first?["spellings"] as? [String],
            ["ghostword"],
            "an anomalous spelling is never even asked about on the Study surface"
        )
    }

    /// The batch surface's identity rules apply unchanged to Study rows.
    func testUnsafeAmbiguousOrMismatchedStudyRowsNeverResolve() async throws {
        let cases: [(String, [(id: String, spelling: String)], VocabularyTargetOutcome)] = [
            ("no record at all", [], .blocked(.notFound)),
            (
                "mismatched spelling only",
                [(id: "VOC_OTHER", spelling: "banana")],
                .blocked(.notFound)
            ),
            ("unsafe id", [(id: "VOC/../A", spelling: "ghost")], .blocked(.matchAnomaly)),
            ("empty id", [(id: "", spelling: "ghost")], .blocked(.matchAnomaly)),
            (
                "two different ids",
                [(id: "VOC_ONE", spelling: "ghost"), (id: "VOC_TWO", spelling: "Ghost")],
                .blocked(.matchAnomaly)
            ),
            (
                "repeated identical id still one target",
                [(id: "VOC_ONE", spelling: "ghost"), (id: "VOC_ONE", spelling: "Ghost")],
                .resolved(vocabularyID: "VOC_ONE")
            ),
        ]
        for (label, records, expected) in cases {
            let (resolver, _, _) = try makeResolver([
                vocabularyQueryResponse([]),
                studyRecordsResponse(records),
            ])

            let resolution = try await resolver.resolve(spellings: ["ghost"])

            XCTAssertEqual(resolution.outcomes, [expected], label)
        }
    }

    /// A record for a spelling nobody asked about can never bind another input.
    func testUnrequestedStudyRecordsBindNothing() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([
                (id: "VOC_UNASKED", spelling: "somethingelse"),
                (id: "VOC_ALSO_UNASKED", spelling: "andanother"),
            ]),
        ])

        let resolution = try await resolver.resolve(spellings: ["ghost"])

        XCTAssertEqual(resolution.outcomes, [.blocked(.notFound)])
    }

    /// A Study envelope this build cannot decode fails closed globally. It never
    /// fabricates an identity, and never silently downgrades into a target.
    func testMalformedStudyResponsesNeverFabricateIdentity() async throws {
        let record = ["voc_id": "VOC_STUDY", "voc_spelling": "ghost"]
        let malformed: [Any] = [
            ["unexpected": "shape"],
            [String: String](),
            ["records": "not an array"],
            ["data": ["records": record]],
            ["data": ["errors": [], "success": true]],
            // Wrapper nested more deeply than the first-party contract.
            ["data": ["data": ["records": [record]]]],
            // Shapes no first-party source shows.
            ["study_records": [record]],
            ["data": ["items": [record]]],
            ["data": [record]],
            [record],
            // Well-formed envelope, unusable row.
            ["data": ["records": [["voc_id": "VOC_STUDY"]]]],
            ["data": ["records": [["voc_id": 7, "voc_spelling": "ghost"]]]],
            ["data": ["records": [["voc_id": "VOC_STUDY", "voc_spelling": 7]]]],
        ]
        for envelope in malformed {
            let (resolver, transport, _) = try makeResolver([
                vocabularyQueryResponse([]),
                jsonResponse(envelope),
            ])
            do {
                _ = try await resolver.resolve(spellings: ["ghost"])
                XCTFail("a malformed Study response must abort the whole read plan")
            } catch {
                XCTAssertEqual(error as? CompanionError, .responseRejected)
            }
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    /// Session-wide failures on the Study request stay session-wide. None of
    /// them may be downgraded into a per-item guess.
    func testStudyAuthenticationRateLimitAndServerFailuresStayGlobal() async throws {
        let cases: [(Int, CompanionError)] = [
            (401, .authenticationRejected),
            (429, .rateLimited),
            (503, .serverFailure),
        ]
        for (status, expected) in cases {
            let (resolver, _, _) = try makeResolver([
                vocabularyQueryResponse([]),
                jsonResponse([:], status: status),
            ])
            do {
                _ = try await resolver.resolve(spellings: ["ghost"])
                XCTFail("HTTP \(status) on the Study repair must abort the whole read plan")
            } catch {
                XCTAssertEqual(error as? CompanionError, expected)
            }
        }
    }

    func testStudyTransportFailureStaysGlobal() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([]),
            .failure(.transport),
        ])

        do {
            _ = try await resolver.resolve(spellings: ["ghost"])
            XCTFail("a transport failure on the Study repair must abort the read plan")
        } catch {
            XCTAssertEqual(error as? CompanionError, .transport)
        }
    }

    /// Cancellation raised while the batch is in flight stops the plan before
    /// the repair is ever dispatched.
    func testCancellationDuringTheBatchStopsBeforeAnyStudyRequest() async throws {
        let (resolver, transport, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([(id: "VOC_STUDY", spelling: "ghost")]),
        ])
        let control = ExecutionControl()
        transport.onSend = { request in
            if request.route == .vocabularyQuery { control.requestCancellation() }
        }

        do {
            _ = try await resolver.resolve(spellings: ["ghost"], control: control)
            XCTFail("cancellation must propagate")
        } catch {
            XCTAssertEqual(error as? CompanionError, .cancelled)
        }
        XCTAssertEqual(transport.studyRecordsQueryCount, 0)
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
            XCTAssertEqual(
                transport.studyRecordsQueryCount,
                0,
                "a malformed batch aborts before any Study repair"
            )
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    func testEmptyResultSetBlocksEveryRequestedSpelling() async throws {
        let (resolver, _, _) = try makeResolver([
            vocabularyQueryResponse([]),
            studyRecordsResponse([]),
        ])

        let resolution = try await resolver.resolve(spellings: ["apple", "banana"])

        XCTAssertEqual(resolution.outcomes, [.blocked(.notFound), .blocked(.notFound)])
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

        // Per-item anomalies stay per-item, inside the first-party wrapper.
        let cases: [(String, [[String: String]], VocabularyTargetOutcome)] = [
            ("unsafe id", [["id": "bad/id", "spelling": "apple"]], .blocked(.matchAnomaly)),
            (
                "two identities",
                [["id": "VOC_A", "spelling": "apple"], ["id": "VOC_B", "spelling": "Apple"]],
                .blocked(.matchAnomaly)
            ),
            ("mismatched spelling", [["id": "VOC_A", "spelling": "apricot"]], .blocked(.notFound)),
        ]
        for (label, voc, expected) in cases {
            let envelope: [String: Any] = ["data": ["voc": voc], "errors": [], "success": true]
            // Only the mismatched-spelling case is a true miss, so only it
            // consumes the trailing Study stub; the anomalies never reach it.
            let (resolver, _, _) = try makeResolver([
                jsonResponse(envelope),
                studyRecordsResponse([]),
            ])
            let resolution = try await resolver.resolve(spellings: ["apple"])
            XCTAssertEqual(resolution.outcomes, [expected], label)
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
            XCTAssertEqual(
                transport.studyRecordsQueryCount,
                0,
                "an all-hit Preview adds no Study traffic (\(count) items)"
            )
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
            XCTAssertEqual(
                transport.studyRecordsQueryCount,
                0,
                "the #167/#168 request shape gains no Study traffic (\(count) items)"
            )
            let totalWait = sleeper.seconds.reduce(0, +)
            let oldFixedFloor = 1.6 * Double(count)
            XCTAssertEqual(totalWait, 0, "\(count) items")
            XCTAssertLessThan(totalWait, oldFixedFloor, "\(count) items")
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

