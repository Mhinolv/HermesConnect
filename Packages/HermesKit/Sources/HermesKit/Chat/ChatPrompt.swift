import Foundation

/// Issue #117: the card of one `secret`, `sudo` or `clarify` request (docs/hermes-protocol.md 3.11). It is local:
/// it never goes to the cache. The card never holds the value that the owner types. The prompt, the env var
/// name and the command never go to a log.
public struct ChatPromptCard: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// A masked value for the env var `envVar`.
        case secret(envVar: String)
        /// The sudo password. `command` is redacted on the server.
        case sudo(command: String)
        /// 1 to 5 questions. `locked` are the answers that the server has already (a reconnect replay).
        case clarify(questions: [ClarifyQuestion], locked: [String: String?])
    }

    public enum State: Sendable, Equatable {
        /// The fields and the buttons show.
        case waiting
        /// The owner tapped Send. The answer is on its way.
        case sending
        /// The server took the answer: "Sent".
        case sent
        /// The owner tapped Cancel: "Cancelled".
        case cancelled
        /// The request timed out, or ended while the socket was closed: "This request expired".
        case expired
    }

    public static let sentText = "Sent"
    public static let cancelledText = "Cancelled"
    public static let notSentText = "Not sent. Try again."
    public static let sendTitle = "Send"
    public static let cancelTitle = "Cancel"

    /// The JSON-RPC id of the server request. The answer goes on it.
    public var serverRequestId: JSONRPCID
    /// The live session id.
    public var sessionId: String
    public var kind: Kind
    /// The server prompt of a secret. Empty for the other kinds.
    public var prompt: String
    public var state: State
    /// The last answer did not go (the socket closed). The fields show again, empty.
    public var sendFailed = false

    public init(serverRequestId: JSONRPCID, sessionId: String, kind: Kind, prompt: String = "",
                state: State = .waiting) {
        self.serverRequestId = serverRequestId
        self.sessionId = sessionId
        self.kind = kind
        self.prompt = prompt
        self.state = state
    }

    /// The card of a server request, or `nil` for an approval.
    public init?(request: GatewayServerRequest, sessionId: String) {
        switch request.kind {
        case .approval: return nil
        case .secret(let secret):
            self.init(serverRequestId: request.id, sessionId: sessionId, kind: .secret(envVar: secret.envVar),
                      prompt: secret.prompt)
        case .sudo(let sudo):
            self.init(serverRequestId: request.id, sessionId: sessionId, kind: .sudo(command: sudo.command))
        case .clarify(let clarify):
            self.init(serverRequestId: request.id, sessionId: sessionId,
                      kind: .clarify(questions: clarify.questions, locked: clarify.lockedAnswers))
        }
    }

    public var isWaiting: Bool { state == .waiting }

    /// A secret or a password: one masked field.
    public var isSecure: Bool {
        if case .clarify = kind { return false }
        return true
    }

    /// The title (design notes).
    public var title: String {
        switch kind {
        case .secret: "Hermes asks for a secret"
        case .sudo: "Hermes asks for a password"
        case .clarify: "Hermes asks a question"
        }
    }

    /// The text under the title: the server prompt. A clarify card shows its questions in their own lines.
    public var bodyText: String? {
        switch kind {
        case .secret(let envVar):
            let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
            return envVar.isEmpty ? "Enter the secret." : "Enter the value."
        case .sudo:
            return "Enter your sudo password to run this command."
        case .clarify:
            return nil
        }
    }

    /// The monospaced line: the env var name of a secret, or the command of a sudo request.
    public var detailText: String? {
        let text: String
        switch kind {
        case .secret(let envVar): text = envVar
        case .sudo(let command): text = command
        case .clarify: return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The placeholder of the masked field.
    public var fieldPlaceholder: String {
        if case .sudo = kind { return "Password" }
        return "Secret"
    }

    /// The questions that wait for an answer: the server did not lock them.
    public var openQuestions: [ClarifyQuestion] {
        guard case .clarify(let questions, let locked) = kind else { return [] }
        return questions.filter { locked[$0.qid] == nil }
    }

    /// The `answers` of a clarify result: the locked ones, then the owner's. `nil` until each open question has
    /// a non-empty answer.
    public func clarifyAnswers(_ typed: [String: String]) -> [String: String?]? {
        guard case .clarify(_, let locked) = kind else { return nil }
        var answers = locked
        for question in openQuestions {
            let text = typed[question.qid]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !text.isEmpty else { return nil }
            answers[question.qid] = .some(text)
        }
        return answers
    }

    /// The secondary line after an answer, or `nil` while the fields show.
    public var resultText: String? {
        switch state {
        case .waiting: sendFailed ? Self.notSentText : nil
        case .sending: "Sending…"
        case .sent: Self.sentText
        case .cancelled: Self.cancelledText
        case .expired: ChatApprovalCard.expiredText
        }
    }

    /// The VoiceOver label of the card text: the title, then the prompt. The fields and the buttons follow as
    /// their own elements.
    public var accessibilityLabel: String {
        var parts = [title]
        if let bodyText { parts.append(bodyText) }
        if let detailText { parts.append(detailText) }
        return parts.joined(separator: ", ")
    }

    /// The error answer of Cancel on a secret or a password: a withdrawal (docs/hermes-protocol.md 3.11).
    public static let cancelErrorCode = -32000
    public static let cancelErrorMessage = "The owner cancelled the request"
}
