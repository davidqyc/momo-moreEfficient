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

    func testPhraseRoutesAreLockedToReviewedGETCREATEAndUPDATEPaths() throws {
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
        let update = InterpretationRoute.updatePhrase(recordID: "INVALID_RECORD")
        XCTAssertEqual(update.method, .post)
        XCTAssertEqual(update.reviewedPath, "/open/api/v1/phrases/INVALID_RECORD")
        XCTAssertEqual(
            try update.url().absoluteString,
            "https://open.maimemo.com/open/api/v1/phrases/INVALID_RECORD"
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
            XCTAssertEqual(records[0].tags, CompanionConstants.tags)
        }
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
            XCTAssertEqual(error as? CompanionError, .responseRejected)
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
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse([unrelated]),
            ]
        )
        XCTAssertEqual(snapshot.createCount, 1)
        XCTAssertEqual(snapshot.items[0].sameEnglishBaseline, [])
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertTrue(transport.requests.allSatisfy { $0.route.method == .get })
    }

    func testExactHardMatchIsAlreadyMatchingDespiteTagAndHighlightGaps() async throws {
        let exact = phraseRecord(tags: nil, highlight: nil)
        let (snapshot, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse([exact]),
            ]
        )
        XCTAssertEqual(snapshot.alreadyMatchingCount, 1)
        XCTAssertEqual(
            snapshot.items[0].observations,
            [.tagsMissing, .highlightMissing, .chineseRangeUnavailable]
        )
    }

    func testSameEnglishConflictsRequireExplicitReplacementCandidates() async throws {
        let conflicts = [
            [phraseRecord(chinese: "不同翻译。")],
            [phraseRecord(source: "词典")],
            [
                phraseRecord(id: "INVALID_A", chinese: "不同翻译 A。"),
                phraseRecord(id: "INVALID_B", chinese: "不同翻译 B。"),
            ],
        ]
        for records in conflicts {
            let (snapshot, _, _) = try await makePhraseSnapshot(
                document: document,
                results: [
                    vocabularyResponse("INVALID_VOC", "acquisition"),
                    phrasesResponse(records),
                ]
            )
            XCTAssertEqual(snapshot.replaceRequiredCount, 1)
            XCTAssertEqual(snapshot.items[0].replacementCandidates.count, records.count)
            XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: snapshot))
        }
    }

    func testMultipleExactSameEnglishRecordsAreBlockedAsAmbiguous() async throws {
        let (snapshot, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse([
                    phraseRecord(id: "INVALID_A"),
                    phraseRecord(id: "INVALID_B"),
                ]),
            ]
        )
        XCTAssertEqual(snapshot.blockedCount, 1)
        XCTAssertEqual(snapshot.items[0].reason, "AMBIGUOUS_SAME_ENGLISH")
    }

    func testReadAndSchemaFailuresBecomeBlocked() async throws {
        let failures: [StubbedResult] = [
            .failure(.transport),
            jsonResponse(["unexpected": []]),
            phrasesResponse([phraseRecord(id: "bad/id")]),
        ]
        for failure in failures {
            let (snapshot, _, _) = try await makePhraseSnapshot(
                document: document,
                results: [
                    vocabularyResponse("INVALID_VOC", "acquisition"),
                    failure,
                ]
            )
            XCTAssertEqual(snapshot.items[0].classification, .blocked)
            XCTAssertEqual(snapshot.items[0].reason, "READ_FAILED")
        }
    }

    func testCapacityPlanningUsesOnlyActivePublishedRecords() async throws {
        for count in [0, 1, 4] {
            let (snapshot, transport, _) = try await makePhraseSnapshot(
                document: document,
                results: [
                    vocabularyResponse("INVALID_VOC", "acquisition"),
                    phrasesResponse(unrelatedRecords(count)),
                ]
            )
            XCTAssertEqual(snapshot.createCount, 1, "active count \(count)")
            XCTAssertEqual(snapshot.replaceRequiredCount, 0)
            XCTAssertEqual(transport.postCount, 0)
        }

        let five = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(unrelatedRecords(5)),
            ]
        ).0
        XCTAssertEqual(five.replaceRequiredCount, 1)
        XCTAssertEqual(five.items[0].replacementCandidates.count, 5)

        let six = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(unrelatedRecords(6)),
            ]
        ).0
        XCTAssertEqual(six.blockedCount, 1)
        XCTAssertEqual(six.items[0].reason, "CAPACITY_EXCEEDED")
    }

    func testExactMatchRemainsZeroWriteNoOpAboveCapacity() async throws {
        let records = unrelatedRecords(6) + [phraseRecord(id: "INVALID_EXACT")]
        let (snapshot, transport, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(records),
            ]
        )
        XCTAssertEqual(snapshot.alreadyMatchingCount, 1)
        XCTAssertEqual(snapshot.blockedCount, 0)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: snapshot))
    }

    func testDeletedRecordsDoNotConsumeCapacityConflictOrCandidateSlots() async throws {
        let deletedSameEnglish = phraseRecord(
            id: "INVALID_DELETED",
            chinese: "旧翻译。",
            status: "DELETED"
        )
        let below = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(unrelatedRecords(4) + [deletedSameEnglish]),
            ]
        ).0
        XCTAssertEqual(below.createCount, 1)
        XCTAssertEqual(below.items[0].activeCount, 4)

        let full = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(unrelatedRecords(5) + [deletedSameEnglish]),
            ]
        ).0
        XCTAssertEqual(full.replaceRequiredCount, 1)
        XCTAssertEqual(full.items[0].replacementCandidates.count, 5)
        XCTAssertFalse(full.items[0].replacementCandidates.contains { $0.status == "DELETED" })
        XCTAssertEqual(full.items[0].collectionBaseline.count, 6)
    }

    func testUnsupportedPhraseStatusFailsClosed() async throws {
        let (snapshot, _, _) = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse([
                    phraseRecord(
                        id: "INVALID_UNSUPPORTED",
                        phrase: "Other sentence.",
                        chinese: "其他。",
                        status: "UNPUBLISHED"
                    ),
                ]),
            ]
        )
        XCTAssertEqual(snapshot.blockedCount, 1)
        XCTAssertEqual(snapshot.items[0].reason, "READ_FAILED")
    }

    func testServerResponseReorderDoesNotCreateFalseStaleAuthority() async throws {
        let baseline = unrelatedRecords(2)
        let shown = try await makePhraseSnapshot(
            document: document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(baseline),
            ]
        ).0
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"),
            phrasesResponse(Array(baseline.reversed())),
            jsonResponse([:], status: 201),
            phrasesResponse(Array(baseline.reversed()) + [phraseRecord()]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(transport.postCount, 1)
    }

    func testReplacementSelectionAndBindingAreCanonicalAndSessionBound() async throws {
        let records = unrelatedRecords(5)
        let shown = try await replacementSnapshot(records: records)
        let reordered = try await replacementSnapshot(records: Array(records.reversed()))
        let session = UUID(uuidString: "00000000-0000-0000-0000-000000000089")!
        let first = try PhraseReplacementBinding.makeApproval(
            snapshot: shown,
            candidateKey: 1,
            sessionID: session
        )
        let reorderedApproval = try PhraseReplacementBinding.makeApproval(
            snapshot: reordered,
            candidateKey: 1,
            sessionID: session
        )
        XCTAssertEqual(first, reorderedApproval)
        XCTAssertNotEqual(
            first,
            try PhraseReplacementBinding.makeApproval(
                snapshot: shown,
                candidateKey: 2,
                sessionID: session
            )
        )
        XCTAssertNotEqual(
            first,
            try PhraseReplacementBinding.makeApproval(
                snapshot: shown,
                candidateKey: 1,
                sessionID: UUID()
            )
        )

        let rendered = String(describing: shown.presentation)
        XCTAssertFalse(rendered.contains("INVALID_CAPACITY_"))
        XCTAssertEqual(shown.presentation.rows[0].replacementCandidates.map(\.key), [1, 2, 3, 4, 5])
    }

    func testReplacementUsesExactDocumentedRouteBodyAndHardReadback() async throws {
        let baseline = unrelatedRecords(5)
        let shown = try await replacementSnapshot(records: baseline)
        var updated = baseline
        updated[1] = phraseRecord(id: "INVALID_CAPACITY_2")
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"),
            phrasesResponse(Array(baseline.reversed())),
            jsonResponse([:]),
            phrasesResponse(Array(updated.reversed())),
        ])
        let summary = try await executeReplacement(
            snapshot: shown,
            candidateKey: 2,
            transport: transport
        )
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.confirmed])
        XCTAssertEqual(
            transport.requests.map(\.route),
            [
                .vocabulary(spelling: "acquisition"),
                .phrases(vocabularyID: "INVALID_VOC"),
                .updatePhrase(recordID: "INVALID_CAPACITY_2"),
                .phrases(vocabularyID: "INVALID_VOC"),
            ]
        )
        XCTAssertEqual(transport.postCount, 1)

        let body = try XCTUnwrap(transport.requests[2].body)
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(Set(root.keys), ["phrase"])
        let phrase = try XCTUnwrap(root["phrase"] as? [String: Any])
        XCTAssertEqual(Set(phrase.keys), ["phrase", "interpretation", "tags", "origin"])
        XCTAssertEqual(phrase["phrase"] as? String, english)
        XCTAssertEqual(phrase["interpretation"] as? String, chinese)
        XCTAssertEqual(phrase["origin"] as? String, "自编")
        XCTAssertEqual(phrase["tags"] as? [String], CompanionConstants.tags)
        for forbidden in ["voc_id", "id", "status", "highlight", "range", "chinese_range"] {
            XCTAssertNil(phrase[forbidden], forbidden)
        }
    }

    func testReplacementUncertainPOSTRecoversWithGETOnlyAndNeverReplays() async throws {
        let baseline = unrelatedRecords(5)
        let shown = try await replacementSnapshot(records: baseline)
        var updated = baseline
        updated[0] = phraseRecord(id: "INVALID_CAPACITY_1")
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse(baseline),
            .failure(.transport), phrasesResponse(updated),
        ])
        let summary = try await executeReplacement(
            snapshot: shown,
            candidateKey: 1,
            transport: transport
        )
        XCTAssertEqual(summary.results.map(\.outcome), [.recovered])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(transport.requests.suffix(2).map(\.route.method), [.post, .get])
    }

    func testReplacementWrongTargetContentSourceStatusOrDuplicateIsNotVerified() async throws {
        let baseline = unrelatedRecords(5)
        let cases: [[[String: Any]]] = {
            var wrongTarget = baseline
            wrongTarget[1] = phraseRecord(id: "INVALID_CAPACITY_2")
            var wrongText = baseline
            wrongText[0] = phraseRecord(id: "INVALID_CAPACITY_1", phrase: "Wrong text.")
            var wrongSource = baseline
            wrongSource[0] = phraseRecord(id: "INVALID_CAPACITY_1", source: "错误来源")
            var wrongStatus = baseline
            wrongStatus[0] = phraseRecord(id: "INVALID_CAPACITY_1", status: "DELETED")
            var duplicate = baseline
            duplicate[0] = phraseRecord(id: "INVALID_CAPACITY_1")
            duplicate[1] = phraseRecord(id: "INVALID_CAPACITY_2")
            return [wrongTarget, wrongText, wrongSource, wrongStatus, duplicate]
        }()

        for readback in cases {
            let shown = try await replacementSnapshot(records: baseline)
            let transport = FakeHTTPTransport([
                vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse(baseline),
                jsonResponse([:]), phrasesResponse(readback),
            ])
            let summary = try await executeReplacement(
                snapshot: shown,
                candidateKey: 1,
                transport: transport
            )
            XCTAssertEqual(summary.failed, 1)
            XCTAssertEqual(summary.results.map(\.outcome), [.notVerified])
            XCTAssertEqual(transport.postCount, 1)
        }
    }

    func testReplacementTagAndHighlightDifferencesRemainNonBlockingObservations() async throws {
        let baseline = unrelatedRecords(5)
        let shown = try await replacementSnapshot(records: baseline)
        var updated = baseline
        updated[0] = phraseRecord(
            id: "INVALID_CAPACITY_1",
            tags: ["MBA"],
            highlight: nil
        )
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse(baseline),
            jsonResponse([:]), phrasesResponse(updated),
        ])
        let summary = try await executeReplacement(
            snapshot: shown,
            candidateKey: 1,
            transport: transport
        )
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(
            summary.results[0].observations,
            [.tagsDiffer, .highlightMissing, .chineseRangeUnavailable]
        )
    }

    func testReplacementDraftCredentialCandidateBaselineAndCollectionChangesSendZeroPOST() async throws {
        let baseline = unrelatedRecords(5)
        let shown = try await replacementSnapshot(records: baseline)
        let session = UUID(uuidString: "00000000-0000-0000-0000-000000000089")!
        let approval = try PhraseReplacementBinding.makeApproval(
            snapshot: shown,
            candidateKey: 1,
            sessionID: session
        )

        let changedDocument = document.replacingOccurrences(of: chinese, with: "改变。")
        let changedDraft = try await replacementSnapshot(
            records: baseline,
            document: changedDocument
        )
        XCTAssertNotEqual(
            approval,
            try PhraseReplacementBinding.makeApproval(
                snapshot: changedDraft,
                candidateKey: 1,
                sessionID: session
            )
        )
        let changedCredential = try await replacementSnapshot(
            records: baseline,
            token: "FAKE_OTHER_TOKEN_NOT_VALID"
        )
        XCTAssertNotEqual(
            approval,
            try PhraseReplacementBinding.makeApproval(
                snapshot: changedCredential,
                candidateKey: 1,
                sessionID: session
            )
        )

        let changedDraftTransport = FakeHTTPTransport([])
        let changedDraftSummary = try await executeReplacement(
            snapshot: changedDraft,
            candidateKey: 1,
            transport: changedDraftTransport,
            approval: approval,
            sessionID: session
        )
        XCTAssertTrue(changedDraftSummary.stalePreview)
        XCTAssertEqual(changedDraftTransport.postCount, 0)
        XCTAssertTrue(changedDraftTransport.requests.isEmpty)

        let changedCredentialTransport = FakeHTTPTransport([])
        let changedCredentialSummary = try await executeReplacement(
            snapshot: shown,
            candidateKey: 1,
            transport: changedCredentialTransport,
            approval: approval,
            sessionID: session,
            token: "FAKE_OTHER_TOKEN_NOT_VALID"
        )
        XCTAssertTrue(changedCredentialSummary.stalePreview)
        XCTAssertEqual(changedCredentialTransport.postCount, 0)
        XCTAssertTrue(changedCredentialTransport.requests.isEmpty)

        let changedSessionTransport = FakeHTTPTransport([])
        let changedSessionSummary = try await executeReplacement(
            snapshot: shown,
            candidateKey: 1,
            transport: changedSessionTransport,
            approval: approval,
            sessionID: UUID()
        )
        XCTAssertTrue(changedSessionSummary.stalePreview)
        XCTAssertEqual(changedSessionTransport.postCount, 0)
        XCTAssertTrue(changedSessionTransport.requests.isEmpty)

        var changedBaseline = baseline
        changedBaseline[0] = phraseRecord(
            id: "INVALID_CAPACITY_1",
            phrase: "Changed baseline.",
            chinese: "改变基线。"
        )
        let freshChanges = [
            changedBaseline,
            baseline + [phraseRecord(
                id: "INVALID_DELETED_EXTRA",
                phrase: "Deleted extra.",
                chinese: "已删除。",
                status: "DELETED"
            )],
            Array(baseline.dropFirst()) + [phraseRecord(
                id: "INVALID_CAPACITY_CHANGED",
                phrase: "Changed identity.",
                chinese: "身份改变。"
            )],
        ]
        for fresh in freshChanges {
            let transport = FakeHTTPTransport([
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(fresh),
            ])
            let summary = try await executeReplacement(
                snapshot: shown,
                candidateKey: 1,
                transport: transport,
                approval: approval,
                sessionID: session
            )
            XCTAssertTrue(summary.stalePreview)
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
            tags: CompanionConstants.tags,
            createPath: "/open/api/v1/phrases/other"
        )
        XCTAssertThrowsError(try PhraseCreateBinding.makeApproval(snapshot: changedPath))

        let conflict = PhrasePreflightItem(
            entry: shown.items[0].entry,
            classification: .blocked,
            vocabularyID: "INVALID_VOC",
            collectionBaseline: [PhraseRecord(
                id: "INVALID_RECORD",
                phrase: english,
                interpretation: "changed",
                tags: nil,
                origin: "自编",
                status: "PUBLISHED",
                highlight: .missing
            )],
            replacementCandidates: [],
            reason: "CONFLICTING_SAME_ENGLISH"
        )
        let changedBaseline = PhrasePreviewSnapshot(
            sourceIdentity: shown.sourceIdentity,
            credentialFingerprint: shown.credentialFingerprint,
            accountMode: shown.accountMode,
            bindingContext: try PhraseCreateBinding.makePreviewBindingContext(items: [conflict]),
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
            vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse([]),
            jsonResponse([:], status: 201), phrasesResponse([phraseRecord(highlight: [[4, 15]])]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.succeeded, 1)
        XCTAssertEqual(summary.results.map(\.outcome), [.confirmed])
        XCTAssertEqual(
            transport.requests.map(\.route),
            [
                .vocabulary(spelling: "acquisition"),
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
        XCTAssertEqual(phrase["tags"] as? [String], CompanionConstants.tags)
        XCTAssertEqual(phrase["origin"] as? String, "自编")
        for forbidden in ["highlight", "status", "id", "range", "chinese_range"] {
            XCTAssertNil(phrase[forbidden])
        }
    }

    func testFreshConflictInvalidatesApprovalBeforePOST() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"),
            phrasesResponse([phraseRecord(chinese: "changed")]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertTrue(summary.stalePreview)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testUnrelatedFreshMembershipChangeInvalidatesCreate() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"),
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
        XCTAssertTrue(summary.stalePreview)
        XCTAssertEqual(transport.postCount, 0)
    }

    func testUncertainPOSTUsesGETOnlyRecoveryAndNeverRetries() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse([]),
            .failure(.transport), phrasesResponse([phraseRecord()]),
        ])
        let summary = try await executePhrase(snapshot: shown, transport: transport)
        XCTAssertEqual(summary.results.map(\.outcome), [.recovered])
        XCTAssertEqual(transport.postCount, 1)
        XCTAssertEqual(transport.requests.suffix(2).map(\.route.method), [.post, .get])
    }

    func testMultiEntryBatchDispatchesAtMostOnePOSTPerCreateItem() async throws {
        let batch = document + """


        ## liquidity
        EN: Liquidity matters.
        ZH: 流动性很重要。
        SOURCE: 自编
        """
        let initial: [StubbedResult] = [
            vocabularyResponse("INVALID_VOC_A", "acquisition"), phrasesResponse([]),
            vocabularyResponse("INVALID_VOC_B", "liquidity"), phrasesResponse([]),
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
            transport.requests.filter { $0.route.method == .post }.map(\.route),
            [.createPhrase, .createPhrase]
        )
    }

    func testTagAndHighlightImperfectionsRemainVerifiedClosedObservations() async throws {
        let shown = try await createSnapshot(document: document)
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse([]),
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
                vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse([]),
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
                vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse([]),
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
                vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse([]),
                jsonResponse([:], status: 201), phrasesResponse(records),
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
            vocabularyResponse("INVALID_VOC", "acquisition"), phrasesResponse([]),
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
            vocabularyResponse("INVALID_VOC_A", "acquisition"), phrasesResponse([]),
            vocabularyResponse("INVALID_VOC_B", "liquidity"), phrasesResponse([]),
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
            vocabularyResponse("INVALID_VOC_A", "acquisition"), phrasesResponse([]),
            vocabularyResponse("INVALID_VOC_B", "liquidity"), phrasesResponse([]),
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
        XCTAssertEqual(transport.requests.suffix(2).map(\.route.method), [.post, .get])
    }

    func testPhraseCoreDefinesReviewedUpdateButNoDeleteRollbackOrReplayRoute() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let core = testsDirectory.deletingLastPathComponent()
            .appendingPathComponent("MomoMoreEfficient/Core")
        let sources = try ["HTTPTransport.swift", "PhraseCreateCore.swift"].map {
            try String(contentsOf: core.appendingPathComponent($0), encoding: .utf8)
        }.joined(separator: "\n")
        XCTAssertTrue(sources.contains("updatePhrase"))
        for forbidden in ["deletePhrase", "replayPhrase", "rollbackPhrase"] {
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
        tags: Any? = CompanionConstants.tags,
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
            XCTAssertEqual(error as? CompanionError, .responseRejected, file: file, line: line)
        }
    }

    private func makePhraseSnapshot(
        document: String,
        results: [StubbedResult],
        token: String = fakeToken
    ) async throws -> (PhrasePreviewSnapshot, FakeHTTPTransport, RecordingSleeper) {
        let entries = try PhraseBatchParser.parse(document)
        let transport = FakeHTTPTransport(results)
        let sleeper = RecordingSleeper()
        let lease = try credentialLease(token)
        let api = MaimemoTransport(transport: transport, credential: lease, sleeper: sleeper)
        let snapshot = try await PhrasePreflightPlanner(api: api).buildSnapshot(
            entries: entries,
            credentialFingerprint: lease.fingerprint
        )
        lease.clear()
        return (snapshot, transport, sleeper)
    }

    private func createSnapshot(
        document: String,
        token: String = fakeToken
    ) async throws -> PhrasePreviewSnapshot {
        let entries = try PhraseBatchParser.parse(document)
        var results: [StubbedResult] = []
        for entry in entries {
            let vocabularyID = entries.count == 1
                ? "INVALID_VOC"
                : "INVALID_VOC_\(entry.ordinal)"
            results.append(vocabularyResponse(vocabularyID, entry.spelling))
            results.append(phrasesResponse([]))
        }
        let snapshot = try await makePhraseSnapshot(
            document: document,
            results: results,
            token: token
        )
        return snapshot.0
    }

    private func executePhrase(
        snapshot: PhrasePreviewSnapshot,
        transport: FakeHTTPTransport,
        control: ExecutionControl = ExecutionControl()
    ) async throws -> PhraseExecutionSummary {
        let lease = try credentialLease()
        let executor = PhraseWriteExecutor(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
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

    private func unrelatedRecords(_ count: Int) -> [[String: Any]] {
        (0..<count).map { offset in
            let index = offset + 1
            return phraseRecord(
                id: "INVALID_CAPACITY_\(index)",
                phrase: "Unrelated capacity phrase \(index).",
                chinese: "无关容量例句 \(index)。",
                source: "来源 \(index)"
            )
        }
    }

    private func replacementSnapshot(
        records: [[String: Any]],
        document: String? = nil,
        token: String = fakeToken
    ) async throws -> PhrasePreviewSnapshot {
        try await makePhraseSnapshot(
            document: document ?? self.document,
            results: [
                vocabularyResponse("INVALID_VOC", "acquisition"),
                phrasesResponse(records),
            ],
            token: token
        ).0
    }

    private func executeReplacement(
        snapshot: PhrasePreviewSnapshot,
        candidateKey: Int,
        transport: FakeHTTPTransport,
        approval: PhraseReplacementApproval? = nil,
        sessionID: UUID = UUID(uuidString: "00000000-0000-0000-0000-000000000089")!,
        token: String = fakeToken
    ) async throws -> PhraseExecutionSummary {
        let lease = try credentialLease(token)
        let executor = PhraseReplacementExecutor(
            api: MaimemoTransport(
                transport: transport,
                credential: lease,
                sleeper: RecordingSleeper()
            )
        )
        let effectiveApproval = try approval ?? PhraseReplacementBinding.makeApproval(
            snapshot: snapshot,
            candidateKey: candidateKey,
            sessionID: sessionID
        )
        let summary = await executor.execute(
            displayedSnapshot: snapshot,
            approval: effectiveApproval,
            sessionID: sessionID,
            control: ExecutionControl()
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
                updatePathTemplate: snapshot.bindingContext.updatePathTemplate,
                tags: tags,
                expectedStatus: snapshot.bindingContext.expectedStatus,
                createBatchDigest: snapshot.bindingContext.createBatchDigest
            ),
            items: snapshot.items
        )
    }
}
