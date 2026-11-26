import HermesKit
import SwiftUI

/// The shared connection status: the subtitle under the chat navigation title (issue #3).
/// It never shows the host name.
struct ConnectionStatusView: View {
    @Environment(AppModel.self) private var model
    /// Issue #179: the retry wait. Nil in previews and the DEBUG demo: a tap then connects directly.
    @Environment(LinkSupervisor.self) private var supervisor: LinkSupervisor?
    /// "Connected" shows for 2 seconds, then the subtitle hides.
    @State private var hidesConnected = false
    /// "Starting Hermes…" shows only when the stage takes more than 1 second (issue #4).
    @State private var showsStarting = false
    /// Stages that VoiceOver announced since the last "Connected". A retry does not announce them again.
    @State private var announced: Set<String> = []

    static let startingDelay: Duration = .seconds(1)

    var body: some View {
        content
            .font(.caption)
            .foregroundStyle(.secondary)
            .task(id: model.connection) {
                hidesConnected = false
                showsStarting = false
                switch model.connection {
                case .connected:
                    announced.removeAll()
                    try? await Task.sleep(for: .seconds(2))
                    if !Task.isCancelled { withAnimation { hidesConnected = true } }
                case .startingHermes:
                    try? await Task.sleep(for: Self.startingDelay)
                    guard !Task.isCancelled else { return }
                    showsStarting = true
                    announceOnce("Starting Hermes")
                case .notStarted:
                    announceOnce("Not connected. Hermes did not start.")
                default:
                    break
                }
            }
    }

    private func announceOnce(_ text: String) {
        guard announced.insert(text).inserted else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    @ViewBuilder private var content: some View {
        switch model.connection {
        case .idle:
            EmptyView()
        case .connecting:
            progress("Connecting…", spoken: "Connecting")
        case .startingHermes:
            if showsStarting {
                progress("Starting Hermes…", spoken: "Starting Hermes")
            } else {
                progress("Connecting…", spoken: "Connecting")
            }
        case .connected:
            if !hidesConnected {
                Text("Connected")
                    .accessibilityLabel("Connection status, Connected")
            }
        case .offline:
            // Issue #179: a tap retries at once and resets the wait to 2 s.
            Button {
                if let supervisor {
                    supervisor.retryNow()
                } else {
                    Task { await model.connect() }
                }
            } label: {
                if let retryAt = supervisor?.retryAt {
                    RetryCountdownLabel(deadline: retryAt)
                } else {
                    // No wait: the owner cancelled the trust sheet, or no retry is planned.
                    Label("Offline", systemImage: "arrow.clockwise")
                        .labelStyle(TrailingIconLabelStyle())
                }
            }
            .buttonStyle(.plain)
            // The label does not change each second, so VoiceOver does not read the countdown.
            .accessibilityLabel(supervisor?.retryAt == nil ? "Connection status, Offline"
                                : "Connection status, Offline. Hermes retries automatically.")
            .accessibilityHint(supervisor?.retryAt == nil ? "Double-tap to retry." : "Double-tap to retry now.")
        case .hostKeyChanged:
            Button {
                model.showsHostKeyError = true
            } label: {
                Label("Not connected", systemImage: "exclamationmark.shield.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Connection status, Not connected. The server identity changed.")
            .accessibilityHint("Double-tap for details.")
        case .notStarted:
            Button {
                model.showsHermesStartError = true
            } label: {
                Label("Not connected", systemImage: "exclamationmark.triangle.fill")
                    .labelStyle(.titleAndIcon)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .accessibilityLabel("Connection status, Not connected. Hermes did not start.")
            .accessibilityHint("Double-tap for details.")
        }
    }

    private func progress(_ text: String, spoken: String) -> some View {
        HStack(spacing: 4) {
            ProgressView().controlSize(.mini)
            Text(text)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Connection status, \(spoken)")
    }
}

/// Issue #145 and #178: VoiceOver says "Reconnecting" one time for each drop. A chat reattach (#145) and a
/// link reconnect (#178) of the same drop come close together, so a repeat in `window` is not posted.
@MainActor
enum ReconnectAnnouncement {
    static let window: Duration = .seconds(5)
    private static var last: ContinuousClock.Instant?

    static func shouldPost(now: ContinuousClock.Instant, last: ContinuousClock.Instant?) -> Bool {
        guard let last else { return true }
        return now - last >= window
    }

    static func post(now: ContinuousClock.Instant = .now) {
        guard shouldPost(now: now, last: last) else { return }
        last = now
        AccessibilityNotification.Announcement("Reconnecting").post()
    }
}

/// Issue #179: "Offline · Retry in 4 s ↻". The number counts down each second, in whole seconds.
struct RetryCountdownLabel: View {
    let deadline: ContinuousClock.Instant
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var seconds: Int

    init(deadline: ContinuousClock.Instant) {
        self.deadline = deadline
        _seconds = State(initialValue: ConnectBackoff.secondsLeft(until: deadline, now: .now))
    }

    var body: some View {
        Label {
            Text("Offline · Retry in \(seconds) s")
                .monospacedDigit()
                .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
        } icon: {
            Image(systemName: "arrow.clockwise")
        }
        .labelStyle(TrailingIconLabelStyle())
        .task(id: deadline) {
            while !Task.isCancelled {
                let now = ContinuousClock.now
                let left = ConnectBackoff.secondsLeft(until: deadline, now: now)
                if reduceMotion {
                    seconds = left
                } else {
                    withAnimation { seconds = left }
                }
                // Wake at the next whole second before the deadline. At the deadline the try starts.
                let next = deadline - .seconds(left - 1)
                guard next > now else { return }
                try? await Task.sleep(until: next, clock: .continuous)
            }
        }
    }
}

/// The text, then the symbol: "Offline ↻".
private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 4) {
            configuration.title
            configuration.icon
        }
    }
}

extension View {
    /// The "Hermes Did Not Start" alert of issue #4. "Install Steps" pushes the setup screen 3 (`InstallStepsView`).
    /// Put it inside the `NavigationStack`. The alert never shows server log text, the token or the port.
    func hermesStartAlert() -> some View {
        modifier(HermesStartAlert())
    }
}

struct HermesStartAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var showsInstallSteps = false

