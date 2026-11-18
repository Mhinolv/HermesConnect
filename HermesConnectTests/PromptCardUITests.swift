import Foundation
import HermesKit
import Testing
import UIKit
@testable import HermesConnect

/// Issue #117: a chat transport that records prompt answers. No network.
final class FakePromptTransport: ChatTransport, ServerRequestTransport, @unchecked Sendable {
    let events: AsyncStream<GatewayClientEvent>
    private let lock = NSLock()
    private var _values: [(JSONRPCID, String)] = []
    private var _clarifies: [(JSONRPCID, [String: String?]?, String)] = []
    private var _rejects: [(JSONRPCID, Int)] = []

    init() {
        events = AsyncStream { _ in }
    }

    var values: [(JSONRPCID, String)] { lock.withLock { _values } }
    var clarifies: [(JSONRPCID, [String: String?]?, String)] { lock.withLock { _clarifies } }
    var rejects: [(JSONRPCID, Int)] { lock.withLock { _rejects } }

    func startSession(source _: String, idempotencyKey _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func resumeSession(storedId _: String, source _: String) async throws -> ChatSessionRef {
        ChatSessionRef(liveId: "s1", storedId: "st1")
    }

    func submitPrompt(sessionId _: String, text _: String, retryBeforeRowId _: Int?) async throws -> Int? { 1 }
    func stopReply(sessionId _: String) async throws -> Bool { true }
    func history(sessionId _: String) async throws -> [TranscriptMessage] { [] }
    func answerApproval(requestId _: JSONRPCID, choice _: ApprovalChoice) async throws {}

    func rejectServerRequest(_ id: JSONRPCID, code: Int, message _: String) async throws {
        lock.withLock { _rejects.append((id, code)) }
    }

    func respondApproval(sessionId _: String, choice _: ApprovalChoice, requestId _: String?) async throws -> Int { 1 }
    func acknowledgeApproval(sessionId _: String, requestId _: String) async throws {}
    func pendingApprovals(sessionId _: String) async throws -> [ApprovalRequest] { [] }

    func answerValue(requestId: JSONRPCID, value: String) async throws {
        lock.withLock { _values.append((requestId, value)) }
    }

    func answerClarify(requestId: JSONRPCID, answers: [String: String?]?, outcome: String) async throws {
        lock.withLock { _clarifies.append((requestId, answers, outcome)) }
    }
}

/// Issue #117: the secret, password and question card. The tests tap with real hit tests and type with
/// `insertText`, the path of the keyboard. Set `HERMES_SCREENS_DIR` (with the `TEST_RUNNER_` prefix for
/// `xcodebuild`) to write the screens.
@MainActor
@Suite(.serialized) struct PromptCardUITests {
    static let value = "VALUE-5e1d hunter2"

    struct Screen {
        let window: UIWindow
        let controller: ChatViewController
        let model: ChatViewModel
        let transport: FakePromptTransport
    }

    enum Request {
        case secret, sudo, clarify

        var json: String {
            switch self {
            case .secret:
                #"{"session_id":"s1","env_var":"WEATHER_API_KEY","prompt":"Paste the API key for the weather skill. Hermes saves it in the server .env file."}"#
            case .sudo:
                #"{"session_id":"s1","command":"sudo apt-get install -y ffmpeg"}"#
            case .clarify:
                #"{"session_id":"s1","questions":[{"qid":"q1","question":"Which calendar?","choices":["Work","Personal"]},{"qid":"q2","question":"Which days?","choices":["Mon","Wed","Fri"],"multi_select":true},{"qid":"q3","question":"Any note for the invite?"}]}"#
            }
        }

        var method: String {
            switch self {
            case .secret: "secret"
            case .sudo: "sudo"
            case .clarify: "clarify"
            }
        }
    }

    private func serverRequest(_ request: Request, id: String) throws -> GatewayServerRequest {
        let params = try JSONDecoder().decode(JSONValue.self, from: Data(request.json.utf8))
        return try GatewayServerRequest(id: .string(id), method: request.method, params: params)
    }

