import Foundation
import Observation

/// One run of the "Ask Hermes" App Shortcut (issue #16).
public struct AskHermesRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The "Message" text, trimmed. `nil` opens the chat and sends nothing.
    public let text: String?

    public init(message: String?, id: UUID = UUID()) {
        self.id = id
        let trimmed = message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        text = trimmed.isEmpty ? nil : trimmed
    }
}

/// What the root does with the request that waits.
public enum AskHermesStep: Equatable, Sendable {
    /// Setup is not done: show the setup screen. The text is dropped.
    case dropForSetup
    /// Open the chat and send the text.
    case run(AskHermesRequest)
}

/// The chat that Ask Hermes opens. `newChat` carries the route key of the new chat.
public enum AskHermesRoute: Equatable, Sendable {
    case session(String)
    case newChat(key: String)
}

/// The shortcut puts its request here. The root takes it when the app is set up and App Lock is open.
@MainActor @Observable
public final class AskHermesInbox {
    /// The request that waits. A newer run replaces it.
    public private(set) var pending: AskHermesRequest?

    public init() {}

    @discardableResult
    public func post(message: String?) -> AskHermesRequest {
        let request = AskHermesRequest(message: message)
        pending = request
        return request
    }

    /// `nil` while nothing waits, or while App Lock covers the app (the request stays).
    /// Any other step removes the request, so it runs once.
    public func next(isSetUp: Bool, isLocked: Bool) -> AskHermesStep? {
        guard let request = pending else { return nil }
        guard isSetUp else {
            pending = nil
            return .dropForSetup
        }
        guard !isLocked else { return nil }
        pending = nil
        return .run(request)
    }
}

@MainActor
public enum AskHermes {
    /// How long a run waits for the chat link before it sends. After that the text shows "Not Delivered".
    public static let linkTimeout: Duration = .seconds(30)

    /// Runs one request. The owner decision (2026-11-16) says the text goes at once, with no composer step.
    ///
    /// 1. The session that launch opens (#7): the cached active session. `show` pushes it at once.
    /// 2. No cached session: wait for the link, then `session.most_recent`. No session: a new chat.
    /// 3. Wait for the link (`linkReady`), then send. A send with no link shows "Not Delivered" and "Try Again".
    ///
    /// Returns the send task, or `nil` when the request has no text.
    @discardableResult
    public static func run(_ request: AskHermesRequest, sessions: SessionListModel,
                           linkReady: @MainActor () async -> Bool,
                           show: @MainActor (AskHermesRoute) -> Void) async -> Task<Void, Never>? {
        let chat: ChatViewModel
        if let id = sessions.cachedActiveSessionId {
            show(.session(id))
            chat = sessions.chat(for: id)
            guard let text = request.text else { return nil }
            _ = await linkReady()
            return chat.send(text)
        }
        let ready = await linkReady()
        let mostRecent = ready ? await sessions.mostRecentSessionId() : nil
        if let id = mostRecent {
            show(.session(id))
            chat = sessions.chat(for: id)
        } else {
            let key = UUID().uuidString
            show(.newChat(key: key))
            chat = sessions.newChat(key: key)
        }
        guard let text = request.text else { return nil }
        return chat.send(text)
    }

    /// `true` when the link is ready. `false` when it failed, there is no link, or the time is over.
    public static func waitUntilReady(timeout: Duration = linkTimeout, poll: Duration = .milliseconds(200),
                                      status: @MainActor () -> ChatLinkStatus?) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while true {
            switch status() {
            case .ready: return true
            case .failed, nil: return false
            default: break
            }
            if Task.isCancelled || clock.now >= deadline { return false }
            try? await Task.sleep(for: poll)
        }
    }
}
