import SwiftUI
import HermesKit

@main
struct HermesConnectApp: App {
    @State private var model = AppModel.live()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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
        RootView().environment(AppModel.preview(setUp: false))
        RootView().environment(AppModel.preview(setUp: true))
    }
}
