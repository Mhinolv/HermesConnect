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
                        .toolbar {
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
        }
        .sheet(isPresented: $showSetup) { SetupFlowView() }
        .sheet(isPresented: $showSettings) { SettingsView() }
    }
}

struct RootView_Previews: PreviewProvider {
    static var previews: some View {
        RootView().environment(AppModel.preview(setUp: false))
        RootView().environment(AppModel.preview(setUp: true))
    }
}
