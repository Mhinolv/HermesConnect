import SwiftUI
import UIKit

/// The full-screen App Lock cover. It also hides the content while the app is not active.
struct AppLockCover: View {
    let showsUnlockButton: Bool
    let onUnlock: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Hermes Is Locked")
                .font(.title2.bold())
            if showsUnlockButton {
                Button(action: onUnlock) {
                    Label(Authenticator.unlockButtonTitle, systemImage: Authenticator.unlockButtonSymbol)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(uiColor: .systemBackground))
        .accessibilityElement(children: .contain)
    }
}

/// Puts the cover in its own window above the app window, so it also covers sheets.
@MainActor
final class LockWindowPresenter {
    private var window: UIWindow?

    func show(_ cover: AppLockCover) {
        if let window, let host = window.rootViewController as? UIHostingController<AppLockCover> {
            host.rootView = cover
            window.isHidden = false
            return
        }
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).first else { return }
        let window = UIWindow(windowScene: scene)
        window.windowLevel = .alert + 1
        window.rootViewController = UIHostingController(rootView: cover)
        window.isHidden = false
        self.window = window
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}

/// Connects the scene phase to App Lock: lock on launch and on return after 5 minutes,
/// cover the app while it is not active, and ask for Face ID when the app becomes active.
struct AppLockModifier: ViewModifier {
    let model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var presenter = LockWindowPresenter()
    @State private var promptPending = true
    @State private var authenticating = false

    private var showsCover: Bool {
        model.lock.isEnabled && (model.lock.isLocked || scenePhase != .active)
    }

    func body(content: Content) -> some View {
        content
            .onAppear { update() }
            .onChange(of: scenePhase) { old, new in
                if new == .background {
                    model.didEnterBackground()
                } else if old == .background {
                    let wasLocked = model.lock.isLocked
                    model.willEnterForeground()
                    if model.lock.isLocked && !wasLocked { promptPending = true }
                }
                update()
            }
            .onChange(of: model.lock) { update() }
    }

    private func update() {
        guard showsCover else {
            presenter.hide()
            return
        }
        presenter.show(AppLockCover(showsUnlockButton: model.lock.isLocked) { unlock() })
        if model.lock.isLocked, scenePhase == .active, promptPending {
            promptPending = false
            unlock()
        }
    }

    private func unlock() {
        guard !authenticating else { return }
        // A device with no passcode cannot authenticate. Do not lock the owner out.
        guard Authenticator.canAuthenticate() else {
            model.unlockSucceeded()
            return
        }
        authenticating = true
        Task {
            let success = await Authenticator.authenticate()
            authenticating = false
            if success { model.unlockSucceeded() }
        }
    }
}

extension View {
    func appLock(_ model: AppModel) -> some View {
        modifier(AppLockModifier(model: model))
    }
}

struct AppLockCover_Previews: PreviewProvider {
    static var previews: some View {
        AppLockCover(showsUnlockButton: true) {}
    }
}
