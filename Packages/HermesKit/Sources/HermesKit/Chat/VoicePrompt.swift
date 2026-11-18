import Foundation
import Observation

// Issue #121: Hermes prompts (approval, clarify, sudo, secret) in Hands-Free and Live. The Voice tab shows the same
// #104 or #117 card. On-device speech says one short line. On-device STT hears a spoken choice. Neither goes to the
// live model. A secret or a password is always typed: this file never sees the value, and never listens for it.

/// One card that waits in the session chat: an approval card (#104) or a prompt card (#117).
public struct VoicePromptItem: Sendable, Equatable, Identifiable {
    public enum Card: Sendable, Equatable {
        case approval(ChatApprovalCard)
        case prompt(ChatPromptCard)
    }

    /// The message id of the card in the chat.
    public var id: String
    public var card: Card

    public init(id: String, card: Card) {
        self.id = id
        self.card = card
    }

    /// The card of a chat message, or `nil` for a bubble.
    public init?(_ message: ChatMessage) {
        if let approval = message.approval {
            self.init(id: message.id, card: .approval(approval))
        } else if let prompt = message.prompt {
            self.init(id: message.id, card: .prompt(prompt))
        } else {
            return nil
        }
    }

    public var isWaiting: Bool {
        switch card {
        case .approval(let card): card.isWaiting
        case .prompt(let card): card.isWaiting
        }
    }

    /// A secret or a password: a typed field only. The microphone stays closed.
    public var isSecure: Bool {
        if case .prompt(let card) = card { return card.isSecure }
        return false
    }

    /// The one question that takes a spoken choice: a clarify card with one open question, with choices, and one
    /// pick. `nil` for the other clarify cards ("Answer on the screen").
    public var spokenQuestion: ClarifyQuestion? {
        guard case .prompt(let card) = card, case .clarify = card.kind else { return nil }
        let open = card.openQuestions
        guard open.count == 1, let question = open.first, !question.choices.isEmpty, !question.multiSelect else {
            return nil
        }
        return question
    }

    /// `true` when the owner can answer by voice: an approval, or a clarify card with one choice question.
    public var takesSpokenAnswer: Bool {
        switch card {
        case .approval(let card): !card.choices.isEmpty
        case .prompt: spokenQuestion != nil
        }
    }

    /// The words that the voice offers, in card order.
    public var spokenChoices: [String] {
        switch card {
        case .approval(let card): card.choices.map(VoicePromptSpeech.spokenName)
        case .prompt: spokenQuestion?.choices ?? []
        }
    }
}

/// What the owner said to a card.
public enum VoicePromptAnswer: Sendable, Equatable {
    case approval(ApprovalChoice)
    /// The choice text of the one open clarify question.
    case clarify(qid: String, choice: String)
    /// "stop": the loop ends.
    case stop
}

/// The lines of on-device speech (design notes table) and the match of a spoken answer.
public enum VoicePromptSpeech {
    public static let expiredLine = "The request expired."
    public static let screenTitle = "Hermes needs an answer"

