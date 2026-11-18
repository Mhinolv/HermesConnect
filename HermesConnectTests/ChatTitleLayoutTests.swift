import Foundation
import HermesKit
import SwiftUI
import Testing
import UIKit
@testable import HermesConnect

// Issue #107: a long chat title ran under the back button and the Live Voice button.
// The tests push the chat title and the Live entry, as `ChatScreen` adds them, and measure the bar in a window.

private struct NoLive: LiveModeService {
    func voiceLiveStatus() async throws -> VoiceLiveStatus? { nil }
    func createVoiceLiveSession(offerSDP _: String, history _: [VoiceLiveHistoryItem]) async throws
        -> VoiceLiveSessionAnswer { VoiceLiveSessionAnswer(sessionId: "s", sdp: "answer") }
}

/// The frames in the navigation bar, in window points.
private struct TitleBar {
    /// All the views of the principal title, as one frame.
    let title: CGRect
    let back: CGRect
    let live: CGRect
    let image: UIImage
}

@MainActor
@Suite(.serialized) struct ChatTitleLayoutTests {
    /// The owner titles from the issue screenshots.
    nonisolated static let long = "Add Post Falls house meeting to Google Calendar"
    nonisolated static let boondocking = "Boondocking spots near Gold Bar"
    nonisolated static let short = "Trip"
    private let width: CGFloat = 402

    @Test(arguments: [long, boondocking], [UIContentSizeCategory.large, .accessibilityExtraExtraExtraLarge])
    func longTitleStaysBetweenTheBarButtons(title: String, size: UIContentSizeCategory) throws {
        let bar = try render(title, style: .light, size: size)
        #expect(bar.title.minX >= bar.back.maxX, "title \(bar.title) runs under the back button \(bar.back)")
        #expect(bar.title.maxX <= bar.live.minX, "title \(bar.title) runs under Live Voice \(bar.live)")
        #expect(bar.title.width > 100, "title \(bar.title) is too narrow")
    }

    @Test func shortTitleKeepsItsWidthAndIsCentered() throws {
        let bar = try render(Self.short, style: .light, size: .large)
        #expect(bar.title.width < 120, "short title \(bar.title) must not stretch")
        #expect(abs(bar.title.midX - width / 2) <= 1, "short title \(bar.title) is not centered")
        #expect(bar.title.minX >= bar.back.maxX)
        #expect(bar.title.maxX <= bar.live.minX)
    }

    // MARK: Screenshots (long, boondocking and short, light, dark, AX5). Set TEST_RUNNER_HERMES_SCREENS_DIR to write them.

    @Test func screenshots() throws {
        let folder = ProcessInfo.processInfo.environment["HERMES_SCREENS_DIR"].map { URL(fileURLWithPath: $0) }
        for (title, name) in [(Self.long, "long"), (Self.boondocking, "boondocking"), (Self.short, "short")] {
            for (style, size, suffix) in [(UIUserInterfaceStyle.light, UIContentSizeCategory.large, "light"),
                                          (.dark, .large, "dark"),
                                          (.light, .accessibilityExtraExtraExtraLarge, "ax5")] {
                let bar = try render(title, style: style, size: size)
                #expect(bar.image.size.width > 0)
                if let folder { try bar.image.pngData()?.write(to: folder.appending(path: "\(name)-\(suffix).png")) }
            }
        }
    }

    private func render(_ title: String, style: UIUserInterfaceStyle, size: UIContentSizeCategory) throws -> TitleBar {
        let chat = ChatViewModel(transport: OfflineChatTransport())
        let view = NavigationStack(path: .constant([1])) {
            Text("Chats").navigationTitle("Chats")
                .navigationDestination(for: Int.self) { _ in
                    Color(uiColor: .systemBackground)
                        .navigationBarTitleDisplayMode(.inline)
                        .modifier(ChatTitleBar { maxWidth in
                            ChatNavigationTitle(title: title, onRename: {}, maxWidth: maxWidth)
                        })
                        .modifier(LiveModeEntry(chat: chat, service: NoLive()))
                }
        }
        .environment(AppModel.preview(setUp: true))
        let host = UIHostingController(rootView: view)
        host.overrideUserInterfaceStyle = style
        host.traitOverrides.preferredContentSizeCategory = size
        let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        let window = scene.map { UIWindow(windowScene: $0) } ?? UIWindow()
        window.frame = CGRect(x: 0, y: 0, width: width, height: 874)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        window.layoutIfNeeded()

        let navBar = try #require(first(in: window) { $0 is UINavigationBar })
        let control = try #require(first(in: navBar) { name($0).contains("TitleControl") }, "no title control")
        let title = frames(below: control, in: window).reduce(control.convert(control.bounds, to: window)) { $0.union($1) }
        let buttons = all(in: navBar) { name($0) == "_UIButtonBarButton" }
            .map { $0.convert($0.bounds, to: window) }
            .sorted { $0.minX < $1.minX }
        let back = try #require(buttons.first, "no back button")
        let live = try #require(buttons.last, "no Live Voice button")
        try #require(buttons.count >= 2 && live.minX > back.maxX, "bar buttons: \(buttons)")
        let image = UIGraphicsImageRenderer(bounds: CGRect(x: 0, y: 0, width: width, height: navBar.frame.maxY + 120))
            .image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        return TitleBar(title: title, back: back, live: live, image: image)
    }

    private func name(_ view: UIView) -> String { String(describing: type(of: view)) }

    private func first(in view: UIView, where match: (UIView) -> Bool) -> UIView? {
        if match(view) { return view }
        for sub in view.subviews { if let found = first(in: sub, where: match) { return found } }
        return nil
    }

    private func all(in view: UIView, where match: (UIView) -> Bool) -> [UIView] {
        (match(view) ? [view] : []) + view.subviews.flatMap { all(in: $0, where: match) }
    }

    /// The frames of the shown views under a view, in window points.
    private func frames(below view: UIView, in window: UIWindow) -> [CGRect] {
        view.subviews.filter { !$0.isHidden && $0.alpha > 0.01 }.flatMap { sub -> [CGRect] in
            let own = sub.bounds.isEmpty ? [] : [sub.convert(sub.bounds, to: window)]
            return own + frames(below: sub, in: window)
        }
    }
}
