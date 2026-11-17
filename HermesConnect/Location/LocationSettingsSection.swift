import HermesKit
import SwiftUI
import UIKit

/// Settings > Location (issue #13).
struct LocationSettingsSection: View {
    @Environment(LocationController.self) private var location
    @Environment(\.openURL) private var openURL

    var body: some View {
        @Bindable var location = location
        Section {
            Toggle("Share Location Automatically", isOn: Binding(
                get: { location.isEnabled },
                set: { location.setEnabled($0) }
            ))
            LabeledContent("Access", value: location.access.title)
            if location.access == .off || location.access == .whileUsing {
                Button("Open Settings") { openSettings() }
            }
            Picker("Accuracy", selection: Binding(
                get: { location.precision },
                set: { location.setPrecision($0) }
            )) {
                Text("Precise").tag(LocationPrecision.precise)
                Text("Approximate").tag(LocationPrecision.approximate)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                LabeledContent("Last Sent", value: LocationController.lastSentText(location.status, now: context.date))
            }
            Button(manualTitle) { location.sendCurrentLocation() }
                .disabled(location.manualSend == .sending)
            if location.manualSend == .notDelivered {
                Label("Not Delivered", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.red)
            }
        } header: {
            Text("Location")
        } footer: {
            Text(footer)
        }
        .alert("Location Access Off", isPresented: $location.showsAccessOffAlert) {
            Button("Open Settings") { openSettings() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Allow location access for Hermes in Settings.")
        }
    }

    private var manualTitle: String {
        switch location.manualSend {
        case .idle, .sent: "Send Location Now"
        case .sending: "Sending…"
        case .notDelivered: "Try Again"
        }
    }

    private var footer: String {
        var lines = [String]()
        if location.access.allowsUpdates, !location.isPreciseAllowed {
            lines.append("Precise Location is off. Hermes gets an approximate area.")
        }
        if location.isEnabled, location.access == .whileUsing {
            lines.append("Choose Always in Settings so that Hermes can send your location in the background.")
        }
        if let error = location.status.lastError {
            lines.append("Last error: \(error)")
        }
        if lines.isEmpty {
            lines.append("Hermes sends your location to your own server when you move a long distance or arrive at a place.")
        }
        return lines.joined(separator: "\n")
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
}

struct LocationSettingsSection_Previews: PreviewProvider {
    static var previews: some View {
        Form { LocationSettingsSection() }
            .environment(LocationController.preview())
        Form { LocationSettingsSection() }
            .environment(LocationController.preview(access: .authorizedWhenInUse, precise: false))
        Form { LocationSettingsSection() }
            .environment(LocationController.preview(access: .denied, enabled: false))
    }
}