    /// The spoken name of an approval choice.
    public static func spokenName(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: "allow once"
        case .session: "this chat"
        case .always: "always"
        case .deny: "deny"
        }
    }

    /// "a, b, or c". Two choices: "a, or b".
    public static func list(_ words: [String]) -> String {
        guard let last = words.last else { return "" }
        guard words.count > 1 else { return last }
        return words.dropLast().joined(separator: ", ") + ", or " + last
    }

    /// The prompt line. It never holds a value, the command, the env var name or the sudo command.
    public static func line(_ item: VoicePromptItem) -> String {
        switch item.card {
        case .approval:
            return "Hermes needs your approval. Say \(list(item.spokenChoices))."
        case .prompt(let card):
            switch card.kind {
            case .secret: return "Hermes needs a secret. Type it on the screen."
            case .sudo: return "Hermes needs your password. Type it on the screen."
            case .clarify:
                guard let question = item.spokenQuestion else { return "Hermes has a question. Answer on the screen." }
                return "Hermes has a question. \(sentence(question.question)) Say \(list(question.choices))."
            }
        }
    }

    /// The line after a spoken answer that matches no choice.
    public static func retryLine(_ item: VoicePromptItem) -> String {
        "Say \(list(item.spokenChoices)), or tap."
    }

    /// The result that the card shows and the voice says, or `nil` while the card waits or sends.
    public static func resultLine(_ item: VoicePromptItem) -> String? {
        switch item.card {
        case .approval(let card):
            switch card.state {
            case .waiting, .sending: return nil
            case .expired: return expiredLine
            default: return card.resultText
            }
        case .prompt(let card):
            switch card.state {
            case .waiting, .sending: return nil
            case .expired: return expiredLine
            default: return card.resultText
            }
        }
    }

    private static func sentence(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".?!".contains(last) ? trimmed : trimmed + "."
    }

    /// Lower case words, with no punctuation.
    static func words(_ text: String) -> [String] {
        text.lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ").map(String.init)
    }

    private static func contains(_ words: [String], phrase: [String]) -> Bool {
        guard !phrase.isEmpty, phrase.count <= words.count else { return false }
        return (0...(words.count - phrase.count)).contains { Array(words[$0..<($0 + phrase.count)]) == phrase }
    }

    private static let ordinals = [["first", "one", "1"], ["second", "two", "2"], ["third", "three", "3"],
                                   ["fourth", "four", "4"], ["fifth", "five", "5"]]

    /// The answer in a transcript, or `nil` when it matches no offered choice.
    public static func match(_ transcript: String, for item: VoicePromptItem) -> VoicePromptAnswer? {
        let said = words(transcript)
        guard !said.isEmpty else { return nil }
        if said == ["stop"] { return .stop }
        switch item.card {
        case .approval(let card):
            let offered = Set(card.choices)
            // Deny first: "no" never allows. Then the longer phrases, so "always allow" is not "allow once".
            let rules: [(ApprovalChoice, [[String]])] = [
                (.deny, [["deny"], ["no"]]),
                (.always, [["always"]]),
                (.session, [["this", "chat"]]),
                (.once, [["allow", "once"], ["once"], ["allow"]]),
            ]
            for (choice, phrases) in rules where offered.contains(choice) {
                if phrases.contains(where: { contains(said, phrase: $0) }) { return .approval(choice) }
            }
            return nil
        case .prompt:
            guard let question = item.spokenQuestion else { return nil }
            // The longest choice that the owner said, so "Work" does not win over "Work trip".
            let hits = question.choices.filter { contains(said, phrase: words($0)) }
            if let best = hits.max(by: { words($0).count < words($1).count }) {
                return .clarify(qid: question.qid, choice: best)
            }
            for (index, names) in ordinals.enumerated() where index < question.choices.count {
                if said.count <= 2, names.contains(where: { said.contains($0) }) {
                    return .clarify(qid: question.qid, choice: question.choices[index])
                }
            }
            return nil
        }
    }
}

/// What on-device STT heard.
public enum VoicePromptHeard: Sendable, Equatable {
    case text(String)
    /// No speech, or no words.
    case nothing
    /// The microphone or the recognizer did not run. The card waits for a tap.
    case unavailable
}

/// On-device speech and on-device STT for prompt lines. Never the Hermes voice and never the live model.
@MainActor
public protocol VoicePromptVoice: AnyObject {
    /// Says one line, and returns when it ends or `stop()` cuts it.
    func speak(_ line: String) async
    /// Listens for one short answer.
    func listen() async -> VoicePromptHeard
    /// Stops the speech and closes the microphone at once.
    func stop()
}

/// The loop that pauses while a card waits: the #96 hands-free engine, or the #98 live engine.
@MainActor
public protocol VoicePromptHolding: AnyObject {
    func holdForPrompt()
    func releasePrompt()
}

/// The session chat. `ChatViewModel` conforms.
@MainActor
public protocol VoicePromptChat: AnyObject {
    /// The cards that wait, oldest first.
    var waitingPrompts: [VoicePromptItem] { get }
    func promptItem(id: String) -> VoicePromptItem?
    @discardableResult func answerApproval(id: String, choice: ApprovalChoice) -> Task<Void, Never>?
    @discardableResult func answerClarify(id: String, typed: [String: String]) -> Task<Void, Never>?
}

