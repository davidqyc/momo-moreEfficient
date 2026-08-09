import XCTest
@testable import MomoMoreEfficient

@MainActor
final class CompanionViewModelTests: XCTestCase {
    func testInputEditImmediatelyInvalidatesPreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        XCTAssertNotNil(model.preview)
        model.sourceText += "。"
        XCTAssertNil(model.preview)
    }

    func testCredentialChangeImmediatelyInvalidatesPreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        XCTAssertNotNil(model.preview)
        var replacement = "FAKE_REPLACEMENT_TOKEN_NOT_VALID"
        model.connect(token: &replacement)
        XCTAssertNil(model.preview)
        XCTAssertTrue(replacement.isEmpty)
    }

    func testBackgroundClearsCredentialAndPreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.enterBackground()
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
    }

    func testBackgroundCancelsPreviewBeforeItsNextGET() async {
        let transport = FakeHTTPTransport([
            vocabularyResponse("INVALID_VOC", "word"),
            interpretationsResponse([]),
        ])
        let gate = GateSleeper()
        let model = CompanionViewModel(
            transportFactory: { transport },
            sleeperFactory: { gate }
        )
        var draft = fakeToken
        model.connect(token: &draft)
        model.sourceText = "word\nn. 新建"

        let previewTask = Task { await model.previewCurrentInput() }
        await gate.waitUntilEntered()
        model.enterBackground()
        await gate.resume()
        await previewTask.value

        XCTAssertEqual(transport.getCount, 1)
        XCTAssertEqual(transport.postCount, 0)
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
    }

    func testExplicitDisconnectDoesTheSameImmediately() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        model.disconnect()
        XCTAssertFalse(model.isConnected)
        XCTAssertNil(model.preview)
    }

    func testCompletedCreateInvalidatesExecutablePreview() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
            [
                vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([]),
                jsonResponse([:], status: 201),
                interpretationsResponse([interpretation("INVALID_RECORD", "n. 新建")]),
            ],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        XCTAssertNotNil(model.preview)
        await model.executeConfirmed(.create)
        XCTAssertNil(model.preview)
        XCTAssertEqual(model.finalSummary.created, 1)
    }

    func testPublicStateAndErrorsNeverExposeFakeToken() async {
        let factory = SequencedTransportFactory([
            [vocabularyResponse("INVALID_VOC", "word"), interpretationsResponse([])],
        ])
        let model = connectedModel(factory)
        model.sourceText = "word\nn. 新建"
        await model.previewCurrentInput()
        let rendered = String(describing: model.preview)
            + String(describing: model.finalSummary)
            + String(describing: model.errorMessage)
        XCTAssertFalse(rendered.contains(fakeToken))
    }

    private func connectedModel(_ factory: SequencedTransportFactory) -> CompanionViewModel {
        let model = CompanionViewModel(
            transportFactory: factory.make,
            sleeperFactory: { RecordingSleeper() }
        )
        var draft = fakeToken
        model.connect(token: &draft)
        XCTAssertTrue(draft.isEmpty)
        return model
    }
}

final class SequencedTransportFactory: @unchecked Sendable {
    private var runs: [[StubbedResult]]
    private(set) var transports: [FakeHTTPTransport] = []

    init(_ runs: [[StubbedResult]]) {
        self.runs = runs
    }

    func make() -> HTTPTransport {
        guard !runs.isEmpty else { return FakeHTTPTransport([]) }
        let transport = FakeHTTPTransport(runs.removeFirst())
        transports.append(transport)
        return transport
    }
}
