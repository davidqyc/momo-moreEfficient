import Foundation
import XCTest
@testable import MomoMoreEfficient

final class PhraseCreateCoreTests: XCTestCase {
    private let document = """
    ## acquisition
    EN: The acquisition strengthened the company's position in the market.
    ZH: 这次收购加强了公司在市场中的地位。
    SOURCE: 自编
    """

    func testPhraseRoutesAreLockedToReviewedGETAndCREATEPaths() throws {
        let collection = InterpretationRoute.phrases(vocabularyID: "INVALID_VOC")
        XCTAssertEqual(collection.method, .get)
        XCTAssertEqual(collection.reviewedPath, "/open/api/v1/phrases")
        XCTAssertEqual(
            try collection.url().absoluteString,
            "https://open.maimemo.com/open/api/v1/phrases?voc_id=INVALID_VOC"
        )
        XCTAssertEqual(InterpretationRoute.createPhrase.method, .post)
        XCTAssertEqual(
            try InterpretationRoute.createPhrase.url().absoluteString,
            "https://open.maimemo.com/open/api/v1/phrases"
        )
    }

    func testDocumentedAndDataPhraseWrappersAreAccepted() async throws {
        for wrapped in [false, true] {
            let record = phraseRecord(highlight: [[4, 15]])
            let transport = FakeHTTPTransport([phrasesResponse([record], wrapped: wrapped)])
            let lease = try credentialLease()
            let api = MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
            let records = try await api.phrases(vocabularyID: "INVALID_VOC")
            lease.clear()
            XCTAssertEqual(records.count, 1)
            XCTAssertEqual(records[0].phrase, english)
            XCTAssertEqual(records[0].interpretation, chinese)
            XCTAssertEqual(records[0].origin, "自编")
            XCTAssertEqual(records[0].status, "PUBLISHED")
            XCTAssertEqual(records[0].tags, [])
        }
    }

    func testOriginFieldAcceptsExactEmptyStringButRejectsMissingAndNonString() async throws {
        let empty = try await readPhrases([phraseRecord(source: "")])
        XCTAssertEqual(empty[0].origin, "")

        var missing = phraseRecord()
        missing.removeValue(forKey: "origin")
        await assertPhraseReadRejected(phrasesResponse([missing]))

        var nonString = phraseRecord()
        nonString["origin"] = 42
        await assertPhraseReadRejected(phrasesResponse([nonString]))
    }

    func testDuplicateAndUnsafePhraseIDsFailClosed() async throws {
        let cases: [[[String: Any]]] = [
            [phraseRecord(id: "INVALID_RECORD"), phraseRecord(id: "INVALID_RECORD")],
            [phraseRecord(id: "unsafe/id")],
        ]
        for records in cases {
            await assertPhraseReadRejected(phrasesResponse(records))
        }
    }

    func testReviewedHighlightShapesAreAcceptedAndBounded() async throws {
        let highlights: [Any] = [
            [[4, 15]],
            [["start": 4, "end": 15]],
            [],
        ]
        let expectedShapes: [PhraseHighlightShape] = [
            .integerPairArray, .objectRangeArray, .emptyArray,
        ]
        for (highlight, expectedShape) in zip(highlights, expectedShapes) {
            let records = try await readPhrases([phraseRecord(highlight: highlight)])
            guard case let .ranges(shape, _) = records[0].highlight else {
                return XCTFail("expected reviewed highlight range shape")
            }
            XCTAssertEqual(shape, expectedShape)
        }

        let missing = try await readPhrases([phraseRecord(highlight: nil)])
        XCTAssertEqual(missing[0].highlight, .missing)
    }

    func testMalformedUnknownAndOutOfBoundsHighlightsFailClosed() async throws {
        let malformed: [Any] = [
            ["start": 4, "end": 15],
            [[-1, 15]],
            [[15, 4]],
            [[4, 4]],
            [[4, english.unicodeScalars.count + 1]],
            [[4, 15, 20]],
            [[true, false]],
            [["4", "15"]],
            [[4, 15], ["start": 4, "end": 15]],
        ]
        for highlight in malformed {
            await assertPhraseReadRejected(
                phrasesResponse([phraseRecord(highlight: highlight)])
            )
        }
    }

    func testMalformedTagsAndRawResponseValuesDoNotLeak() async throws {
        let serverSentinel = "PRIVATE_SERVER_SENTINEL"
        let result = phrasesResponse([
            phraseRecord(tags: ["MBA", serverSentinel], highlight: []),
        ])
        let transport = FakeHTTPTransport([result])
        let lease = try credentialLease("FAKE_PRIVATE_CREDENTIAL_SENTINEL")
        let api = MaimemoTransport(
            transport: transport,
            credential: lease,
            sleeper: RecordingSleeper()
        )
        do {
            _ = try await api.phrases(vocabularyID: "INVALID_VOC")
            XCTFail("malformed tags should fail")
        } catch {
            XCTAssertEqual(error as? CompanionError, .itemResponseRejected)
            XCTAssertFalse(String(reflecting: error).contains(serverSentinel))
            XCTAssertFalse(String(reflecting: transport.requests).contains(serverSentinel))
            XCTAssertFalse(String(reflecting: transport.requests).contains("FAKE_PRIVATE"))
        }
        lease.clear()
    }

