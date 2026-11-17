#if DEBUG
import Foundation
import HermesKit

/// DEBUG only: a "Demo conversation" that replays fixture gateway events, so the chat screen
/// runs on the Simulator with no server. Start it with the launch environment `HERMES_DEMO=<scenario>`.
/// Release builds do not contain this file.
final class DemoChatTransport: ChatTransport, @unchecked Sendable {
    enum Scenario: String {
        /// Seeded thread. Each send streams a scripted reply.
        case live
        /// Seeded thread, idle.
        case thread
        /// Seeded thread plus a reply that streams with a tool line and holds before `message.complete`.
        case streaming
        /// Seeded thread with a failed reply, plus a send that fails ("Not Delivered").
        case failed
        /// No messages. The composer has focus.
        case empty

        static var current: Scenario? {
            ProcessInfo.processInfo.environment["HERMES_DEMO"].flatMap(Scenario.init(rawValue:))
        }

        /// The prompt that the demo sends at launch, if any.
        var autoPrompt: String? {
            switch self {
            case .streaming: "What's the weather in Austin this weekend?"
            case .failed: "Can you check the server logs?"
            case .live, .thread, .empty: nil
            }
        }
    }

    let scenario: Scenario
    let events: AsyncStream<GatewayClientEvent>
    private let input: AsyncStream<GatewayClientEvent>.Continuation
    private let lock = NSLock()
    private var seq = 0
    private var rowId = 200
    private var stopped = false

    static let sessionId = "d3m0c4t5"

    init(scenario: Scenario) {
        self.scenario = scenario
        (events, input) = AsyncStream.makeStream(of: GatewayClientEvent.self)
    }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        try await Task.sleep(for: .milliseconds(150))
        return ChatSessionRef(liveId: Self.sessionId, storedId: "20261116_094100_demo01")
    }

    struct DemoFailure: Error {}

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? {
        try await Task.sleep(for: .milliseconds(350))
        if scenario == .failed { throw DemoFailure() }
        let row = lock.withLock {
            stopped = false
            rowId += 2
            return rowId
        }
        let hold = scenario == .streaming
        Task.detached { [self] in await replay(Self.weatherReply, hold: hold) }
        return row
    }

    func stopReply(sessionId _: String) async throws -> Bool {
        lock.withLock { stopped = true }
        return true
    }

    // MARK: Replay

    private var isStopped: Bool { lock.withLock { stopped } }

    private func emit(_ type: String, _ payload: String) {
        let next = lock.withLock {
            seq += 1
            return seq
        }
        let json = #"{"type":"\#(type)","session_id":"\#(Self.sessionId)","seq":\#(next),"payload":\#(payload)}"#
        guard let event = try? JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8)) else { return }
        input.yield(.event(event))
    }

    private static func quoted(_ text: String) -> String {
        let data = (try? JSONEncoder().encode(text)) ?? Data("\"\"".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func replay(_ reply: String, hold: Bool) async {
        emit("message.start", #"{"turn_id":"demo"}"#)
        try? await Task.sleep(for: .milliseconds(900))
        emit("tool.start", #"{"tool_id":"t1","name":"web_search"}"#)
        try? await Task.sleep(for: .milliseconds(1200))
        emit("tool.complete", #"{"tool_id":"t1","name":"web_search"}"#)
        let words = reply.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let stopAt = hold ? words.count * 3 / 5 : words.count
        var offset = 0
        for (index, word) in words.enumerated() {
            if isStopped {
                emit("message.complete", #"{"text":"","status":"interrupted"}"#)
                return
            }
            if index == stopAt { return }
            let chunk = index == 0 ? word : " " + word
            emit("message.delta", #"{"text":\#(Self.quoted(chunk)),"turn_id":"demo","segment":0,"offset":\#(offset)}"#)
            offset += chunk.utf16.count
            try? await Task.sleep(for: .milliseconds(45))
        }
        emit("message.complete", #"{"text":\#(Self.quoted(reply)),"status":"complete"}"#)
    }

    static let weatherReply = """
        Austin looks **warm and dry** this weekend: Saturday 78°F and sunny, Sunday 74°F with a light \
        breeze. Rain chances stay under *10%*. Forecast source: https://example.com/weather/austin
        """

    // MARK: Seed

    /// The seeded history: a time header, a short run, a code block, a link and a long reply.
    func seedMessages(now: Date = Date()) -> [ChatMessage] {
        guard scenario != .empty else { return [] }
        let early = now.addingTimeInterval(-2 * 3600)
        let recent = now.addingTimeInterval(-6 * 60)
        var messages = [
            ChatMessage(id: "d1", role: .user, text: "What's on my calendar tomorrow?", date: early,
                        delivery: .delivered, userRowId: 101),
            ChatMessage(id: "d2", role: .assistant,
                        text: "You have **two** meetings tomorrow:\n10:00 AM *Design review*\n2:30 PM Call with Sam\n"
                            + "Details are in [your calendar](https://example.com/calendar).",
                        date: early.addingTimeInterval(20), reply: .complete, promptId: "d1"),
            ChatMessage(id: "d3", role: .user, text: "Move the call to 3?", date: early.addingTimeInterval(60),
                        delivery: .delivered, userRowId: 103),
            ChatMessage(id: "d4", role: .assistant, text: "Done. The call with Sam is now at 3:00 PM.",
                        date: early.addingTimeInterval(75), reply: .complete, promptId: "d3"),
            ChatMessage(id: "d5", role: .user, text: "How do I follow the gateway log?", date: recent,
                        delivery: .delivered, userRowId: 105),
            ChatMessage(id: "d6", role: .assistant,
                        text: "Run this on the server:\n```\njournalctl --user -u hermes-gateway -f\n```\n"
                            + "Press `Ctrl-C` to stop. The log shows each turn, tool call and reconnect, so it is "
                            + "the first place to look when a reply is slow or a tool fails. Add `--since \"10 min ago\"` "
                            + "to see only recent lines.",
                        date: recent.addingTimeInterval(15), reply: .complete, promptId: "d5"),
        ]
        if scenario == .failed {
            messages.append(ChatMessage(id: "d7", role: .user, text: "Summarize today's inbox",
                                        date: recent.addingTimeInterval(90), delivery: .delivered, userRowId: 107))
            messages.append(ChatMessage(id: "d8", role: .assistant, text: "You have 14 new emails. The most urgent",
                                        date: recent.addingTimeInterval(100), reply: .failed(message: nil),
                                        promptId: "d7"))
        }
        return messages
    }
}
#endif
