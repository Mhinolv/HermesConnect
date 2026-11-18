import Foundation

/// Issue #98: the chat is the Hermes side of a live session. Each delegation is a normal turn in this chat.
extension ChatViewModel: LiveModeHermes {
    public func submitDelegation(prompt: String, voiceContext: String) async throws -> String {
        await sendLiveDelegation(prompt, voiceContext: voiceContext)
    }

    public func replyProgress(promptId: String) -> LiveReplyProgress {
        liveReplyProgress(promptId: promptId)
    }

    public func stopReply() {
        _ = stop()
    }

    public func liveHistory() -> [VoiceLiveHistoryItem] {
        LiveModeText.history(messages)
    }
}
