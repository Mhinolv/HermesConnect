import Foundation
import Testing
@testable import HermesKit

/// Issue #104 regression: an `approval` server request in the stream must show a card in the chat.
/// Before the fix, `ChatViewModel.receive` dropped `.serverRequest`, so the tool call stayed blocked.
@MainActor
struct ApprovalRegressionTests {
    @Test func approvalRequestInTheStreamShowsACard() throws {
        let transport = FakeChatTransport()
        let vm = ChatViewModel(transport: transport, session: ChatSessionRef(liveId: "s1", storedId: "st1"),
                               redrawInterval: .seconds(60))
        let params: JSONValue = .object([
            "session_id": .string("s1"), "request_id": .string("a1"), "command": .string("gcal update"),
            "description": .string("Update a calendar event"),
            "choices": .array([.string("once"), .string("session"), .string("always"), .string("deny")]),
        ])
        vm.receive(.serverRequest(try GatewayServerRequest(id: .string("srq-1"), method: "approval", params: params)))
        #expect(vm.messages.count == 1)
        #expect(vm.messages.first?.role == .assistant)
    }
}
