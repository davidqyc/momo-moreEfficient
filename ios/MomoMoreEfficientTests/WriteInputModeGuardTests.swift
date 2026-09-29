import Foundation
import XCTest
@testable import MomoMoreEfficient

/// The #180 cross-mode write protection: a pure local, block-only guard.
///
/// Every test proves the frozen rules: strict phrase shapes block
/// interpretation mode; compact-POS or interpretation-only shapes block
/// phrase mode; both-parsers-accept ambiguity never blocks; ordinary valid
/// input in its own mode never false-blocks; a blocked guard provably causes
/// zero provider operations and zero transport requests; and the copied
/// diagnostic carries only selected/suggested/reason — never any content.
@MainActor
final class WriteInputModeGuardTests: XCTestCase {

    /// A multi-record native phrase document (the real wrong-mode incident
    /// shape): 3-line blocks the strict phrase grammar accepts.
    private let nativePhraseDocument = """
    apple
    A round fruit that keeps doctors away.
    一种让医生远离我的圆形水果。

    ledger
    The bank kept a careful ledger of every transaction.
    银行仔细记录了每一笔交易的账本。
    """

    /// Compact-POS interpretation text: spelling lines alternate with
    /// POS-prefixed definition lines — the strong interpretation signature.
    private let compactPOSDocument = """
    collapse
    v. 倒塌；崩溃
    ledger
    n. 账本；分类账
    """

    /// A plain two-line blank-delimited interpretation batch: no POS markers,
    /// so the interpretation parser accepts it as blank-delimited while the
    /// strict phrase grammar cannot.
    private let interpretationOnlyDocument = """
    apple
    一种让医生远离我的圆形水果，红色的果实

    ledger
    银行仔细记录了每一笔交易的账本
    """

    /// A plain two-line compact interpretation batch the phrase grammar
    /// cannot accept.
    private let plainInterpretationDocument = """
    apple
    n. 苹果；一种水果

    ledger
    n. 账本；分类账
    """

    // MARK: - Selected interpretation mode

    func testNativePhraseDocumentBlocksInterpretationMode() {
        let issue = WriteInputModeGuard.safetyIssue(
            document: nativePhraseDocument,
            selectedMode: .interpretation
        )
        XCTAssertEqual(
            issue,
            .looksLikePhrase(reason: .strictPhraseShape)
        )
        XCTAssertEqual(issue?.suggestedMode, .phrase)
    }

    func testOrdinaryInterpretationDoesNotFalseBlockInterpretationMode() {
        XCTAssertNil(WriteInputModeGuard.safetyIssue(
            document: plainInterpretationDocument,
            selectedMode: .interpretation
        ))
        XCTAssertNil(WriteInputModeGuard.safetyIssue(
            document: compactPOSDocument,
            selectedMode: .interpretation
        ))
    }

    func testEmptyDocumentNeverBlocks() {
        XCTAssertNil(WriteInputModeGuard.safetyIssue(document: "", selectedMode: .interpretation))
        XCTAssertNil(WriteInputModeGuard.safetyIssue(document: "", selectedMode: .phrase))
    }

    // MARK: - Selected phrase mode

    func testCompactPOSDocumentBlocksPhraseMode() {
        let issue = WriteInputModeGuard.safetyIssue(
            document: compactPOSDocument,
            selectedMode: .phrase
        )
        XCTAssertEqual(
            issue,
            .looksLikeInterpretation(reason: .compactPOS)
        )
        XCTAssertEqual(issue?.suggestedMode, .interpretation)
    }

    func testPhraseParserFailureWithInterpretationOnlyShapeBlocksPhraseMode() {
        // A blank-delimited, non-POS interpretation batch fails the strict
        // phrase grammar but parses as interpretations: the phrase path could
        // not proceed safely anyway, so the guard offers the interpretation
        // mode.
        let issue = WriteInputModeGuard.safetyIssue(
            document: interpretationOnlyDocument,
            selectedMode: .phrase
        )
        XCTAssertEqual(
            issue,
            .looksLikeInterpretation(reason: .interpretationOnlyShape)
        )
    }

    func testOrdinaryNativePhraseDoesNotBlockPhraseMode() {
        XCTAssertNil(WriteInputModeGuard.safetyIssue(
            document: nativePhraseDocument,
            selectedMode: .phrase
        ))
    }

    func testValidLegacyPhraseDoesNotBlockPhraseMode() {
        let legacyPhrase = """
        ## apple
        EN: A round fruit that keeps doctors away.
        ZH: 一种让医生远离我的圆形水果。
        SOURCE: Offline fixture

        ## ledger
        EN: The bank kept a careful ledger.
        ZH: 银行仔细记录了账本。
        SOURCE: Offline fixture
        """
        // Both parsers accept a legacy document ("## " triggers the legacy
        // path); ambiguity alone never blocks the selected strict phrase path.
        XCTAssertNotNil(try? PhraseBatchParser.parse(legacyPhrase))
        XCTAssertNil(WriteInputModeGuard.safetyIssue(
            document: legacyPhrase,
            selectedMode: .phrase
        ))
    }

