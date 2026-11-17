import SwiftUI
import HermesKit

@main
struct HermesConnectApp: App {
    @State private var model = AppModel.live()
    /// Made at launch, also for a relaunch in the background by a location event (issue #13).
    @State private var location = LocationController.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(location)
                .appLock(model)
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @State private var showSetup = false
    @State private var showSettings = false

    var body: some View {
        NavigationStack {
            Group {
                if model.isSetUp {
                    ContentUnavailableView("Not Connected", systemImage: "bolt.horizontal.circle",
                                           description: Text("Chat comes in a later version."))
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .principal) { ChatTitleView() }
                            ToolbarItem(placement: .topBarTrailing) {
                                Button("Settings", systemImage: "gearshape") { showSettings = true }
                            }
                        }
                } else {
                    ContentUnavailableView {
                        Label("Set Up Hermes", systemImage: "key.horizontal")
                    } description: {
                        Text("Connect this iPhone to your Hermes server.")
                    } actions: {
                        Button("Set Up Server") { showSetup = true }
                            .buttonStyle(.glassProminent)
                    }
                }
            }
            .navigationTitle("Hermes")
            .hermesStartAlert()
        }
        .sheet(isPresented: $showSetup) { SetupFlowView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
        .hostTrustPresenter(enabled: !showSetup && !showSettings)
        .locationAccessPrompt(enabled: !showSetup && !showSettings && model.pendingTrust == nil)
        .task(id: model.isSetUp) {
            if model.isSetUp { await model.connect() }
        }
        .onChange(of: showSettings) { _, shown in
            // A new server or a forgotten host key leaves the status idle. Connect when Settings closes.
            if !shown, model.isSetUp, model.connection == .idle { Task { await model.connect() } }
        }
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environment(AppModel.preview(setUp: false)).environment(LocationController.preview())
        RootView().environment(AppModel.preview(setUp: true)).environment(LocationController.preview())
    }
}
