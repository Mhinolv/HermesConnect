import Foundation

/// Issue #104: the card of one `approval` request (docs/hermes-protocol.md 3.11). It is local: it never goes to
/// the cache. The command text never goes to a log.
public struct ChatApprovalCard: Sendable, Equatable {
    public enum State: Sendable, Equatable {
        /// The buttons show.
        case waiting
        /// The owner tapped a choice. The answer is on its way.
        case sending(ApprovalChoice)
        /// The server took the answer.
        case answered(ApprovalChoice)
        /// The request timed out: "This request expired".
        case expired
        /// `approval.cancelled`: the server dropped the approval and resolved it as deny.
        case cancelled
    }

    public static let title = "Hermes asks for approval"
    /// The preview line of a chat that waits for an approval (design notes).
    public static let listPreview = "Approval needed"
    public static let expiredText = "This request expired"

    /// The approval queue id (`params.request_id`). `approval.received` and `approval.respond` use it.
    /// Empty when the server sent none.
    public var requestId: String
    /// The JSON-RPC id of the server request. `nil` for a card from the snapshot `pending_approval` or from
    /// `approval.pending`: the answer then goes as `approval.respond`.
    public var serverRequestId: JSONRPCID?
    /// The live session id.
    public var sessionId: String
    /// The redacted command. Never in a log.
    public var command: String
    public var description: String
    /// The server choices, in server order, with deny last.
    public var choices: [ApprovalChoice]
    public var toolName: String?
    public var state: State

    public init(request: ApprovalRequest, serverRequestId: JSONRPCID?, sessionId: String? = nil,
                state: State = .waiting) {
        requestId = request.requestId
        self.serverRequestId = serverRequestId
        self.sessionId = sessionId ?? request.sessionId
        command = request.command
        description = request.description
        let offered = request.choices.isEmpty ? Self.defaultChoices(request) : request.choices
        choices = offered.filter { $0 != .deny } + (offered.contains(.deny) ? [.deny] : [])
        toolName = request.toolName
        self.state = state
    }

    /// The choices of `server.py:_approval_request_payload` when the server sends none.
    static func defaultChoices(_ request: ApprovalRequest) -> [ApprovalChoice] {
        var choices: [ApprovalChoice] = [.once]
        if request.allowSession != false {
            choices.append(.session)
            if request.allowPermanent != false { choices.append(.always) }
        }
        return choices + [.deny]
    }

    public var isWaiting: Bool { state == .waiting }

    /// The body text: the description, else the command.
    public var bodyText: String {
        let text = description.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? command : text
    }

    /// The monospaced command under the description. `nil` when the body already shows it or it is empty.
    public var commandText: String? {
        let text = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != bodyText else { return nil }
        return text
    }

    /// The secondary line after an answer, or `nil` while the buttons show.
    public var resultText: String? {
        switch state {
        case .waiting: nil
        case .sending: "Sending…"
        case .answered(let choice): Self.resultText(choice)
        case .expired: Self.expiredText
        case .cancelled: Self.resultText(.deny)
        }
    }

    /// The button title of a choice (design notes).
    public static func buttonTitle(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: "Allow Once"
        case .session: "Allow for This Chat"
        case .always: "Always Allow"
        case .deny: "Deny"
        }
    }

    public static func resultText(_ choice: ApprovalChoice) -> String {
        switch choice {
        case .once: "Allowed once"
        case .session: "Allowed for this chat"
        case .always: "Always allowed"
        case .deny: "Denied"
        }
    }

    /// The VoiceOver label: the title, then the description. The buttons follow as their own elements.
    public var accessibilityLabel: String {
        var parts = [Self.title, bodyText]
        if let commandText { parts.append(commandText) }
        if let resultText { parts.append(resultText) }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

/// Issue #104: the one-line card for a `clarify`, `sudo` or `secret` request. The app answers it with an error
/// at once, so Hermes does not wait. A full UI is a separate issue.
enum UnsupportedServerRequest {
    static let errorCode = -32601
    static let errorMessage = "The iOS app cannot answer this request yet"

    static func card(for kind: GatewayServerRequest.Kind) -> ChatCommandCard? {
        let header: String
        switch kind {
        case .approval: return nil
        case .clarify: header = "Question from Hermes"
        case .sudo: header = "Password request from Hermes"
        case .secret: header = "Secret request from Hermes"
        }
        return ChatCommandCard(command: header, output: "The app cannot answer this yet. Hermes did not wait.")
    }
}

/// Issue #104: an approval that came while the socket was open. The app posts a local notification when it is in
/// the background. The body has no command text.
public struct ApprovalAlert: Sendable, Equatable, Identifiable {
    public let id: String
    /// The stored id of the chat. A tap on the notification opens it.
    public let storedSessionId: String?
    /// The chat title, or `nil` for "New Chat".
    public let title: String?

    public init(id: String, storedSessionId: String?, title: String?) {
        self.id = id
        self.storedSessionId = storedSessionId
        self.title = title
    }

    public static let notificationTitle = ChatApprovalCard.title
    public static let notificationBody = "Open the chat to answer."
}
