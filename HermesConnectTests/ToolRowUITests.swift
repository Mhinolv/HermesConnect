import Foundation
import HermesKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

// Issue #120: the tool row under a reply, its inline list, and the Voice tab tool line. Fakes only.

@MainActor
@Suite struct ToolRowUITests {
    private let start = Date(timeIntervalSince1970: 1_763_290_000)

    private static let threeTools = [
        ChatToolCall(id: "t1", name: "web_search", summary: "Searched 4 pages", duration: 1.2),
        ChatToolCall(id: "t2", name: "browser", summary: "Opened united.com and read the fare table", duration: 64),
        ChatToolCall(id: "t3", name: "calendar"),
    ]

    private struct Screen {
        let window: UIWindow
        let controller: ChatViewController
    }

    private func show(_ tools: [ChatToolCall], style: UIUserInterfaceStyle = .light,
                      size: UIContentSizeCategory = .large) -> Screen {
        let messages = [
            ChatMessage(id: "u1", role: .user, text: "Find a flight to Denver on Friday", date: start,
                        delivery: .delivered),
            ChatMessage(id: "r1", role: .assistant, text: "The 9:05 AM United flight is $142.",
                        date: start.addingTimeInterval(8), reply: .complete, promptId: "u1", tools: tools),
        ]
        let model = ChatViewModel(transport: OfflineChatTransport(), messages: messages)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ToolRowUITests")
        let controller = ChatViewController(model: model, recorder: FakeVoiceRecorder(), voiceFolder: folder)
        controller.autoPlayEnabled = { false }
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        controller.overrideUserInterfaceStyle = style
        window.overrideUserInterfaceStyle = style
        controller.traitOverrides.preferredContentSizeCategory = size
        window.rootViewController = controller
        window.makeKeyAndVisible()
        settle(controller)
        return Screen(window: window, controller: controller)
    }

    private func settle(_ controller: ChatViewController) {
        controller.view.layoutIfNeeded()
        controller.messagesCollectionView.layoutIfNeeded()
        controller.messagesCollectionView.visibleCells.forEach { $0.layoutIfNeeded() }
    }