extension ChatViewModel: VoicePromptChat {
    public var waitingPrompts: [VoicePromptItem] {
        messages.compactMap(VoicePromptItem.init).filter(\.isWaiting)
    }

    public func promptItem(id: String) -> VoicePromptItem? {
        messages.first { $0.id == id }.flatMap(VoicePromptItem.init)
    }
}

/// The step of the card on the Voice tab (design notes, States).
public enum VoicePromptPhase: Sendable, Equatable {
    /// The voice says the line.
    case speaking
    /// The microphone is open for a spoken choice.
    case listening
    /// The card waits for a tap or a typed value. The microphone is closed.
    case waiting
    /// "Sending…".
    case sending
    /// The result line ("Allowed once", "Sent", "This request expired"). The card hides after 2 s.
    case done(String)

    /// The Quiet Ring of the step.
    public var ring: VoiceRingStyle {
        switch self {
        case .speaking: .speaking
        case .listening: .listening
        case .waiting: .paused
        case .sending, .done: .working
        }
    }
}

/// Issue #121: shows and speaks the prompts of the session chat, one at a time, oldest first.
///
/// - A new card holds the loop (mic and audio), then the voice says the line.
/// - A card with choices listens for one answer. No match: "Say …, or tap." A second miss closes the mic.
/// - A secret or a password: the line only. The mic stays closed. The value goes from the field to the chat.
/// - An answer from the Voice tab or the chat ends the card. The result shows for 2 s, then the loop goes on.
/// - The log gets ids and steps. Never the line, the transcript, the question or a value.
@MainActor @Observable
public final class VoicePromptCoordinator {
    /// The card that the Voice tab shows. It follows the chat state.
    public private(set) var item: VoicePromptItem?
    public private(set) var phase: VoicePromptPhase = .waiting
    /// One more for each new card. The tab plays the `.warning` haptic.
    public private(set) var shownCount = 0

    /// The owner said "stop".
    @ObservationIgnored public var onStop: (@MainActor () -> Void)?

    @ObservationIgnored private let voice: any VoicePromptVoice
    @ObservationIgnored private let resultHold: Duration
    @ObservationIgnored private weak var chat: (any VoicePromptChat)?
    @ObservationIgnored private weak var hold: (any VoicePromptHolding)?
    @ObservationIgnored private var held = false
    @ObservationIgnored private var serial = 0
    /// One more on each start and stop. An observer of an older chat stops.
    @ObservationIgnored private var watch = 0
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var resultTask: Task<Void, Never>?
    @ObservationIgnored private let log = HermesLog(category: "voice-prompt")

    /// - Parameter resultHold: how long the result shows. Tests make it short.
    public init(voice: any VoicePromptVoice, resultHold: Duration = .seconds(2)) {
        self.voice = voice
        self.resultHold = resultHold
    }

    /// Starts to watch the chat of a voice session.
    public func start(chat: any VoicePromptChat, hold: any VoicePromptHolding) {
        stop()
        self.chat = chat
        self.hold = hold
        observe()
        refresh()
    }

    /// The session ended: the voice stops, the card hides. The chat keeps the card.
    public func stop() {
        serial += 1
        watch += 1
        task?.cancel()
        task = nil
        resultTask?.cancel()
        resultTask = nil
        if item != nil { voice.stop() }
        item = nil
        phase = .waiting
        held = false
        chat = nil
        hold = nil
    }

    /// Re-reads the chat. The observer calls it on each change of the messages.
    public func refresh() {
        guard let chat else { return }
        guard let current = item else {
            if let next = chat.waitingPrompts.first { begin(next) }
            return
        }
        guard let latest = chat.promptItem(id: current.id) else {
            // The thread dropped the card (a reload): go on with the loop.
            close()
            return
        }
        item = latest
        if case .done = phase { return }
        if latest.isWaiting {
            // An answer that did not go: the card waits again, for a tap.
            if phase == .sending { phase = .waiting }
            return
        }
        task?.cancel()
        task = nil
        voice.stop()
        guard let result = VoicePromptSpeech.resultLine(latest) else {
            phase = .sending
            return
        }
        showResult(result)
    }