    func testUnparseableInputIsLeftToTheSelectedParser() {
        let garbage = "彻底无法解析的内容 !!!"
        XCTAssertNil(WriteInputModeGuard.safetyIssue(document: garbage, selectedMode: .phrase))
        XCTAssertNil(WriteInputModeGuard.safetyIssue(document: garbage, selectedMode: .interpretation))
    }

    // MARK: - Blocked guard proves zero provider work

    /// A blocked mode mismatch must never reach the provider operation lane
    /// or the transport: previewing through the guard dispatches nothing.
    func testBlockedPreviewCausesZeroProviderOperationsAndZeroRequests() async {
        let transport = FakeHTTPTransport([])
        let model = makeModel(transport: transport)
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)
        model.sourceText = nativePhraseDocument

        await model.previewCurrentInput()

        XCTAssertNotNil(model.modeSafetyIssue)
        XCTAssertFalse(model.isBusy)
        XCTAssertFalse(model.isPreviewing)
        XCTAssertNil(model.activeProviderOperation)
        XCTAssertEqual(transport.requests.count, 0)
        XCTAssertEqual(transport.postCount, 0)
    }

    // MARK: - One-tap switch preserving text

    func testSwitchToPhrasePreservesExactDocumentBytes() {
        let model = makeModel(transport: FakeHTTPTransport([]))
        model.selectMode(.interpretation)
        let document = nativePhraseDocument + "\n"
        model.sourceText = document
        XCTAssertEqual(model.sourceText, document)
        XCTAssertNotNil(model.modeSafetyIssue)

        model.switchModePreservingCurrentText(to: .phrase)

        // Exact bytes remain the editor content, now under the phrase mode.
        XCTAssertEqual(model.contentMode, .phrase)
        XCTAssertEqual(model.sourceText, document)
        // The document parses cleanly in its correct mode: no guard verdict.
        XCTAssertNil(model.modeSafetyIssue)
        // The target mode's draft holds the same document, so leaving and
        // returning keeps it.
        model.selectMode(.interpretation)
        model.selectMode(.phrase)
        XCTAssertEqual(model.sourceText, document)
    }

    func testSwitchBackPreservesTextWhenGuardSuggestsInterpretation() {
        let model = makeModel(transport: FakeHTTPTransport([]))
        model.selectMode(.phrase)
        model.sourceText = compactPOSDocument
        XCTAssertEqual(
            model.modeSafetyIssue,
            .looksLikeInterpretation(reason: .compactPOS)
        )

        model.switchModePreservingCurrentText(to: .interpretation)

        XCTAssertEqual(model.contentMode, .interpretation)
        XCTAssertEqual(model.sourceText, compactPOSDocument)
        XCTAssertNil(model.modeSafetyIssue)
    }

    // MARK: - Diagnostic privacy

    func testGuardDiagnosticContainsOnlySelectedSuggestedReason() {
        let issue = WriteInputModeGuard.safetyIssue(
            document: nativePhraseDocument,
            selectedMode: .interpretation
        )
        let report = WriteModeGuardDiagnostics.report(selected: .interpretation, issue: issue!)
        XCTAssertTrue(report.contains("小黑鸟伴侣 Write Mode Guard Diagnostic v1"))
        XCTAssertTrue(report.contains("selected=interpretation"))
        XCTAssertTrue(report.contains("suggested=phrase"))
        XCTAssertTrue(report.contains("reason=strict_phrase_shape"))
        // Nothing else: no content, no extra lines.
        XCTAssertEqual(report.split(separator: "\n").count, 4)
    }

    func testGuardDiagnosticNeverContainsSuppliedContentOrToken() {
        let markedPhrase = nativePhraseDocument
            .replacingOccurrences(of: "apple", with: "SECRETSPELLING")
            .replacingOccurrences(of: "fruit", with: "SECRETCONTENT")
        let model = makeModel(transport: FakeHTTPTransport([]))
        model.selectMode(.interpretation)
        model.sourceText = markedPhrase
        var token = fakeToken
        model.installVerifiedCredentialForTesting(token: &token)

        let report = model.modeGuardReport() ?? ""

        XCTAssertFalse(report.contains("SECRETSPELLING"))
        XCTAssertFalse(report.contains("SECRETCONTENT"))
        XCTAssertFalse(report.contains(fakeToken))
    }

    // MARK: - Fixtures

    private func makeModel(transport: FakeHTTPTransport) -> CompanionViewModel {
        CompanionViewModel(
            phraseSafetyJournal: makeTestPhraseJournal(),
            tokenStore: FakeTokenStore(),
            historyStore: InMemoryHistoryStore(),
            transportFactory: { transport },
            credentialValidationTransportFactory: successfulCredentialValidationTransport,
            sleeperFactory: { RecordingSleeper() },
            preferenceDefaults: isolatedPreferenceDefaults()
        )
    }
}