    private func show(_ requests: [Request], style: UIUserInterfaceStyle = .light,
                      size: UIContentSizeCategory = .large, states: [ChatPromptCard.State] = []) throws -> Screen {
        let transport = FakePromptTransport()
        let start = Date(timeIntervalSince1970: 1_763_290_000)
        var messages = [
            ChatMessage(id: "u1", role: .user, text: "Set up the weather skill", date: start, delivery: .delivered),
            ChatMessage(id: "r1", role: .assistant, text: "I need a few things from you first.",
                        date: start.addingTimeInterval(4), reply: .complete),
        ]
        let ids = IdMaker()
        if !states.isEmpty {
            // Answered cards: the states that the model sets after Send, Cancel and a timeout.
            for (index, (request, state)) in zip(requests, states).enumerated() {
                var card = try #require(ChatPromptCard(request: try serverRequest(request, id: "srq-\(index + 1)"),
                                                       sessionId: "s1"))
                card.state = state
                messages.append(ChatMessage(id: "done\(index)", role: .assistant, text: "",
                                            date: start.addingTimeInterval(Double(6 + index)), prompt: card))
            }
        }
        let model = ChatViewModel(transport: transport, session: ChatSessionRef(liveId: "s1", storedId: "st1"),
                                  messages: messages, redrawInterval: .seconds(60),
                                  now: { start.addingTimeInterval(10) },
                                  makeId: { ids.next() })
        for (index, request) in requests.enumerated() where states.isEmpty {
            model.receive(.serverRequest(try serverRequest(request, id: "srq-\(index + 1)")))
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("PromptCardUITests")
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        // A window in the app scene draws, so the screens are not blank.
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.overrideUserInterfaceStyle = style
        window.overrideUserInterfaceStyle = style
        controller.traitOverrides.preferredContentSizeCategory = size
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle(controller)
        return Screen(window: window, controller: controller, model: model, transport: transport)
    }

    private func settle(_ controller: ChatViewController) {
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        controller.messagesCollectionView.visibleCells.forEach { $0.layoutIfNeeded() }
    }

    /// The id of the prompt card at `index`, in thread order.
    private func cardId(_ screen: Screen, _ index: Int = 0) throws -> String {
        let ids = screen.model.messages.filter { $0.prompt != nil }.map(\.id)
        guard index < ids.count else { throw PromptCardError.noCell("no card \(index)") }
        return ids[index]
    }

    private func cell(_ screen: Screen, _ index: Int = 0) throws -> ChatPromptCell {
        let id = try cardId(screen, index)
        settle(screen.controller)
        let collection = screen.controller.messagesCollectionView
        for section in 0..<collection.numberOfSections {
            let path = IndexPath(item: 0, section: section)
            if let cell = collection.cellForItem(at: path) as? ChatPromptCell,
               (screen.controller.messageForItem(at: path, in: collection) as? ChatBubble)?.row.id == id {
                cell.layoutIfNeeded()
                return cell
            }
        }
        let seen = collection.visibleCells.map { String(describing: Swift.type(of: $0)) }
        throw PromptCardError.noCell("\(id): sections \(collection.numberOfSections), cells \(seen), "
            + "messages \(screen.model.messages.map(\.id))")
    }

    enum PromptCardError: Error { case noCell(String), notHit(String) }