    private func toolsCell(_ screen: Screen) throws -> ChatToolsCell {
        settle(screen.controller)
        let collection = screen.controller.messagesCollectionView
        let cell = try #require(collection.visibleCells.compactMap { $0 as? ChatToolsCell }.first,
                                "no tool row in \(collection.visibleCells.map { String(describing: type(of: $0)) })")
        cell.layoutIfNeeded()
        return cell
    }

    /// A real hit test at the center of the row finds the row button (lesson of #111).
    private func tapRow(_ cell: ChatToolsCell, in screen: Screen) throws {
        let button = cell.headerButton
        let center = button.convert(CGPoint(x: button.bounds.midX, y: button.bounds.midY), to: screen.window)
        let hit = try #require(screen.window.hitTest(center, with: nil))
        #expect(hit === button || hit.isDescendant(of: button), "hit test at \(center) found \(hit)")
        // The thread tap does not take the touch from the button.
        for tap in screen.controller.messagesCollectionView.gestureRecognizers ?? [] {
            guard let tap = tap as? UITapGestureRecognizer, tap.isEnabled, tap.numberOfTapsRequired == 1,
                  tap.cancelsTouchesInView else { continue }
            #expect(!button.gestureRecognizerShouldBegin(tap), "a thread tap takes the touch")
        }
        (hit as? UIControl ?? button).sendActions(for: .primaryActionTriggered)
    }

    @Test func toolRowShowsUnderTheReplyAndATapOpensAndClosesTheList() throws {
        let screen = show(Self.threeTools)
        defer { screen.window.isHidden = true }
        var cell = try toolsCell(screen)
        #expect(cell.headerButton.accessibilityLabel == "Used 3 tools")
        #expect(cell.headerButton.accessibilityValue == "Collapsed")
        #expect(cell.headerButton.accessibilityHint == "Shows the tools.")
        #expect(cell.headerButton.bounds.height >= 44)
        #expect(abs(cell.headerButton.bounds.width - cell.messageContainerView.bounds.width) < 0.5, "full row width")
        #expect(cell.rowViews.isEmpty)

        // The row sits under the reply bubble, aligned with its leading edge.
        let collection = screen.controller.messagesCollectionView
        let reply = try #require(collection.visibleCells.compactMap { $0 as? ChatTextCell }.first { cell in
            (cell.messageContainerView.convert(cell.messageContainerView.bounds, to: collection).minX) < 100
        })
        let replyFrame = reply.messageContainerView.convert(reply.messageContainerView.bounds, to: collection)
        let rowFrame = cell.headerButton.convert(cell.headerButton.bounds, to: collection)
        #expect(rowFrame.minY >= replyFrame.maxY - 0.5)
        #expect(abs(rowFrame.minX - replyFrame.minX) < 0.5)

        try tapRow(cell, in: screen)
        #expect(screen.controller.expandedTools == ["r1"])
        cell = try toolsCell(screen)
        #expect(cell.headerButton.accessibilityValue == "Expanded")
        #expect(cell.rowViews.map(\.accessibilityLabel) == [
            "web_search, Searched 4 pages, 1.2 seconds",
            "browser, Opened united.com and read the fare table, 1 minute 4 seconds",
            "calendar",
        ])
        #expect(cell.rowViews.map { $0.durationLabel.text } == ["1.2 s", "1 min 4 s", "—"])
        #expect(!cell.listView.isHidden)
        let tops = cell.rowViews.map(\.frame.minY)
        #expect(tops == tops.sorted(), "call order, top to bottom")
        #expect(cell.messageContainerView.accessibilityElements?.count == 4)

        try tapRow(cell, in: screen)
        #expect(screen.controller.expandedTools.isEmpty)
        cell = try toolsCell(screen)
        #expect(cell.rowViews.isEmpty)
        #expect(cell.headerButton.accessibilityValue == "Collapsed")
    }

    @Test func oneToolNamesTheTool() throws {
        let screen = show([ChatToolCall(id: "t1", name: "web_search", summary: "Searched", duration: 0.4)])
        defer { screen.window.isHidden = true }
        #expect(try toolsCell(screen).headerButton.accessibilityLabel == "Used web_search")
    }

    @Test func listGrowsWhenOpenAndWithTheLargestTextSize() {
        let large = UITraitCollection(preferredContentSizeCategory: .large)
        let ax5 = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let closed = ChatToolsLayout.size(Self.threeTools, expanded: false, traits: large, maxWidth: 300)
        let open = ChatToolsLayout.size(Self.threeTools, expanded: true, traits: large, maxWidth: 300)
        let openAX5 = ChatToolsLayout.size(Self.threeTools, expanded: true, traits: ax5, maxWidth: 300)
        #expect(closed.height == ChatToolsLayout.minHeaderHeight)
        #expect(open.height > closed.height)
        #expect(openAX5.height > open.height)
        let frames = ChatToolsLayout.frames(Self.threeTools, expanded: true, traits: ax5, width: 300)
        for row in frames.rows {
            #expect(row.duration.maxX <= 300 - ChatToolsLayout.listInset + 0.5)
            #expect(row.name.maxX <= row.duration.minX)
        }
    }

    // MARK: Screens (light, dark, AX5). Set TEST_RUNNER_HERMES_SCREENS_DIR to write them.

    @Test func screens() throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        if let folder { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
        let states: [(String, [ChatToolCall], Bool)] = [
            ("tools-1", [Self.threeTools[0]], false),
            ("tools-3-collapsed", Self.threeTools, false),
            ("tools-3-open", Self.threeTools, true),
        ]
        for (name, tools, open) in states {
            for (style, size, suffix) in Self.looks {
                let screen = show(tools, style: style, size: size)
                if open { try tapRow(try toolsCell(screen), in: screen) }
                settle(screen.controller)
                RunLoop.main.run(until: Date().addingTimeInterval(0.3))
                settle(screen.controller)
                let image = UIGraphicsImageRenderer(bounds: screen.window.bounds).image { _ in
                    screen.window.drawHierarchy(in: screen.window.bounds, afterScreenUpdates: true)
                }
                #expect(image.size.width > 0)
                if let folder { try image.pngData()?.write(to: folder.appending(path: "\(name)-\(suffix).png")) }
                screen.window.isHidden = true
            }
        }
        let handsFree = VoiceTabDisplay.make(state: .thinking, muted: false, thinkingSeconds: 6, tool: "web_search")
        let live = try #require(VoiceTabDisplay.live(phase: .working, muted: false, speaking: false, idleWarning: false,
                                                     stillWorking: false, tool: "web_search"))
        let app = AppModel.preview(setUp: true, hostKey: .sample)
        app.previewConnection(.connected(gateVersion: "demo"))
        for (name, display, mode) in [("voice-hands-free-tool", handsFree, VoiceTabMode.handsFree),
                                      ("voice-live-tool", live, .live)] {
            let view = NavigationStack {
                VoiceScreen(state: VoiceScreenState(display: display, targetTitle: "Weekend trip plan",
                                                    activeChatTitle: "Weekend trip plan", mode: mode,
                                                    liveAvailable: true, liveElapsed: 14,
                                                    showsLiveCapsule: mode == .live))
            }
            .environment(app)
            for (style, size, suffix) in Self.looks {
                let image = render(view, style: style, size: size)
                #expect(image.size.width > 0)
                if let folder { try image.pngData()?.write(to: folder.appending(path: "\(name)-\(suffix).png")) }
            }
        }
    }

    private static let looks: [(UIUserInterfaceStyle, UIContentSizeCategory, String)] = [
        (.light, .large, "light"), (.dark, .large, "dark"), (.light, .accessibilityExtraExtraExtraLarge, "ax5"),
    ]

    private func render(_ view: some View, style: UIUserInterfaceStyle, size: UIContentSizeCategory) -> UIImage {
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = style
        host.traitOverrides.preferredContentSizeCategory = size
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: 402, height: 874)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }
}
