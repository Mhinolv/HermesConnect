import Foundation
import HermesKit

/// DEBUG only: the Live status of the Voice tab with no server. `HERMES_DEMO_LIVE=on` (Live available) or `off`
/// (not available). The demo never opens a live session: a start in the `on` demo fails at once with no network.
enum LiveModeDemo {
    static var service: (any LiveModeService)? {
        #if DEBUG
        switch ProcessInfo.processInfo.environment["HERMES_DEMO_LIVE"] {
        case "on": return Service(status: VoiceLiveStatus(mode: .gptLive, available: true, model: "gpt-live-1",
                                                          voice: "marin"))
        case "off": return Service(status: VoiceLiveStatus(mode: .chained, available: false,
                                                           reason: "GPT-Live is off on this server."))
        default: return nil
        }
        #else
        return nil
        #endif
    }

    struct Service: LiveModeService {
        let status: VoiceLiveStatus

        func voiceLiveStatus() async throws -> VoiceLiveStatus? { status }

        func createVoiceLiveSession(offerSDP _: String, history _: [VoiceLiveHistoryItem]) async throws
            -> VoiceLiveSessionAnswer {
            throw VoiceLiveSessionError.unavailable(detail: "Demo mode has no live session.")
        }
    }
}