    func body(content: Content) -> some View {
        @Bindable var model = model
        content
            .alert(HermesStartAlert.title, isPresented: $model.showsHermesStartError) {
                Button("Install Steps") { showsInstallSteps = true }
                Button("OK", role: .cancel) {}
            } message: {
                Text(HermesStartAlert.message)
            }
            .navigationDestination(isPresented: $showsInstallSteps) { InstallStepsView() }
    }

    static let title = "Hermes Did Not Start"
    static let message = "The server refused the request. Check the install steps in Settings."
}

/// The chat navigation title with the connection status under it.
struct ChatTitleView: View {
    var body: some View {
        VStack(spacing: 0) {
            Text("Hermes").font(.headline)
            ConnectionStatusView()
        }
    }
}

struct ConnectionStatusView_Previews: PreviewProvider {
    static func model(_ state: AppModel.ConnectionState) -> AppModel {
        let model = AppModel.preview(setUp: true)
        model.previewConnection(state)
        return model
    }

    static var previews: some View {
        VStack(spacing: 24) {
            ChatTitleView().environment(model(.connecting))
            ChatTitleView().environment(model(.startingHermes))
            ChatTitleView().environment(model(.connected(gateVersion: "1")))
            ChatTitleView().environment(model(.offline(.unreachable)))
            // Issue #179: the wait before the next try, at 4 s and at the 30 s limit.
            RetryCountdownLabel(deadline: .now + .seconds(4)).font(.caption).foregroundStyle(.secondary)
            RetryCountdownLabel(deadline: .now + .seconds(30)).font(.caption).foregroundStyle(.secondary)
            ChatTitleView().environment(model(.hostKeyChanged(saved: .sample, received: .otherSample)))
            ChatTitleView().environment(model(.notStarted(.gateError("hermes-not-found"))))
        }
    }
}