    /// A real hit test at the center of the view. Returns the view that takes the touch.
    @discardableResult
    private func hit(_ view: UIView, in window: UIWindow) throws -> UIView {
        let center = view.convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), to: window)
        guard let found = window.hitTest(center, with: nil), found === view || found.isDescendant(of: view) else {
            throw PromptCardError.notHit("hit test at \(center) did not find \(view.accessibilityLabel ?? "")")
        }
        return found
    }

    private func tap(_ button: UIButton, in window: UIWindow) throws {
        try hit(button, in: window)
        button.sendActions(for: .primaryActionTriggered)
    }

    /// A tap on the field, then the keyboard types the text.
    private func type(_ text: String, into field: UITextField, in window: UIWindow) throws {
        try hit(field, in: window)
        #expect(field.becomeFirstResponder())
        field.insertText(text)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        Issue.record("timed out")
    }

    @Test func secretCardShowsThePromptTheEnvVarAndAMaskedField() throws {
        let screen = try show([.secret])
        defer { screen.window.isHidden = true }
        let cell = try cell(screen)
        #expect(cell.titleLabel.attributedText?.string.hasSuffix("Hermes asks for a secret") == true)
        #expect(cell.bodyLabel.attributedText?.string.hasPrefix("Paste the API key") == true)
        #expect(cell.detailLabel.attributedText?.string == "WEATHER_API_KEY")
        let field = try #require(cell.fields.first)
        #expect(cell.fields.count == 1)
        #expect(field.isSecureTextEntry)
        #expect(field.autocorrectionType == .no)
        #expect(field.spellCheckingType == .no)
        #expect(field.enablesReturnKeyAutomatically, "the Send key is off while the field is empty")
        #expect(cell.sendButton?.isEnabled == false)
        // VoiceOver: the title and the prompt, then the field, then the buttons.
        let elements = try #require(cell.messageContainerView.accessibilityElements as? [UIView])
        #expect(elements.firstIndex(of: cell.titleLabel)! < elements.firstIndex(of: field)!)
        #expect(elements.firstIndex(of: field)! < elements.firstIndex(of: cell.sendButton!)!)
    }

    @Test func typeAndTapSendAnswersTheValueAndClearsTheField() async throws {
        let screen = try show([.secret])
        defer { screen.window.isHidden = true }
        let cell = try cell(screen)
        let field = try #require(cell.fields.first)
        try type(Self.value, into: field, in: screen.window)
        #expect(field.text == Self.value)
        let send = try #require(cell.sendButton)
        #expect(send.isEnabled)
        // A tap on Send: UIKit gives the touch to the button, so the thread tap does not start.
        for gesture in screen.controller.messagesCollectionView.gestureRecognizers ?? [] {
            guard let tap = gesture as? UITapGestureRecognizer, tap.isEnabled, tap.numberOfTapsRequired == 1,
                  tap.cancelsTouchesInView else { continue }
            #expect(!send.gestureRecognizerShouldBegin(tap), "a thread tap takes the touch")
        }
        try tap(send, in: screen.window)
        #expect(field.text?.isEmpty ?? true, "the field is empty after Send")
        #expect(!field.isFirstResponder)
        try await waitUntil { screen.model.messages.last?.prompt?.state == .sent }
        #expect(screen.transport.values.map(\.0) == [.string("srq-1")])
        #expect(screen.transport.values.map(\.1) == [Self.value])
        let after = try self.cell(screen)
        #expect(after.fields.isEmpty)
        #expect(after.sendButton == nil)
        #expect(after.resultLabel.attributedText?.string == "Sent")
        #expect(!String(describing: screen.model.messages).contains(Self.value))
        #expect(!after.messageContainerView.allText.contains(Self.value))
    }

    @Test func cancelAnswersWithAnErrorAndShowsCancelled() async throws {
        let screen = try show([.secret])
        defer { screen.window.isHidden = true }
        let cell = try cell(screen)
        try type("partial", into: try #require(cell.fields.first), in: screen.window)
        try tap(try #require(cell.cancelButton), in: screen.window)
        try await waitUntil { !screen.transport.rejects.isEmpty }
        #expect(screen.transport.rejects.map(\.0) == [.string("srq-1")])
        #expect(screen.transport.values.isEmpty)
        #expect(try self.cell(screen).resultLabel.attributedText?.string == "Cancelled")
    }

    @Test func sudoSendsWithTheReturnKey() async throws {
        let screen = try show([.sudo])
        defer { screen.window.isHidden = true }
        let cell = try cell(screen)
        #expect(cell.titleLabel.attributedText?.string.hasSuffix("Hermes asks for a password") == true)
        #expect(cell.detailLabel.attributedText?.string == "sudo apt-get install -y ffmpeg")
        let field = try #require(cell.fields.first)
        #expect(field.placeholder == "Password")
        try type(Self.value, into: field, in: screen.window)
        #expect(field.returnKeyType == .send)
        #expect(field.delegate?.textFieldShouldReturn?(field) == false)
        #expect(field.text?.isEmpty ?? true)
        try await waitUntil { !screen.transport.values.isEmpty }
        #expect(screen.transport.values.map(\.1) == [Self.value])
    }

    @Test func clarifyTakesTapsOnChoicesAndTypedText() async throws {
        let screen = try show([.clarify])
        defer { screen.window.isHidden = true }
        let cell = try cell(screen)
        #expect(cell.questionLabels.count == 3)
        #expect(cell.choiceButtons.map(\.accessibilityLabel) == ["Work", "Personal", "Mon", "Wed", "Fri"])
        #expect(cell.fields.count == 1)
        #expect(cell.fields.first?.isSecureTextEntry == false)
        try tap(cell.choiceButtons[0], in: screen.window)
        try tap(cell.choiceButtons[1], in: screen.window)
        #expect(cell.choiceButtons[1].accessibilityTraits.contains(.selected))
        #expect(!cell.choiceButtons[0].accessibilityTraits.contains(.selected), "one pick for a single question")
        try tap(cell.choiceButtons[2], in: screen.window)
        try tap(cell.choiceButtons[4], in: screen.window)
        #expect(cell.sendButton?.isEnabled == false, "the text question has no answer yet")
        try type("Bring the slides", into: try #require(cell.fields.first), in: screen.window)
        #expect(cell.sendButton?.isEnabled == true)
        try tap(try #require(cell.sendButton), in: screen.window)
        try await waitUntil { !screen.transport.clarifies.isEmpty }
        let sent = try #require(screen.transport.clarifies.first)
        #expect(sent.0 == .string("srq-1"))
        let expected: [String: String?] = ["q1": "Personal", "q2": #"["Mon","Fri"]"#, "q3": "Bring the slides"]
        #expect(sent.1 == expected)
        #expect(sent.2 == "submitted")
    }

    @Test func clarifyCancelSendsNoAnswers() async throws {
        let screen = try show([.clarify])
        defer { screen.window.isHidden = true }
        try tap(try #require(try cell(screen).cancelButton), in: screen.window)
        try await waitUntil { !screen.transport.clarifies.isEmpty }
        #expect(screen.transport.clarifies.first?.1 == nil)
        #expect(screen.transport.clarifies.first?.2 == "cancelled")
        #expect(screen.transport.rejects.isEmpty)
    }

    @Test func typedTextStaysAfterAReloadOfTheThread() throws {
        let screen = try show([.secret])
        defer { screen.window.isHidden = true }
        try type("abc", into: try #require(try cell(screen).fields.first), in: screen.window)
        screen.controller.messagesCollectionView.reloadData()
        let after = try cell(screen)
        #expect(after.fields.first?.text == "abc")
        #expect(after.sendButton?.isEnabled == true)
    }

    @Test func cardGrowsWithTheLargestTextSize() throws {
        for request in [Request.secret, .sudo, .clarify] {
            let card = try #require(ChatPromptCard(request: try serverRequest(request, id: "r1"), sessionId: "s1"))
            let regular = ChatPromptCardLayout.size(card, traits: UITraitCollection(preferredContentSizeCategory: .large),
                                                    maxWidth: 340)
            let ax5 = ChatPromptCardLayout.size(card, traits: UITraitCollection(
                preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), maxWidth: 340)
            #expect(ax5.height > regular.height)
            let frames = ChatPromptCardLayout.frames(card, traits: UITraitCollection(preferredContentSizeCategory: .large),
                                                     width: 340)
            #expect((frames.send?.height ?? 0) >= ChatApprovalCardLayout.minButtonHeight)
            // AX5: Send and Cancel each get a full row, so no word breaks.
            let stacked = ChatPromptCardLayout.frames(card, traits: UITraitCollection(
                preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge), width: 340)
            let send = try #require(stacked.send)
            let cancel = try #require(stacked.cancel)
            #expect(send.width == cancel.width && cancel.minY > send.maxY)
            #expect(frames.parts.allSatisfy { $0.1.height >= ChatApprovalCardLayout.minButtonHeight || $0.0.isQuestion })
        }
    }

    /// The screens in light, dark and AX5 (`.team/screens/117/`).
    @Test func screens() throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let states: [(String, [Request], [ChatPromptCard.State])] = [
            ("secret", [.secret], []), ("sudo", [.sudo], []), ("clarify", [.clarify], []),
            ("done", [.secret, .sudo, .clarify], [.sent, .cancelled, .expired]),
        ]
        for (name, requests, done) in states {
            for (style, size, suffix) in [(UIUserInterfaceStyle.light, UIContentSizeCategory.large, "light"),
                                          (.dark, .large, "dark"),
                                          (.light, .accessibilityExtraExtraExtraLarge, "ax5")] {
                let screen = try show(requests, style: style, size: size, states: done)
                if name == "secret" {
                    let cell = try cell(screen)
                    try type("hunter2", into: try #require(cell.fields.first), in: screen.window)
                    cell.fields.first?.resignFirstResponder()
                }
                settle(screen.controller)
                RunLoop.main.run(until: Date().addingTimeInterval(0.35))
                settle(screen.controller)
                let image = UIGraphicsImageRenderer(bounds: screen.window.bounds).image { _ in
                    screen.window.drawHierarchy(in: screen.window.bounds, afterScreenUpdates: true)
                }
                #expect(image.size.width > 0)
                if let folder { try image.pngData()?.write(to: folder.appending(path: "\(name)-\(suffix).png")) }
                screen.window.isHidden = true
            }
        }
    }
}

/// Card ids "card1", "card2", ... in order.
private final class IdMaker: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> String {
        lock.withLock {
            count += 1
            return "card\(count)"
        }
    }
}

private extension ChatPromptCardLayout.Part {
    var isQuestion: Bool {
        if case .question = self { return true }
        return false
    }
}

private extension UIView {
    /// The text of every label, field and button in the view.
    var allText: String {
        var parts: [String] = []
        if let label = self as? UILabel { parts.append(label.attributedText?.string ?? label.text ?? "") }
        if let field = self as? UITextField { parts.append(field.text ?? "") }
        if let button = self as? UIButton { parts.append(button.configuration?.title ?? "") }
        return (parts + subviews.map(\.allText)).joined(separator: "\n")
    }
}
