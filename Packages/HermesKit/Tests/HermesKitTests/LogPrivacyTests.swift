import Foundation
import Testing
@testable import HermesKit

/// Issue #18: info-level logs carry metadata only. A message body in a log entry fails these tests.
@Suite(.serialized) struct LogPrivacyTests {
    static let sentBody = "BODY-7f3a sample prompt text"
    static let replyBody = "REPLY-91c2 sample answer text"

    /// Collects the entries of all categories at `info` or higher while `body` runs.
    final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var _entries: [HermesLog.Entry] = []
        var entries: [HermesLog.Entry] { lock.withLock { _entries } }

        func record(_ entry: HermesLog.Entry) {
            guard entry.level >= .info else { return }
            lock.withLock { _entries.append(entry) }
        }

        /// The entries that contain one of `secrets`.
        func leaks(of secrets: [String]) -> [HermesLog.Entry] {
            entries.filter { entry in secrets.contains { entry.message.contains($0) } }
        }
    }

    /// Starts a capture. Call `stop` with the id.
    private func startCapture() -> (Capture, UUID) {
        let capture = Capture()
        return (capture, HermesLog.addObserver { capture.record($0) })
    }

    private func event(_ json: String) throws -> GatewayClientEvent {
        .event(try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)))
    }

    /// The check itself works: a body at info level is a leak.
    @Test func captureDetectsABodyAtInfoLevel() async {
        let (capture, id) = startCapture()
        HermesLog(category: "test").info("text: \(Self.sentBody)")
        HermesLog.removeObserver(id)
        #expect(capture.leaks(of: [Self.sentBody]).count == 1)
    }

    @Test @MainActor func chatRoundLogsNoMessageBody() async throws {
        let transport = FakeChatTransport()
        let vm = ChatViewModel(transport: transport, redrawInterval: .seconds(60))
        let (capture, id) = startCapture()
        defer { HermesLog.removeObserver(id) }
        await vm.send(Self.sentBody)?.value
        vm.receive(try event(#"{"type":"message.start","session_id":"s1","payload":{"turn_id":"t1"}}"#))
        vm.receive(try event(#"{"type":"message.delta","session_id":"s1","payload":{"text":"\#(Self.replyBody)","offset":0}}"#))
        vm.receive(try event(#"{"type":"message.complete","session_id":"s1","payload":{"text":"\#(Self.replyBody)"}}"#))
        transport.failSubmit = true
        await vm.send(Self.sentBody + " again")?.value
        #expect(vm.messages.map(\.text).contains(Self.replyBody), "the reply reached the model")
        let chat = capture.entries.filter { $0.category == "chat" }
        #expect(chat.contains { $0.message.hasPrefix("prompt delivered") })
        #expect(chat.contains { $0.message.hasPrefix("reply complete") })
        #expect(chat.contains { $0.message.hasPrefix("prompt not delivered") })
        #expect(capture.leaks(of: [Self.sentBody, Self.replyBody, "BODY-7f3a", "REPLY-91c2"]).isEmpty)
    }

    @Test func connectLogsNoServerOutput() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample, pingReply: .success("PONG 1\n"))
        let key = SoftwareKeyFactory.wrap(.init())
        let (capture, id) = startCapture()
        defer { HermesLog.removeObserver(id) }
        _ = try await HostConnector(transport: transport)
            .connect(profile: ServerProfile(host: "vps.example.com", hostKey: .sample), key: key)
        let ssh = capture.entries.filter { $0.category == "ssh" }
        #expect(ssh.map(\.message) == ["SSH connected: gate 1, aes256-gcm@openssh.com · curve25519-sha256"])
    }
}
