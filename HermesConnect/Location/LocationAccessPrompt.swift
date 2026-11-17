import SwiftUI

/// The "Share Your Location" sheet. It shows once, after the first successful connect (issue #13).
struct LocationAccessSheet: View {
    @Environment(LocationController.self) private var location
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "location.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(.tint)
                    .symbolRenderingMode(.hierarchical)
                    .accessibilityHidden(true)
                Text("Share Your Location")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text("Hermes sends your location to your own server when you move or arrive at a place. Your agent uses it to answer questions about where you are.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                VStack(spacing: 12) {
                    Button {
                        location.allowFromPrompt()
                    } label: {
                        Text("Allow Location Access").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.large)
                    Button("Not Now") { location.closePrompt() }
                        .controlSize(.large)
                }
                .padding(.top, 8)
            }
            .padding(24)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        // At accessibility text sizes the text and the buttons do not fit in the medium height.
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.medium, .large])
    }
}

private struct LocationAccessPrompt: ViewModifier {
    @Environment(AppModel.self) private var model
    @Environment(LocationController.self) private var location
    @Environment(\.scenePhase) private var scenePhase
    let enabled: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { enabled && location.wantsPrompt },
                set: { if !$0 { location.closePrompt() } }
            )) {
                LocationAccessSheet()
            }
            .onChange(of: model.connection) { _, state in
                if case .connected = state { location.didConnect() }
            }
            // Issue #51: `initial` covers the first launch, which can start in the active phase.
            .onChange(of: scenePhase, initial: true) { _, phase in
                switch phase {
                case .active: location.appDidBecomeActive()
                case .background: location.appDidEnterBackground()
                default: break
                }
            }
    }
}

extension View {
    /// Shows the "Share Your Location" sheet after the first connect. On connect and when the app opens, it
    /// requests a new fix and sends it. `enabled` is false while another sheet shows.
    func locationAccessPrompt(enabled: Bool) -> some View {
        modifier(LocationAccessPrompt(enabled: enabled))
    }
}

struct LocationAccessSheet_Previews: PreviewProvider {
    static var previews: some View {
        Color.clear
            .sheet(isPresented: .constant(true)) { LocationAccessSheet() }
            .environment(LocationController.preview(access: .notDetermined, enabled: false))
    }
}
