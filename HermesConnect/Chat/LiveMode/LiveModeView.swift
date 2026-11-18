import HermesKit
import SwiftUI

// Issue #98: a minimal, plain view to drive the GPT-Live engine. The final Voice UI comes from #101
// (the Voice tab). Replace this file then. `LiveModeSessionModel` and `LiveModeController` stay.

/// The chat toolbar button that opens the Live sheet. The chat screen adds it with one modifier.
struct LiveModeEntry: ViewModifier {
    let chat: ChatViewModel
    let service: (any LiveModeService)?
    @State private var session: LiveModeSessionModel?

    func body(content: Content) -> some View {
        if let service {
            content
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Live Voice", systemImage: "waveform") {
                            session = LiveModeSessionModel(hermes: chat, service: service)
                        }
                    }
                }
                .sheet(isPresented: Binding(get: { session != nil }, set: { if !$0 { close() } })) {
                    if let session {
                        LiveModeView(model: session, onClose: close)
                            .presentationDetents([.medium, .large])
                    }
                }
                .onDisappear(perform: close)
        } else {
            content
        }
    }

    /// The sheet closed or the chat left: no session runs on.
    private func close() {
        session?.end(.hangUp)
        session = nil
    }
}

/// The Live controls as plain rows: availability and cost, state, elapsed time, Start, Mute and End.
struct LiveModeView: View {
    @Bindable var model: LiveModeSessionModel
    var onClose: () -> Void = {}

    private var controller: LiveModeController { model.controller }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("Status", value: controller.display?.label ?? "Off")
                    LabeledContent("Time") {
                        Text(LiveModeFormat.elapsed(controller.elapsedSeconds)).monospacedDigit()
                    }
                    LabeledContent("Cost", value: model.isAvailable ? LiveModeFormat.costCaption : model.availabilityText)
                    if controller.phase == .failed, let failure = controller.failure {
                        Text(failure).foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Live mode talks to OpenAI gpt-live. Each request goes to Hermes in this chat.")
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(controller.accessibilityLabel)

                Section {
                    if !controller.isActive || controller.phase == .failed {
                        Button(controller.phase == .failed ? "Try Again" : "Start Live",
                               systemImage: "dot.radiowaves.left.and.right") {
                            Task { await model.start() }
                        }
                        .disabled(!model.isAvailable)
                    } else {
                        Button(controller.muted ? "Unmute" : "Mute", systemImage: "mic.slash.fill") {
                            controller.toggleMute()
                        }
                        .disabled(controller.phase == .connecting)
                    }
                    if controller.isActive {
                        Button("End", systemImage: "phone.down.fill", role: .destructive) {
                            model.end(.hangUp)
                        }
                    }
                }
                if let end = controller.lastEnd, !controller.isActive {
                    Section { Text(end.toast) }
                }
            }
            .navigationTitle("Live Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done", action: onClose) }
            }
        }
        .accessibilityAction(.magicTap) { controller.toggleMute() }
        .accessibilityAction(.escape) { model.end(.hangUp) }
        .task { await model.refreshStatus() }
        .onChange(of: controller.phase) { _, phase in
            // VoiceOver hears only "Hermes is working" and the end, so the voice model does not hear it.
            if phase == .working { UIAccessibility.post(notification: .announcement, argument: "Hermes is working") }
        }
        .onChange(of: controller.lastEnd?.serial) { _, _ in
            if let end = controller.lastEnd { UIAccessibility.post(notification: .announcement, argument: end.toast) }
        }
        .alert("Microphone Access Off", isPresented: $model.microphoneDenied) {
            Button("Cancel", role: .cancel) {}
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            }
        } message: {
            Text("Turn on Microphone for Hermes in Settings to use Live mode.")
        }
    }
}
