import Foundation
import Testing
@testable import HermesKit

/// Issue #67 regression: text that starts with `/` must never go to `prompt.submit` as plain text.
/// This suite uses only the API from before the fix, so it compiles and fails on the old code.
@MainActor
@Suite(.timeLimit(.minutes(1))) struct SlashCommandRegressionTests {
    @Test func newAndUsageNeverGoToPromptSubmit() async {
        let transport = FakeChatTransport()
        let vm = ChatViewModel(transport: transport, redrawInterval: .seconds(60))
        await vm.send("/new")?.value
        await vm.send("/usage")?.value
        #expect(transport.submits.map(\.text) == [])
        #expect(!vm.messages.contains { $0.role == .user && $0.text.hasPrefix("/") })
    }
}
