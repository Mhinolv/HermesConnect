import SwiftUI
import HermesKit

@main
struct HermesConnectApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}

struct RootView: View {
    var body: some View {
        NavigationStack {
            ContentUnavailableView("Not connected", systemImage: "bolt.horizontal.circle",
                                   description: Text("Add your Hermes server to start."))
                .navigationTitle("Hermes")
        }
    }
}
