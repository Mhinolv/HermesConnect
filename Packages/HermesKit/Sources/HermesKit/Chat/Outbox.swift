import Foundation

/// Issue #39: the rules of the offline outbox. A send that fails because the app is offline waits in the
/// outbox ("Will send when connected"). A send that the server refuses shows "Not Delivered", as before.
///
/// - The outbox never sends a prompt twice. A `prompt.submit` that maybe reached the server is not queued.
/// - Queued messages go in thread order, one at a time, after the next connect.
public enum Outbox {
    /// `true` when `error` means "no link to Hermes", so the send can wait for the next connect.
    /// `submitted` is `true` when the error came from `prompt.submit`. Then only an error from before the
    /// request went out counts (`GatewayError.notConnected`). A drop or a time-out after the write is not
    /// known to have failed: the message shows "Not Delivered" with "Try Again".
    public static func isOffline(_ error: any Error, submitted: Bool) -> Bool {
        if case GatewayError.notConnected = error { return true }
        guard !submitted else { return false }
        switch error {
        case GatewayError.disconnected(let reason):
            // A refused token is not offline. The renewal shows its own state.
            return !LiveChatTransport.isStaleToken(reason)
        case let error as URLError:
            return offlineURLCodes.contains(error.code)
        case ReceivedFileError.offline:
            return true
        default:
            return false
        }
    }

    /// The URL errors of a REST call (voice memo transcription) with no link to the forwarded port.
    /// A time-out is not here: a slow server is not offline, and the next connect can be far away.
    static let offlineURLCodes: Set<URLError.Code> = [
        .notConnectedToInternet, .networkConnectionLost, .cannotConnectToHost, .cannotFindHost,
        .dataNotAllowed, .internationalRoamingOff,
    ]
}