    func testUnrelatedPhrasesDoNotBlockCreate() async throws {
        let unrelated = phraseRecord(
            id: "INVALID_OTHER",
            phrase: "An unrelated example.",
            chinese: "无关例句。",
            highlight: []
        )
        let (snapshot, transport, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse([unrelated]),
            ]
        )
        XCTAssertEqual(snapshot.createCount, 1)
        XCTAssertEqual(snapshot.items[0].sameEnglishBaseline, [])
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertTrue(transport.requests.allSatisfy { !$0.route.isMutating })
    }

    func testZeroThroughFourActivePhrasesAllowCreate() async throws {
        for activeCount in 0...4 {
            let records = (0..<activeCount).map { index in
                phraseRecord(
                    id: "INVALID_ACTIVE_\(index)",
                    phrase: "Unrelated active phrase \(index).",
                    chinese: "无关例句 \(index)。"
                )
            }
            let (snapshot, transport, _) = try await makePhraseSnapshot(
                document: document,
                results: [
                    vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                    phrasesResponse(records),
                ]
            )

            XCTAssertEqual(snapshot.createCount, 1, "active count \(activeCount)")
            XCTAssertEqual(snapshot.blockedCount, 0, "active count \(activeCount)")
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    func testFiveActivePhrasesBlockCreateWithCompactCapacityReason() async throws {
        let records = (0..<5).map { index in
            phraseRecord(
                id: "INVALID_ACTIVE_\(index)",
                phrase: "Unrelated active phrase \(index).",
                chinese: "无关例句 \(index)。"
            )
        }
        let (snapshot, transport, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse(records),
            ]
        )

        XCTAssertEqual(snapshot.blockedCount, 1)
        XCTAssertEqual(snapshot.items[0].reason, "ACTIVE_CAPACITY_REACHED")
        XCTAssertEqual(
            snapshot.presentation.rows[0].blockedReason,
            "已达到当前安全上限 5 条，请先在墨墨中编辑或删除一条旧例句后重新预览"
        )
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: snapshot))
        XCTAssertEqual(transport.postCount, 0)
    }

    func testMoreThanFiveActivePhrasesFailClosedBeforeCreate() async throws {
        let records = (0..<6).map { index in
            phraseRecord(
                id: "INVALID_ACTIVE_\(index)",
                phrase: "Unrelated active phrase \(index).",
                chinese: "无关例句 \(index)。"
            )
        }
        let (snapshot, transport, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse(records),
            ]
        )

        XCTAssertEqual(snapshot.blockedCount, 1)
        XCTAssertEqual(snapshot.items[0].reason, "ACTIVE_CAPACITY_EXCEEDED")
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: snapshot))
        XCTAssertEqual(transport.postCount, 0)
    }

    func testDeletedPhrasesDoNotConsumeActiveCapacity() async throws {
        let active = (0..<4).map { index in
            phraseRecord(
                id: "INVALID_ACTIVE_\(index)",
                phrase: "Unrelated active phrase \(index).",
                chinese: "无关例句 \(index)。"
            )
        }
        let deleted = (0..<3).map { index in
            phraseRecord(
                id: "INVALID_DELETED_\(index)",
                phrase: "Deleted phrase \(index).",
                chinese: "已删除例句 \(index)。",
                status: "DELETED"
            )
        }
        let (snapshot, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse(active + deleted),
            ]
        )

        XCTAssertEqual(snapshot.createCount, 1)
        XCTAssertEqual(snapshot.blockedCount, 0)
    }

    func testDeletedSameEnglishTombstoneDoesNotBlockCreate() async throws {
        let tombstone = phraseRecord(id: "INVALID_DELETED", status: "DELETED")
        let (snapshot, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse([tombstone]),
            ]
        )

        XCTAssertEqual(snapshot.createCount, 1)
        XCTAssertEqual(snapshot.items[0].sameEnglishBaseline, [])
    }

    func testExactHardMatchIsAlreadyMatchingDespiteTagAndHighlightGaps() async throws {
        let exact = phraseRecord(tags: nil, highlight: nil)
        let (snapshot, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse([exact]),
            ]
        )
        XCTAssertEqual(snapshot.alreadyMatchingCount, 1)
        XCTAssertEqual(
            snapshot.items[0].observations(tags: snapshot.bindingContext.tags),
            [.tagsMissing, .highlightMissing, .chineseRangeUnavailable]
        )
    }

    func testNoSourceAlreadyMatchingIgnoresOriginButKeepsOtherHardFields() async throws {
        let document = "acquisition\n\(english)\n\(chinese)"
        let (matching, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse([phraseRecord(source: "server stored source")]),
            ]
        )
        XCTAssertEqual(matching.items[0].classification, .alreadyMatching)

        let (wrongChinese, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                phrasesResponse([phraseRecord(chinese: "不同中文", source: "anything")]),
            ]
        )
        XCTAssertEqual(wrongChinese.items[0].classification, .blocked)
        XCTAssertEqual(wrongChinese.items[0].reason, "CONFLICTING_SAME_ENGLISH")
    }

    func testSameEnglishConflictAndMultipleCandidatesAreBlocked() async throws {
        let conflicts = [
            [phraseRecord(chinese: "不同翻译。")],
            [phraseRecord(source: "词典")],
            [phraseRecord(id: "INVALID_A"), phraseRecord(id: "INVALID_B")],
        ]
        for records in conflicts {
            let (snapshot, _, _) = try await makePhraseSnapshot(
                document: document,
                results: [
                    vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                    phrasesResponse(records),
                ]
            )
            XCTAssertEqual(snapshot.blockedCount, 1)
            XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: snapshot))
        }
    }

    func testItemSchemaFailuresBecomeBlocked() async throws {
        let failures: [StubbedResult] = [
            phrasesResponse([phraseRecord(id: "bad/id")]),
            phrasesResponse([phraseRecord(status: "UNPUBLISHED")]),
        ]
        for failure in failures {
            let (snapshot, _, _) = try await makePhraseSnapshot(
                document: document,
                results: [
                    vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
                    failure,
                ]
            )
            XCTAssertEqual(snapshot.items[0].classification, .blocked)
            XCTAssertEqual(snapshot.items[0].reason, "READ_FAILED")
        }
    }

    func testVocabularyNotFoundBlocksOnlyThatPhraseEntry() async throws {
        let mixedDocument = """
        ## missingword
        EN: This entry should remain blocked.
        ZH: 这一条应保持阻断。
        SOURCE: 自编

        ## acquisition
        EN: The acquisition strengthened the company's position in the market.
        ZH: 这次收购加强了公司在市场中的地位。
        SOURCE: 自编
        """
        let (snapshot, transport, _) = try await makePhraseSnapshot(
            document: mixedDocument,
            results: [
                // The batch resolution simply has no record for "missingword".
                vocabularyQueryResponse([(id: "INVALID_VOC_ACQUISITION", spelling: "acquisition")]),
                // #164: the miss gets one exact-GET attempt, which proves nothing.
                unresolvableVocabularyResponse(),
                phrasesResponse([]),
            ]
        )

        XCTAssertEqual(snapshot.items.map(\.classification), [.blocked, .create])
        XCTAssertEqual(snapshot.items[0].reason, "VOCABULARY_NOT_FOUND")
        XCTAssertNil(snapshot.items[0].vocabularyID)
        XCTAssertEqual(snapshot.items[1].vocabularyID, "INVALID_VOC_ACQUISITION")
        XCTAssertEqual(
            transport.readCount,
            3,
            "one batch query, one fallback GET, and no content read for the unresolved entry"
        )
        XCTAssertEqual(transport.requests[1].route, .vocabulary(spelling: "missingword"))
        XCTAssertEqual(transport.postCount, 0)
    }

    func testGlobalReadFailuresAbortPhrasePlanWithoutFabricatedRows() async throws {
        let entries = try PhraseBatchParser.parse(document)
        for failure in [
            jsonResponse(["error": "auth"], status: 401),
            StubbedResult.failure(.transport),
            jsonResponse(["error": "rate"], status: 429),
            jsonResponse(["error": "server"], status: 503),
        ] {
            let transport = FakeHTTPTransport([failure])
            let lease = try credentialLease()
            defer { lease.clear() }
            do {
                _ = try await PhrasePreflightPlanner(
                    api: MaimemoTransport(
                        transport: transport,
                        credential: lease,
                        sleeper: RecordingSleeper()
                    )
                ).buildSnapshot(
                    entries: entries,
                    tags: [],
                    credentialFingerprint: lease.fingerprint
                )
                XCTFail("global failure must abort Preview")
            } catch let error as CompanionError {
                XCTAssertTrue(error.abortsReadPlan)
            }
            XCTAssertEqual(transport.readCount, 1)
            XCTAssertEqual(transport.postCount, 0)
        }
    }

    func testBindingCommitsContentTagsPathsCredentialAndRelevantBaseline() async throws {
        let shown = try await createSnapshot(document: document, token: fakeToken)
        let approval = try PhraseCreateBinding.makeApproval(snapshot: shown)

        for changed in [
            document.replacingOccurrences(of: english, with: english + " Changed"),
            document.replacingOccurrences(of: chinese, with: chinese + "改变"),
            document.replacingOccurrences(of: "SOURCE: 自编", with: "SOURCE: 课堂"),
        ] {
            let snapshot = try await createSnapshot(document: changed, token: fakeToken)
            XCTAssertNotEqual(
                try PhraseCreateBinding.makeApproval(snapshot: snapshot),
                approval
            )
        }

        let otherCredential = try await createSnapshot(
            document: document,
            token: "FAKE_OTHER_TOKEN_NOT_VALID"
        )
        XCTAssertNotEqual(
            try PhraseCreateBinding.makeApproval(snapshot: otherCredential),
            approval
        )

        let changedTags = replacingContext(
            shown,
            tags: ["MBA"],
            createPath: PhraseCreateBinding.createPath
        )
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: changedTags))
        let changedPath = replacingContext(
            shown,
            tags: [],
            createPath: "/open/api/v1/phrases/other"
        )
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: changedPath))

        let conflict = PhrasePreflightItem(
            entry: shown.items[0].entry,
            classification: .blocked,
            vocabularyID: "INVALID_VOC",
            sameEnglishBaseline: [PhraseRecord(
                id: "INVALID_RECORD",
                phrase: english,
                interpretation: "changed",
                tags: nil,
                origin: "自编",
                status: "PUBLISHED",
                highlight: .missing
            )],
            reason: "CONFLICTING_SAME_ENGLISH"
        )
        let changedBaseline = PhrasePreviewSnapshot(
            sourceIdentity: shown.sourceIdentity,
            credentialFingerprint: shown.credentialFingerprint,
            accountMode: shown.accountMode,
            bindingContext: try PhraseCreateBinding.makePreviewBindingContext(
                items: [conflict],
                tags: []
            ),
            items: [conflict]
        )
        XCTAssertNotEqual(
            try PhraseCreateBinding.snapshotIdentity(changedBaseline),
            approval.snapshotIdentity
        )
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: changedBaseline))
    }

    func testFreshPreflightThenExactCREATEBodyAndImmediateReadback() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201), phrasesResponse([phraseRecord(highlight: [[4, 15]])]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.confirmed])
        XCTAssertEqual(
            transport.requests.map(\.route),
            [
                .vocabularyQuery,
                .phrases(vocabularyID: "INVALID_VOC"),
                .createPhrase,
                .phrases(vocabularyID: "INVALID_VOC"),
            ]
        )
        XCTAssertEqual(transport.postCount, 1)

        let body = try XCTUnwrap(transport.requests[2].body)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(Set(object.keys), Set(["phrase"]))
        let phrase = try XCTUnwrap(object["phrase"] as? [String: Any])
        XCTAssertEqual(
            Set(phrase.keys),
            Set(["voc_id", "phrase", "interpretation", "tags", "origin"])
        )
        XCTAssertEqual(phrase["voc_id"] as? String, "INVALID_VOC")
        XCTAssertEqual(phrase["phrase"] as? String, english)
        XCTAssertEqual(phrase["interpretation"] as? String, chinese)
        XCTAssertEqual(phrase["tags"] as? [String], [])
        XCTAssertEqual(phrase["origin"] as? String, "自编")
        for forbidden in ["highlight", "status", "id", "range", "chinese_range"] {
            XCTAssertNil(phrase[forbidden])
        }
    }

    func testNoSourceCREATEEmitsEmptyOriginAndReadbackDoesNotConstrainStoredOrigin() async throws {
        let noSourceDocument = "acquisition\n\(english)\n\(chinese)"
        let shown = try await createSnapshot(
            document: noSourceDocument,
            tags: ["MBA", "BEC"]
        )
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201),
            phrasesResponse([
                phraseRecord(tags: ["BEC", "MBA"], source: "server assigned"),
            ]),
        ])

        let summary = try await executePhrase(snapshot: shown, transport: transport)

        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.results[0].outcome, .confirmed)
        XCTAssertTrue(summary.results[0].observations.contains(.tagsMatchRequested))
        let post = try XCTUnwrap(transport.requests.first(where: { $0.route.isMutating }))
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try XCTUnwrap(post.body)) as? [String: Any]
        )
        let phrase = try XCTUnwrap(object["phrase"] as? [String: Any])
        XCTAssertEqual(phrase["origin"] as? String, "")
        XCTAssertEqual(phrase["tags"] as? [String], ["MBA", "BEC"])
    }

    func testPostCreateReadbackIgnoresDeletedSameEnglishTombstone() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201),
            phrasesResponse([
                phraseRecord(id: "INVALID_DELETED", status: "DELETED"),
                phraseRecord(id: "INVALID_ACTIVE"),
            ]),
        ])

        let summary = try await executePhrase(snapshot: shown, transport: transport)

        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.confirmed])
        XCTAssertEqual(transport.postCount, 1)
    }

    func testFreshConflictInvalidatesApprovalBeforePOST() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
            phrasesResponse([phraseRecord(chinese: "changed")]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertTrue(summary.stalePreview)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testUnrelatedFreshBaselineChangeDoesNotInvalidateCreate() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]),
            phrasesResponse([
                phraseRecord(
                    id: "INVALID_OTHER",
                    phrase: "An unrelated example.",
                    chinese: "无关。"
                ),
            ]),
            jsonResponse([:], status: 201),
            phrasesResponse([phraseRecord()]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(transport.postCount, 1)
    }

    func testUncertainPOSTUsesGETOnlyRecoveryAndNeverRetries() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            .failure(.transport), phrasesResponse([phraseRecord()]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.results.map(\.outcome), [.recovered])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(transport.requests.suffix(2).map(\.route.isMutating), [true, false])
    }

    func testCleanPOSTFirstReadbackMissingLaterReadbackConfirmsWithOnePOST() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201),
            phrasesResponse([]),
            phrasesResponse([phraseRecord()]),
        ])
        let sleeper = RecordingSleeper()

        let summary = try await executePhrase(
            snapshot: shown,
            transport: transport,
            sleeper: sleeper
        )

        XCTAssertEqual(summary.results.map(\.outcome), [.confirmed])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(summary.results[0].diagnostic?.postDispatch, .clean2xx(status: 201))
        XCTAssertEqual(
            summary.results[0].diagnostic?.readbackAttempts.map(\.category),
            [.targetNotVisible, .success]
        )
        // #168: pacing goes through the shared aggregate-window scheduler now
        // (the opening request on a fresh transport is still free); every
        // request here stays far under the aggregate windows, so each paced
        // call waits 0 seconds instead of the old fixed floor.
        XCTAssertEqual(sleeper.seconds.count, transport.requests.count - 1)
        XCTAssertTrue(sleeper.seconds.allSatisfy { $0 == 0 })
    }

    func testUncertainPOSTMissingThenLaterReadbackRecoversWithOnePOST() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            .failure(.transport),
            phrasesResponse([]),
            phrasesResponse([phraseRecord()]),
        ])

        let summary = try await executePhrase(snapshot: shown, transport: transport)

        XCTAssertEqual(summary.results.map(\.outcome), [.recovered])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(
            summary.results[0].diagnostic?.postDispatch,
            .transportFailure(errorCategory: .transport)
        )
        XCTAssertEqual(
            summary.results[0].diagnostic?.readbackAttempts.map(\.category),
            [.targetNotVisible, .success]
        )
    }

    func testPostDiagnosticsDistinguishCleanHTTPRejectionAndTransportWithoutPrivateData()
        async throws
    {
        let privateDocument = """
        ## acquisition
        EN: The acquisition strengthened the company's position in the market.
        ZH: PRIVATE_CHINESE_SENTINEL
        SOURCE: PRIVATE_SOURCE_SENTINEL
        """
        let cases: [(StubbedResult, PostDispatchCategory, String)] = [
            (
                jsonResponse(["raw": "PRIVATE_RAW_RESPONSE_SENTINEL"], status: 201),
                .clean2xx(status: 201),
                "POST：HTTP 201 [clean2xx]"
            ),
            (
                jsonResponse(["raw": "PRIVATE_RAW_RESPONSE_SENTINEL"], status: 400),
                .httpRejected(status: 400),
                "POST：HTTP 400 [httpRejected]"
            ),
            (
                .failure(.transport),
                .transportFailure(errorCategory: .transport),
                "POST：发送失败（transport） [transportFailure/transport]"
            ),
        ]

        for (postResult, expectedDispatch, expectedExport) in cases {
            let shown = try await createSnapshot(document: privateDocument)
            let transport = FakeHTTPTransport([
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
                postResult,
                phrasesResponse([]), phrasesResponse([]), phrasesResponse([]),
            ])

            let summary = try await executePhrase(snapshot: shown, transport: transport)

            XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
            XCTAssertEqual(summary.results[0].diagnostic?.postDispatch, expectedDispatch)
            XCTAssertEqual(transport.postCount, 1)
            XCTAssertTrue(transport.requests.suffix(3).allSatisfy { !$0.route.isMutating })

            let receipt = ExecutionReceipt(
                selectedSpellings: ["acquisition"],
                result: summary
            )
            XCTAssertEqual(receipt.unconfirmed, 1)
            XCTAssertEqual(receipt.failed, 0)
            let archive = String(decoding: try JSONEncoder().encode(receipt), as: UTF8.self)
            let exported = receipt.sanitizedDiagnosticText
            XCTAssertTrue(exported.contains(expectedExport), expectedExport)
            for forbidden in [
                fakeToken, "Bearer ", "Authorization", "Cookie",
                "INVALID_VOC", english, "PRIVATE_CHINESE_SENTINEL",
                "PRIVATE_SOURCE_SENTINEL", "PRIVATE_RAW_RESPONSE_SENTINEL",
            ] {
                XCTAssertFalse(archive.contains(forbidden), forbidden)
                XCTAssertFalse(exported.contains(forbidden), forbidden)
            }
        }
    }

    func testBoundedReadbacksNeverConfirmAndStopLaterBatchItem() async throws {
        let batch = document + """


        ## liquidity
        EN: Liquidity matters.
        ZH: 流动性很重要。
        SOURCE: 自编
        """
        let initial: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "acquisition"), (id: "INVALID_VOC_B", spelling: "liquidity")]), phrasesResponse([]),
            phrasesResponse([]),
        ]
        let (shown, _, _) = try await makePhraseSnapshot(document: batch, results: initial)
        let transport = FakeHTTPTransport(initial + [
            jsonResponse([:], status: 201),
            phrasesResponse([]), phrasesResponse([]), phrasesResponse([]),
        ])

        let summary = try await executePhrase(snapshot: shown, transport: transport)

        XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(summary.results[0].diagnostic?.readbackAttempts.count, 3)
        XCTAssertEqual(
            summary.results[0].diagnostic?.readbackAttempts.map(\.category),
            [.targetNotVisible, .targetNotVisible, .targetNotVisible]
        )
    }

    func testAuthenticationRejectionStopsConfirmationWindowImmediately() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201),
            jsonResponse(["error": "auth"], status: 401),
        ])

        let summary = try await executePhrase(snapshot: shown, transport: transport)

        XCTAssertEqual(summary.terminalError, .authenticationRejected)
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(summary.results[0].diagnostic?.readbackAttempts.count, 1)
        XCTAssertEqual(
            summary.results[0].diagnostic?.readbackAttempts.first?.category,
            .authenticationRejected
        )
    }

    func testReadbackTransportServerAndSchemaFailuresHaveDistinctDiagnostics() async throws {
        let cases: [([StubbedResult], ReadbackCategory, Int)] = [
            ([.failure(.transport), .failure(.transport), .failure(.transport)],
             .transportFailure, 3),
            ([jsonResponse(["error": "server"], status: 503),
              jsonResponse(["error": "server"], status: 503),
              jsonResponse(["error": "server"], status: 503)],
             .serverFailure, 3),
            ([jsonResponse(["unexpected": []])], .responseSchemaRejected, 1),
        ]

        for (readbacks, expectedCategory, expectedCount) in cases {
            let shown = try await createSnapshot(document: document)
            let transport = FakeHTTPTransport([
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
                jsonResponse([:], status: 201),
            ] + readbacks)

            let summary = try await executePhrase(snapshot: shown, transport: transport)

            XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
            XCTAssertEqual(transport.postCount, 1)
            XCTAssertEqual(summary.results[0].diagnostic?.readbackAttempts.count, expectedCount)
            XCTAssertEqual(
                summary.results[0].diagnostic?.readbackAttempts.last?.category,
                expectedCategory
            )
        }
    }

    func testRateLimitAndAmbiguousTargetStopWithoutExtraReadback() async throws {
        let cases: [(StubbedResult, ReadbackCategory)] = [
            (jsonResponse(["error": "rate"], status: 429), .rateLimited),
            (phrasesResponse([
                phraseRecord(id: "INVALID_A"),
                phraseRecord(id: "INVALID_B"),
            ]), .targetAmbiguous),
        ]

        for (readback, expectedCategory) in cases {
            let shown = try await createSnapshot(document: document)
            let transport = FakeHTTPTransport([
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
                jsonResponse([:], status: 201), readback,
            ])

            let summary = try await executePhrase(snapshot: shown, transport: transport)

            XCTAssertEqual(transport.postCount, 1)
            XCTAssertEqual(summary.results[0].diagnostic?.readbackAttempts.count, 1)
            XCTAssertEqual(
                summary.results[0].diagnostic?.readbackAttempts[0].category,
                expectedCategory
            )
        }
    }

    func testSameEnglishMismatchDiagnosticStoresOnlyClosedKeysAndCounts() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201),
            phrasesResponse([phraseRecord(id: "INVALID_PRIVATE_RECORD", chinese: "不同中文")]),
        ])

        let summary = try await executePhrase(snapshot: shown, transport: transport)
        let attempt = try XCTUnwrap(summary.results[0].diagnostic?.readbackAttempts.first)
        let facts = try XCTUnwrap(attempt.phraseFacts)

        XCTAssertEqual(attempt.category, .intendedStateMismatch)
        XCTAssertEqual(facts.activeRecordCount, 1)
        XCTAssertEqual(facts.sameEnglishCount, 1)
        XCTAssertEqual(facts.mismatchKeys, [.chinese])
        let encoded = String(
            decoding: try JSONEncoder().encode(attempt),
            as: UTF8.self
        )
        XCTAssertFalse(encoded.contains("INVALID_PRIVATE_RECORD"))
        XCTAssertFalse(encoded.contains(chinese))
    }

    func testMultiEntryBatchDispatchesAtMostOnePOSTPerCreateItem() async throws {
        let batch = document + """


        ## liquidity
        EN: Liquidity matters.
        ZH: 流动性很重要。
        SOURCE: 自编
        """
        let initial: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "acquisition"), (id: "INVALID_VOC_B", spelling: "liquidity")]), phrasesResponse([]),
            phrasesResponse([]),
        ]
        let (shown, _, _) = try await makePhraseSnapshot(document: batch, results: initial)
        let transport = FakeHTTPTransport(initial + [
            jsonResponse([:], status: 201), phrasesResponse([phraseRecord()]),
            jsonResponse([:], status: 201),
            phrasesResponse([
                phraseRecord(
                    id: "INVALID_RECORD_B",
                    phrase: "Liquidity matters.",
                    chinese: "流动性很重要。"
                ),
            ]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.succeeded, 2)
        XCTAssertEqual(summary.results.map(\.outcome), [.confirmed, .confirmed])
        XCTAssertEqual(transport.postCount, 2)
        XCTAssertEqual(
            transport.requests.filter { $0.route.isMutating }.map(\.route),
            [.createPhrase, .createPhrase]
        )
    }

    func testTagAndHighlightImperfectionsRemainVerifiedClosedObservations() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201),
            phrasesResponse([phraseRecord(tags: ["MBA"], highlight: nil)]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(
            summary.results[0].observations,
            [.tagsDiffer, .highlightMissing, .chineseRangeUnavailable]
        )
    }

    func testDuplicateOrExtraDocumentedTagsRemainNonBlockingMismatch() async throws {
        for tags in [
            ["MBA", "MBA"],
            ["MBA", "BEC", "GMAT", "GRE"],
        ] {
            let shown = try await createSnapshot(document: document)
            let transport = FakeHTTPTransport([
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
                jsonResponse([:], status: 201),
                phrasesResponse([phraseRecord(tags: tags, highlight: [])]),
            ])
            let summary = try await executePhrase(snapshot: shown, transport: transport)
            XCTAssertEqual(summary.succeeded, 1)
            XCTAssertTrue(summary.results[0].observations.contains(.tagsDiffer))
        }
    }

    func testExactTargetAndEmptyHighlightRemainClosedObservations() async throws {
        for (highlight, expected) in [
            ([[4, 15]] as Any, PhraseObservation.highlightExactTarget),
            ([[0, 3]] as Any, PhraseObservation.highlightOtherReviewedRange),
            ([] as Any, PhraseObservation.highlightEmpty),
        ] {
            let effectiveHighlight: Any = highlight
            let shown = try await createSnapshot(document: document)
            let transport = FakeHTTPTransport([
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
                jsonResponse([:], status: 201),
                phrasesResponse([phraseRecord(highlight: effectiveHighlight)]),
            ])
            let summary = try await executePhrase(snapshot: shown, transport: transport)
            XCTAssertEqual(summary.succeeded, 1, expected.rawValue)
            XCTAssertTrue(
                summary.results.first?.observations.contains(expected) == true,
                expected.rawValue
            )
        }
    }

    func testWrongSentenceTranslationSourceStatusAndDuplicatesAreNotVerified() async throws {
        let mismatches: [[[String: Any]]] = [
            [phraseRecord(phrase: "A different sentence.")],
            [phraseRecord(chinese: "错误翻译。")],
            [phraseRecord(source: "错误来源")],
            [phraseRecord(status: "UNPUBLISHED")],
            [phraseRecord(id: "INVALID_A"), phraseRecord(id: "INVALID_B")],
        ]
        for records in mismatches {
            let shown = try await createSnapshot(document: document)
            let transport = FakeHTTPTransport([
                vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
                jsonResponse([:], status: 201),
                phrasesResponse(records), phrasesResponse(records), phrasesResponse(records),
            ])
            let summary = try await executePhrase(snapshot: shown, transport: transport)
            XCTAssertEqual(summary.failed, 1)
            XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
            XCTAssertEqual(transport.postCount, 1)
        }
    }

    func testMalformedHighlightMakesReadbackUnverified() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyQueryResponse([(id: "INVALID_VOC", spelling: "acquisition")]), phrasesResponse([]),
            jsonResponse([:], status: 201),
            phrasesResponse([phraseRecord(highlight: [[4, english.count + 10]])]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
        XCTAssertEqual(transport.postCount, 1)
    }

    func testWrongHardReadbackOrDuplicateSameEnglishStopsWithoutLaterPOST() async throws {
        let twoEntryDocument = document + """


        ## liquidity
        EN: Liquidity matters.
        ZH: 流动性很重要。
        SOURCE: 自编
        """
        let initial: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "acquisition"), (id: "INVALID_VOC_B", spelling: "liquidity")]), phrasesResponse([]),
            phrasesResponse([]),
        ]
        let (shown, _, _) = try await makePhraseSnapshot(
            document: twoEntryDocument,
            results: initial
        )
        let transport = FakeHTTPTransport(initial + [
            jsonResponse([:], status: 201),
            phrasesResponse([phraseRecord(source: "wrong source")]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.failed, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
        XCTAssertEqual(transport.postCount, 1)
    }

    func testCancellationAfterPOSTAllowsReadbackAndPreventsLaterPOST() async throws {
        let twoEntryDocument = document + """


        ## liquidity
        EN: Liquidity matters.
        ZH: 流动性很重要。
        SOURCE: 自编
        """
        let initial: [StubbedResult] = [
            vocabularyQueryResponse([(id: "INVALID_VOC_A", spelling: "acquisition"), (id: "INVALID_VOC_B", spelling: "liquidity")]), phrasesResponse([]),
            phrasesResponse([]),
        ]
        let (shown, _, _) = try await makePhraseSnapshot(
            document: twoEntryDocument,
            results: initial
        )
        let transport = FakeHTTPTransport(initial + [
            jsonResponse([:], status: 201), phrasesResponse([phraseRecord()]),
        ])
        let control = ExecutionControl()
        transport.onSend = { request in
            if request.route == .createPhrase { control.requestCancellation() }
        }
        let summary = try await executePhrase(
            snapshot: shown,
            transport: transport,
            control: control
        )
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertTrue(summary.cancelled)
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(transport.requests.suffix(2).map(\.route.isMutating), [true, false])
    }

    func testPhraseCoreDefinesNoUpdateDeleteOrReplayRoute() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let core = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("MomoMoreEfficient/Core")
        let sources = try ["HTTPTransport.swift", "PhraseCreateCore.swift"].map {
            try String(contentsOf: core.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        for forbidden in ["updatePhrase", "deletePhrase", "replayPhrase", "rollbackPhrase"] {
            XCTAssertFalse(sources.contains(forbidden), forbidden)
        }
    }

    private var english: String {
        "The acquisition strengthened the company's position in the market."
    }

    private var chinese: String { "这次收购加强了公司在市场中的地位。" }

    private func phraseRecord(
        id: String = "INVALID_RECORD",
        phrase: String? = nil,
        chinese: String? = nil,
        tags: Any? = [String](),
        source: String = "自编",
        status: String = "PUBLISHED",
        highlight: Any? = []
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "phrase": phrase ?? english,
            "interpretation": chinese ?? self.chinese,
            "origin": source,
            "status": status,
        ]
        if let tags { value["tags"] = tags }
        if let highlight { value["highlight"] = highlight }
        return value
    }

    private func phrasesResponse(
        _ records: [[String: Any]],
        wrapped: Bool = false
    ) -> StubbedResult {
        wrapped
            ? jsonResponse(["data": ["phrases": records]])
            : jsonResponse(["phrases": records])
    }

    private func readPhrases(_ records: [[String: Any]]) async throws -> [PhraseRecord] {
        let transport = FakeHTTPTransport([phrasesResponse(records)])
        let lease = try credentialLease()
        defer { lease.clear() }
        let api = MaimemoTransport(
            transport: transport,
            credential: lease,
            sleeper: RecordingSleeper()
        )
        return try await api.phrases(vocabularyID: "INVALID_VOC")
    }

    private func assertPhraseReadRejected(
        _ result: StubbedResult,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let transport = FakeHTTPTransport([result])
        do {
            let lease = try credentialLease()
            defer { lease.clear() }
            let api = MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
            _ = try await api.phrases(vocabularyID: "INVALID_VOC")
            XCTFail("expected phrase response rejection", file: file, line: line)
        } catch {
            XCTAssertEqual(
                error as? CompanionError,
                .itemResponseRejected,
                file: file,
                line: line
            )
        }
    }

    private func makePhraseSnapshot(
        document: String,
        results: [StubbedResult],
        token: String = fakeToken,
        tags: [String] = []
    ) async throws -> (PhrasePreviewSnapshot, FakeHTTPTransport, RecordingSleeper) {
        let entries = try PhraseBatchParser.parse(document)
        let transport = FakeHTTPTransport(results)
        let sleeper = RecordingSleeper()
        let lease = try credentialLease(token)
        let api = MaimemoTransport(transport: transport, credential: lease, sleeper: sleeper)
        let snapshot = try await PhrasePreflightPlanner(api: api).buildSnapshot(
            entries: entries,
            tags: tags,
            credentialFingerprint: lease.fingerprint
        )
        lease.clear()
        return (snapshot, transport, sleeper)
    }

    private func createSnapshot(
        document: String,
        token: String = fakeToken,
        tags: [String] = []
    ) async throws -> PhrasePreviewSnapshot {
        let entries = try PhraseBatchParser.parse(document)
        let targets = entries.map { entry in
            (
                id: entries.count == 1 ? "INVALID_VOC" : "INVALID_VOC_\(entry.ordinal)",
                spelling: entry.spelling
            )
        }
        let results: [StubbedResult] = [vocabularyQueryResponse(targets)]
            + entries.map { _ in phrasesResponse([]) }
        let snapshot = try await makePhraseSnapshot(
            document: document,
            results: results,
            token: token,
            tags: tags
        )
        return snapshot.0
    }

    private func executePhrase(
        snapshot: PhrasePreviewSnapshot,
        transport: FakeHTTPTransport,
        control: ExecutionControl = ExecutionControl(),
        sleeper: RecordingSleeper = RecordingSleeper()
    ) async throws -> PhraseExecutionSummary {
        let lease = try credentialLease()
        let executor = PhraseWriteExecutor(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: sleeper
            )
        )
        let summary = await executor.execute(
            displayedSnapshot: snapshot,
            approval: try PhraseCreateBinding.makeApproval(snapshot: snapshot),
            control: control
        )
        lease.clear()
        return summary
    }

    private func replacingContext(
        _ snapshot: PhrasePreviewSnapshot,
        tags: [String],
        createPath: String
    ) -> PhrasePreviewSnapshot {
        PhrasePreviewSnapshot(
            sourceIdentity: snapshot.sourceIdentity,
            credentialFingerprint: snapshot.credentialFingerprint,
            accountMode: snapshot.accountMode,
            bindingContext: PhrasePreviewBindingContext(
                host: snapshot.bindingContext.host,
                vocabularyPath: snapshot.bindingContext.vocabularyPath,
                collectionPath: snapshot.bindingContext.collectionPath,
                createPath: createPath,
                tags: tags,
                expectedStatus: snapshot.bindingContext.expectedStatus,
                createBatchDigest: snapshot.bindingContext.createBatchDigest
            ),
            items: snapshot.items
        )
    }
}
