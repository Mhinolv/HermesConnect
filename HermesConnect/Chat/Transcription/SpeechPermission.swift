import HermesKit
import Speech

/// Issue #50: the speech recognition permission for Apple On-Device file transcripts.
/// Only the permission API of `SFSpeechRecognizer` is used. Its recognizer never runs.
struct SystemSpeechPermission: SpeechPermissionChecking {
    func status() -> SpeechPermission {
        Self.map(SFSpeechRecognizer.authorizationStatus())
    }

    func request() async -> SpeechPermission {
        let status = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
        }
        return Self.map(status)
    }

    static func map(_ status: SFSpeechRecognizerAuthorizationStatus) -> SpeechPermission {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }
}
