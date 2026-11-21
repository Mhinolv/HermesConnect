import Foundation
import Testing
@testable import HermesKit

/// Issue #170: a recognizer that the test drives.
@MainActor
private final class FakeSpeechSource: LiveSpeechSource {
    var failure: LiveDictationFailure?
    private(set) var starts = 0
    private(set) var finishes = 0
    private(set) var cancels = 0
    private var continuation: AsyncThrowingStream<LiveDictationEvent, any Error>.Continuation?
    /// Results that `finish()` gives before the stream ends.
    var lastResults: [LiveDictationEvent] = []

    func start() async throws(LiveDictationFailure) -> AsyncThrowingStream<LiveDictationEvent, any Error> {
        starts += 1
        if let failure { throw failure }
        let (stream, continuation) = AsyncThrowingStream<LiveDictationEvent, any Error>.makeStream()
        self.continuation = continuation
        return stream
    }

    func finish() async {
        finishes += 1
        for event in lastResults { continuation?.yield(event) }
        continuation?.finish()
    }

    func cancel() {
        cancels += 1
        continuation?.finish()
    }

    func send(_ event: LiveDictationEvent) { continuation?.yield(event) }
    func fail() { continuation?.finish(throwing: CancellationError()) }
}

@MainActor
private func settle(_ dictation: LiveDictation, until done: (LiveDictation) -> Bool) async {
    for _ in 0..<200 where !done(dictation) {
        await Task.yield()
    }
}

@Suite struct DictationTextTests {
    @Test func partialWordsGoAfterTheFinalPhrases() {
        let text = DictationText.compose(before: "", final: "Book the", partial: "flight")
        #expect(text.text == "Book the flight")
        #expect(text.partialRange == NSRange(location: 9, length: 6))
    }

    @Test func textTypedBeforeStaysInFront() {
        let text = DictationText.compose(before: "Note:", final: "call Sam", partial: "")
        #expect(text.text == "Note: call Sam")
        #expect(text.partialRange.length == 0)
        #expect(DictationText.compose(before: "Note: ", final: "call Sam", partial: "").text == "Note: call Sam")
    }

    @Test func noDoubleSpacesAndNoLeadingSpace() {
        #expect(DictationText.compose(before: "", final: " Hello", partial: " there").text == "Hello there")
        #expect(DictationText.join("Hi ", " there") == "Hi  there")
        #expect(DictationText.join("Hi", "there") == "Hi there")
    }

    @Test func rangesCountUTF16Units() {
        let text = DictationText.compose(before: "Café 👋", final: "", partial: "ok")
        #expect((text.text as NSString).substring(with: text.partialRange) == "ok")
    }
}

@MainActor @Suite struct LiveDictationTests {
    @Test func partialWordsShowThenTheFinalPhraseTakesTheirPlace() async {
        let source = FakeSpeechSource()
        let dictation = LiveDictation(source: source)
        var shown: [String] = []
        dictation.onText = { shown.append($0.text) }
        dictation.start(after: "")
        await settle(dictation) { $0.state == .listening }
        source.send(.partial("Book"))
        source.send(.partial("Book the"))
        source.send(.final("Book the flight."))
        source.send(.partial("For"))
        await settle(dictation) { $0.current.text == "Book the flight. For" }
        #expect(shown == ["Book", "Book the", "Book the flight.", "Book the flight. For"])
        #expect(dictation.current.partialRange == NSRange(location: 17, length: 3))
    }

    @Test func stopKeepsTheLastFinalPhraseAndNeverSends() async {
        let source = FakeSpeechSource()
        source.lastResults = [.final("Call Sam at noon")]
        let dictation = LiveDictation(source: source)
        dictation.start(after: "Reminder:")
        await settle(dictation) { $0.state == .listening }
        source.send(.partial("Call Sam"))
        dictation.stop()
        #expect(dictation.state == .finishing)
        await settle(dictation) { $0.state == .idle }
        #expect(source.finishes == 1)
        #expect(dictation.current.text == "Reminder: Call Sam at noon")
        #expect(dictation.current.partialRange.length == 0)
    }

    @Test func cancelKeepsThePartialWordsAsText() async {
        let source = FakeSpeechSource()
        let dictation = LiveDictation(source: source)
        dictation.start(after: "")
        await settle(dictation) { $0.state == .listening }
        source.send(.partial("half a"))
        await settle(dictation) { $0.current.text == "half a" }
        dictation.cancel()
        #expect(dictation.state == .idle)
        #expect(source.cancels == 1)
        #expect(dictation.current.text == "half a")
        #expect(dictation.current.partialRange.length == 0)
        // A late result of the cancelled run changes nothing.
        source.send(.final("half a sentence"))
        await Task.yield()
        #expect(dictation.current.text == "half a")
    }

    @Test func aStartFailureShowsTheReasonAndKeepsTheText() async {
        let source = FakeSpeechSource()
        source.failure = .modelNotInstalled
        let dictation = LiveDictation(source: source)
        var failures: [LiveDictationFailure] = []
        dictation.onFailure = { failures.append($0) }
        dictation.start(after: "Typed")
        await settle(dictation) { $0.state == .idle }
        #expect(failures == [.modelNotInstalled])
        #expect(dictation.current.text == "Typed")
    }

    @Test func aRecognizerErrorEndsWithTheWordsSoFar() async {
        let source = FakeSpeechSource()
        let dictation = LiveDictation(source: source)
        var failures: [LiveDictationFailure] = []
        dictation.onFailure = { failures.append($0) }
        dictation.start(after: "")
        await settle(dictation) { $0.state == .listening }
        source.send(.final("Hello"))
        source.send(.partial("wor"))
        source.fail()
        await settle(dictation) { $0.state == .idle }
        #expect(failures == [.failed])
        #expect(dictation.current.text == "Hello wor")
    }

    @Test func aSecondStartWhileActiveDoesNothing() async {
        let source = FakeSpeechSource()
        let dictation = LiveDictation(source: source)
        dictation.start(after: "")
        dictation.start(after: "other")
        await settle(dictation) { $0.state == .listening }
        #expect(source.starts == 1)
        #expect(dictation.current.text == "")
    }

    @Test func cancelWithNoPublishKeepsWhatTheOwnerTyped() async {
        let source = FakeSpeechSource()
        let dictation = LiveDictation(source: source)
        var shown: [String] = []
        dictation.start(after: "")
        await settle(dictation) { $0.state == .listening }
        source.send(.partial("Hel"))
        await settle(dictation) { $0.current.text == "Hel" }
        dictation.onText = { shown.append($0.text) }
        dictation.cancel(publish: false)
        #expect(dictation.state == .idle)
        #expect(shown.isEmpty)
    }

    @Test func eachFinalPhraseIsAnnouncedOnce() async {
        let source = FakeSpeechSource()
        let dictation = LiveDictation(source: source)
        var phrases: [String] = []
        dictation.onFinal = { phrases.append($0) }
        dictation.start(after: "")
        await settle(dictation) { $0.state == .listening }
        source.send(.partial("One"))
        source.send(.final("One two."))
        source.send(.final(" "))
        await settle(dictation) { _ in phrases.count == 1 }
        #expect(phrases == ["One two."])
    }
}