    private func observe() {
        let watch = watch
        withObservationTracking { [weak self] in
            guard let self, let chat = self.chat else { return }
            _ = chat.waitingPrompts
            if let id = self.item?.id { _ = chat.promptItem(id: id) }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.watch == watch, self.chat != nil else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    private func begin(_ next: VoicePromptItem) {
        serial += 1
        item = next
        shownCount += 1
        if !held {
            held = true
            hold?.holdForPrompt()
        }
        let kind = next.isSecure ? "secure" : (next.takesSpokenAnswer ? "choices" : "screen")
        log.info("voice prompt shown: card \(next.id), \(kind)")
        let serial = serial
        phase = .speaking
        task = Task { [weak self] in await self?.run(next, serial: serial) }
    }

    private func isCurrent(_ serial: Int, _ id: String) -> Bool {
        !Task.isCancelled && self.serial == serial && item?.id == id && item?.isWaiting == true
    }

    private func run(_ start: VoicePromptItem, serial: Int) async {
        await voice.speak(VoicePromptSpeech.line(start))
        guard isCurrent(serial, start.id) else { return }
        guard start.takesSpokenAnswer else {
            phase = .waiting
            return
        }
        var misses = 0
        while isCurrent(serial, start.id) {
            phase = .listening
            let heard = await voice.listen()
            guard isCurrent(serial, start.id), let current = item else { return }
            let answer: VoicePromptAnswer? = if case .text(let text) = heard {
                VoicePromptSpeech.match(text, for: current)
            } else {
                nil
            }
            if heard == .unavailable {
                log.notice("voice prompt listen unavailable: card \(current.id)")
                phase = .waiting
                return
            }
            if let answer {
                apply(answer, to: current)
                return
            }
            misses += 1
            log.info("voice prompt no match: card \(current.id), miss \(misses)")
            guard misses < 2 else {
                phase = .waiting
                return
            }
            phase = .speaking
            await voice.speak(VoicePromptSpeech.retryLine(current))
        }
    }

    private func apply(_ answer: VoicePromptAnswer, to current: VoicePromptItem) {
        switch answer {
        case .stop:
            log.info("voice prompt stop word")
            onStop?()
        case .approval(let choice):
            log.info("voice prompt spoken answer: card \(current.id), choice \(choice.rawValue)")
            chat?.answerApproval(id: current.id, choice: choice)
            refresh()
        case .clarify(let qid, let choice):
            log.info("voice prompt spoken answer: card \(current.id)")
            chat?.answerClarify(id: current.id, typed: [qid: choice])
            refresh()
        }
    }

    private func showResult(_ text: String) {
        phase = .done(text)
        let serial = serial
        let hold = resultHold
        resultTask = Task { [weak self] in
            await self?.voice.speak(text)
            try? await Task.sleep(for: hold)
            guard let self, !Task.isCancelled, self.serial == serial else { return }
            self.close()
        }
    }

    /// The card hides. The next waiting card shows, else the loop goes on.
    private func close() {
        item = nil
        phase = .waiting
        resultTask = nil
        if let next = chat?.waitingPrompts.first {
            begin(next)
            return
        }
        if held {
            held = false
            hold?.releasePrompt()
        }
    }
}

extension VoiceTabDisplay {
    /// Issue #121: the tab while a card waits. The title says so, the ring follows the prompt step, and Mute is off:
    /// the loop holds the mic.
    public static func prompt(_ phase: VoicePromptPhase, over loop: VoiceTabDisplay) -> VoiceTabDisplay {
        VoiceTabDisplay(ring: phase.ring, title: VoicePromptSpeech.screenTitle,
                        subtitle: phase == .listening ? "Listening" : nil, action: nil, isSession: true,
                        muteOn: loop.muteOn, muteEnabled: false, isLive: loop.isLive)
    }
}
