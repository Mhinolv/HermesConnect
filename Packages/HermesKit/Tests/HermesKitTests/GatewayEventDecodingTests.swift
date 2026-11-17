import Foundation
import Testing
@testable import HermesKit

/// Real-shaped frames. Sources: docs/hermes-protocol.md 3.10 and 3.11, `tui_gateway/contracts/events.py`.
enum GatewayFixtures {
    static let turn = [
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.start","session_id":"s1","seq":10,"payload":{"turn_id":"t1"}}}"#,
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"reasoning.delta","session_id":"s1","seq":11,"payload":{"text":"User greets."}}}"#,
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s1","seq":12,"payload":{"text":"Hello","turn_id":"t1","segment":0,"offset":0}}}"#,
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.delta","session_id":"s1","seq":13,"payload":{"text":"! How can I help?","turn_id":"t1","segment":0,"offset":5}}}"#,
        #"{"jsonrpc":"2.0","method":"event","params":{"type":"message.complete","session_id":"s1","seq":14,"payload":{"text":"Hello! How can I help?","status":"complete","usage":{"input":120,"output":9,"total":129}}}}"#,
    ]

    static let approvalRequest = #"""
    {"jsonrpc":"2.0","id":"r-17","method":"approval","params":{"session_id":"s1","request_id":"a1b2","command":"rm -rf build/","description":"Delete the build folder","choices":["once","session","always","deny"],"tool_name":"terminal","allow_session":true,"allow_permanent":true}}
    """#

    static let resumeResult = #"""
    {"session_id":"e5f6a7b8","stored_session_id":"20261116_120000_ab12","message_count":3,
     "messages":[{"role":"user","text":"Plan my trip","row_id":7,"timestamp":1763290000.0}],
     "info":{"model":"gpt-x","running":true},"messages_omitted":false,"running":true,"status":"streaming",
     "inflight":{"assistant":"Partial","streaming":true,"user":"Plan my trip"},
     "open_requests":[{"id":"r-1","method":"approval","params":{"session_id":"e5f6a7b8","request_id":"x"}}]}
    """#
}

@Suite struct GatewayEventDecodingTests {
    private func decode(_ json: String) throws -> GatewayEvent {
        try JSONDecoder().decode(GatewayEvent.self, from: Data(json.utf8))
    }

    @Test func gatewayReadyWithSessionAuthority() throws {
        let event = try decode(#"""
        {"type":"gateway.ready","payload":{"skin":{"name":"mono","colors":{}},"change_events":true,"heartbeat":true,
        "replay_epoch":"abc","session_authority":true}}
        """#)
        #expect(event.kind == .gatewayReady(GatewayReady(skinName: "mono", replayEpoch: "abc", heartbeat: true,
                                                         sessionAuthority: true)))
        #expect(event.sessionId == nil)
        #expect(event.seq == nil)
    }

    @Test func messageDeltaWithNullTextIsASegmentBoundary() throws {
        let event = try decode(#"{"type":"message.delta","session_id":"s1","seq":3,"payload":{"text":null,"segment":1}}"#)
        guard case .messageDelta(let payload) = event.kind else { Issue.record("expected message.delta"); return }
        #expect(payload.text == nil)
        #expect(payload.segment == 1)
    }

    @Test func toolStartAndComplete() throws {
        let start = try decode(#"""
        {"type":"tool.start","session_id":"s1","seq":5,"payload":{"tool_id":"call_1","name":"terminal",
        "args":{"command":"ls","timeout":30},"context":"ls"}}
        """#)
        #expect(start.kind == .toolStart(ToolStartPayload(toolId: "call_1", name: "terminal", context: "ls",
                                                          args: ["command": "ls", "timeout": 30])))

        let complete = try decode(#"""
        {"type":"tool.complete","session_id":"s1","seq":6,"payload":{"tool_id":"call_1","name":"terminal",
        "duration_s":0.25,"result":{"exit_code":0},"summary":"Listed 3 files","image_path":"/tmp/a.png"}}
        """#)
        guard case .toolComplete(let payload) = complete.kind else { Issue.record("expected tool.complete"); return }
        #expect(payload.durationS == 0.25)
        #expect(payload.result?["exit_code"] == 0)
        #expect(payload.summary == "Listed 3 files")
        #expect(payload.imagePath == "/tmp/a.png")
    }

    @Test func messageCompleteWithErrorAndStructuredText() throws {
        let failed = try decode(#"""
        {"type":"message.complete","session_id":"s1","payload":{"text":"","status":"error","error":"rate limited",
        "recoverable":true,"error_surface":{"layer":"provider","code":"429","retryable":true}}}
        """#)
        guard case .messageComplete(let payload) = failed.kind else { Issue.record("expected message.complete"); return }
        #expect(payload.status == .error)
        #expect(payload.error == "rate limited")
        #expect(payload.recoverable == true)

        let structured = try decode(#"{"type":"message.complete","payload":{"text":[{"type":"text"}],"status":"future"}}"#)
        guard case .messageComplete(let other) = structured.kind else { Issue.record("expected message.complete"); return }
        #expect(other.text == nil)
        #expect(other.status == .unknown("future"))

        let empty = try decode(#"{"type":"message.complete","payload":{}}"#)
        guard case .messageComplete(let defaults) = empty.kind else { Issue.record("expected message.complete"); return }
        #expect(defaults.text == "")
    }

    @Test func otherKnownEvents() throws {
        #expect(try decode(#"{"type":"error","session_id":"s1","payload":{"message":"agent init failed"}}"#).kind
            == .error(GatewayErrorPayload(message: "agent init failed")))
        #expect(try decode(#"{"type":"status.update","payload":{"kind":"compacting","text":"Compacting"}}"#).kind
            == .statusUpdate(StatusUpdatePayload(kind: "compacting", text: "Compacting")))
        #expect(try decode(#"{"type":"session.title","payload":{"session_id":"k1","title":"Trip"}}"#).kind
            == .sessionTitle(SessionTitlePayload(sessionId: "k1", title: "Trip")))
        #expect(try decode(#"{"type":"request.cancel","payload":{"id":"r-17","method":"approval","reason":"timeout"}}"#).kind
            == .requestCancel(RequestCancelPayload(id: "r-17", method: "approval", reason: "timeout")))
        #expect(try decode(#"{"type":"cron.changed","payload":{}}"#).kind == .cronChanged)
        #expect(try decode(#"{"type":"message.start","session_id":"s1"}"#).kind
            == .messageStart(MessageStartPayload()))
    }

    @Test func unknownTypeAndBadPayloadFallBackToOther() throws {
        #expect(try decode(#"{"type":"skin.changed","payload":{"name":"x"}}"#).kind == .other(["name": "x"]))
        // A known type with a payload that does not match its contract is kept, not dropped.
        #expect(try decode(#"{"type":"tool.start","payload":{"name":"x"}}"#).kind == .other(["name": "x"]))
    }

    @Test func approvalChoicesDropUnknownValues() throws {
        let request = try GatewayServerRequest(id: .string("r-1"), method: "approval", params: [
            "session_id": "s1", "request_id": "a", "choices": ["once", "later", "deny"],
        ])
        guard case .approval(let approval) = request.kind else { Issue.record("expected approval"); return }
        #expect(approval.choices == [.once, .deny])
        #expect(approval.command == "")
    }

    @Test func jsonValueRoundTrip() throws {
        let json = #"{"a":[1,2.5,"x",true,null],"b":{"c":-3}}"#
        let value = try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        #expect(value == ["a": [1, .double(2.5), "x", true, nil], "b": ["c": -3]])
        let again = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
        #expect(again == value)
        #expect(value["b"]?["c"]?.intValue == -3)
    }
}
