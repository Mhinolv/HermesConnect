import Foundation

/// Issue #96: the chat is the target of voice mode. Each turn is a #9 memo bubble and a #10 reply in this chat.
/// `replyProgress(promptId:)` comes from the #98 extension.
extension ChatViewModel: VoiceModeChat {
    public func attachVoiceModeAudio(_ audio: SpokenAudio, promptId: String) {
        saveVoiceModeAudio(audio, promptId: promptId)
    }
}
