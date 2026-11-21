import Foundation
import Observation

/// Issue #170: one result of a live recognizer. A partial result replaces the partial before it. A final result
/// ends that phrase, and the next partial starts a new one.
public enum LiveDictationEvent: Sendable, Equatable {
    case partial(String)
    case final(String)
}

/// Issue #170: why dictation could not start or stopped early.
public enum LiveDictationFailure: Error, Sendable, Equatable {
    /// The owner did not allow the microphone.
    case microphoneOff
    /// The Apple speech model for the language is not on the iPhone.
    case modelNotInstalled
    /// The iPhone or the language has no on-device speech.
    case unsupported
    /// The audio did not start, or the recognizer failed.
    case failed
}

/// Issue #170: the microphone and the on-device recognizer. The app gives Apple `SpeechTranscriber`. Tests give a fake.
@MainActor
public protocol LiveSpeechSource: AnyObject {
    /// Starts the microphone. The stream ends after `finish()` gave the last final results, or after `cancel()`.
    func start() async throws(LiveDictationFailure) -> AsyncThrowingStream<LiveDictationEvent, any Error>
    /// Stops the microphone. The recognizer gives the final results of the audio it has, then the stream ends.
    func finish() async
    /// Stops the microphone and the recognizer at once, with no more results.
    func cancel()
}

/// Issue #170: the text of the message box during dictation.
public struct DictationText: Equatable, Sendable {
    /// The whole text of the box.
    public var text: String
    /// The partial words at the end of `text`, in UTF-16 units. The box shows them in a lighter color.
    public var partialRange: NSRange

    /// The text before the dictation, then the final phrases, then the partial words.
    public static func compose(before: String, final: String, partial: String) -> DictationText {
        let settled = join(before, final)
        let text = join(settled, partial)
        // The space that `join` puts in front is not part of the partial words.
        let shown = settled.isEmpty ? String(partial.drop { $0.isWhitespace }) : partial
        let partialLength = (shown as NSString).length
        return DictationText(text: text,
                             partialRange: NSRange(location: (text as NSString).length - partialLength, length: partialLength))
    }

    /// Puts one space between two parts when neither part has one at the join.
    static func join(_ first: String, _ second: String) -> String {
        let second = first.isEmpty ? String(second.drop { $0.isWhitespace }) : second
        guard !first.isEmpty, !second.isEmpty else { return first + second }
        if first.last?.isWhitespace == true || second.first?.isWhitespace == true { return first + second }
        return first + " " + second
    }
}

/// Issue #170: live dictation into the message box of a chat.
///
/// - `start(after:)` keeps the text that is in the box. The dictated words go after it.
/// - Partial words show at once. A final phrase takes their place.
/// - `stop()` waits for the last final phrase. The text stays in the box: dictation never sends.
/// - No audio and no text go to a log.
@MainActor @Observable
public final class LiveDictation {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case listening
        /// The microphone stopped. The last final phrase can still come.
        case finishing
    }

    public private(set) var state: State = .idle
    /// The text of the box now.
    public private(set) var current = DictationText(text: "", partialRange: NSRange(location: 0, length: 0))
    /// The box changed: show `current`.
    @ObservationIgnored public var onText: ((DictationText) -> Void)?
    /// The state changed.
    @ObservationIgnored public var onState: ((State) -> Void)?
    /// A phrase became final. VoiceOver reads it once.
    @ObservationIgnored public var onFinal: ((String) -> Void)?
    /// Dictation could not start, or stopped with an error.
    @ObservationIgnored public var onFailure: ((LiveDictationFailure) -> Void)?

    @ObservationIgnored private let source: any LiveSpeechSource
    @ObservationIgnored private var before = ""
    @ObservationIgnored private var final = ""
    @ObservationIgnored private var partial = ""
    @ObservationIgnored private var task: Task<Void, Never>?
    /// One more on each start and cancel. Results of an older run change nothing.
    @ObservationIgnored private var run = 0

    public init(source: any LiveSpeechSource) {
        self.source = source
    }

    /// `true` from the start until the last result is in the box.
    public var isActive: Bool { state != .idle }

    /// Starts the microphone. `text` is the text of the box now.
    public func start(after text: String) {
        guard state == .idle else { return }
        run += 1
        let run = run
        before = text
        final = ""
        partial = ""
        current = DictationText.compose(before: text, final: "", partial: "")
        set(.starting)
        task = Task { [weak self] in
            guard let self else { return }
            let stream: AsyncThrowingStream<LiveDictationEvent, any Error>
            do throws(LiveDictationFailure) {
                stream = try await source.start()
            } catch {
                guard self.run == run else { return }
                self.end(failure: error)
                return
            }
            guard self.run == run else { return }
            if state == .starting { set(.listening) }
            do {
                for try await event in stream {
                    guard self.run == run else { return }
                    apply(event)
                }
                guard self.run == run else { return }
                end(failure: nil)
            } catch {
                guard self.run == run else { return }
                end(failure: .failed)
            }
        }
    }

    /// The owner tapped Stop Dictation. The last final phrase goes in the box, then the state is idle.
    public func stop() {
        switch state {
        case .starting:
            cancel()
        case .listening:
            set(.finishing)
            Task { await source.finish() }
        case .idle, .finishing:
            break
        }
    }

    /// Stops at once (leaving the chat, the background). The partial words stay as text.
    /// - Parameter publish: `false` when the box already has the text to keep (the owner typed, or sent).
    public func cancel(publish: Bool = true) {
        guard state != .idle else { return }
        run += 1
        source.cancel()
        task?.cancel()
        task = nil
        final = DictationText.join(final, partial)
        partial = ""
        if publish { self.publish() }
        set(.idle)
    }

    private func apply(_ event: LiveDictationEvent) {
        switch event {
        case let .partial(text):
            partial = text
        case let .final(text):
            final = DictationText.join(final, text)
            partial = ""
            let phrase = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !phrase.isEmpty { onFinal?(phrase) }
        }
        publish()
    }

    private func end(failure: LiveDictationFailure?) {
        task = nil
        final = DictationText.join(final, partial)
        partial = ""
        publish()
        set(.idle)
        if let failure { onFailure?(failure) }
    }

    private func publish() {
        let next = DictationText.compose(before: before, final: final, partial: partial)
        guard next != current else { return }
        current = next
        onText?(next)
    }

    private func set(_ next: State) {
        guard state != next else { return }
        state = next
        onState?(next)
    }
}
