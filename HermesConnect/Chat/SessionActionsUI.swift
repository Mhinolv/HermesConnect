import HermesKit
import Observation
import SwiftUI

/// Issue #64: the rename alert, the delete dialog and the error alert of the session list, the Archived list
/// and the chat title menu. One state object per screen. `SessionListModel` makes the calls.
@MainActor @Observable
final class SessionActionState {
    /// The session that the rename alert shows.
    var renameTarget: SessionActionTarget?
    var renameText = ""
    var renameSelection: TextSelection?
    /// The session that the delete dialog asks about.
    var deleteTarget: SessionActionTarget?
    /// The failed action that the error alert shows.
    var failure: SessionActionFailure?

    func startRename(_ target: SessionActionTarget) {
        renameText = target.title
        renameSelection = TextSelection(range: renameText.startIndex..<renameText.endIndex)
        renameTarget = target
    }

    /// "Save" is off when the trimmed text is empty or the same as the current title.
    var canSave: Bool {
        guard let renameTarget else { return false }
        return SessionActionText.canSave(renameText, current: renameTarget.title)
    }

    func saveRename(_ model: SessionListModel) {
        guard let target = renameTarget, canSave else { return }
        let text = renameText
        renameTarget = nil
        run(.rename, model) { try await $0.rename(target.id, to: text) }
    }

    func archive(_ id: String, _ model: SessionListModel) {
        run(.archive, model) { try await $0.archive(id) }
    }

    func unarchive(_ id: String, _ model: SessionListModel) {
        run(.unarchive, model) { try await $0.unarchive(id) }
    }

    func confirmDelete(_ model: SessionListModel) {
        guard let target = deleteTarget else { return }
        deleteTarget = nil
        run(.delete, model) { try await $0.delete(target.id) }
    }

    private func run(_ action: SessionAction, _ model: SessionListModel,
                     _ body: @escaping @MainActor (SessionListModel) async throws -> Void) {
        Task {
            do {
                try await body(model)
            } catch {
                failure = SessionActionFailure(action: action, message: SessionActionError.message(for: error))
            }
        }
    }
}

/// The session of an action, with the title that the rename alert starts with.
struct SessionActionTarget: Identifiable, Equatable {
    var id: String
    var title: String

    init(id: String, title: String) {
        self.id = id
        self.title = title
    }

    init(_ item: SessionListItem) {
        self.init(id: item.id, title: item.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    }
}

enum SessionAction: Equatable {
    case rename, archive, unarchive, delete
}

struct SessionActionFailure: Identifiable, Equatable {
    var action: SessionAction
    var message: String
    var id: String { "\(action)-\(message)" }
    var title: String { SessionActionText.failureTitle(action) }
}

/// The UI strings of issue #64. "Chat" is the word in every string, as in "New Chat".
enum SessionActionText {
    static let renameTitle = "Rename Chat"
    static let renamePlaceholder = "Title"
    static let deleteTitle = "Delete This Chat?"
    static let deleteMessage = "This deletes the chat on all your devices and apps, including Hermes on your Mac. You can't undo this."
    static let deleteButton = "Delete Chat"
    static let archivedTitle = "Archived"

    static func failureTitle(_ action: SessionAction) -> String {
        switch action {
        case .rename: "Couldn't Rename Chat"
        case .archive: "Couldn't Archive Chat"
        case .unarchive: "Couldn't Unarchive Chat"
        case .delete: "Couldn't Delete Chat"
        }
    }

    static func canSave(_ text: String, current: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed != current.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The rename alert, the delete dialog and the error alert.
struct SessionActionDialogs: ViewModifier {
    @Bindable var state: SessionActionState
    let model: SessionListModel

    func body(content: Content) -> some View {
        content
            .alert(SessionActionText.renameTitle, isPresented: present($state.renameTarget), presenting: state.renameTarget) { _ in
                TextField(SessionActionText.renamePlaceholder, text: $state.renameText, selection: $state.renameSelection)
                    .submitLabel(.done)
                Button("Cancel", role: .cancel) {}
                Button("Save") { state.saveRename(model) }
                    .disabled(!state.canSave)
            }
            .confirmationDialog(SessionActionText.deleteTitle, isPresented: present($state.deleteTarget),
                                titleVisibility: .visible, presenting: state.deleteTarget) { _ in
                Button(SessionActionText.deleteButton, role: .destructive) { state.confirmDelete(model) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text(SessionActionText.deleteMessage)
            }
            .alert(state.failure?.title ?? "", isPresented: present($state.failure), presenting: state.failure) { _ in
                Button("OK") {}
            } message: { failure in
                Text(failure.message)
            }
    }

    /// `true` while the value is set. A dismiss clears it.
    private func present<Value>(_ value: Binding<Value?>) -> Binding<Bool> {
        Binding(get: { value.wrappedValue != nil }, set: { if !$0 { value.wrappedValue = nil } })
    }
}

extension View {
    func sessionActionDialogs(_ state: SessionActionState, model: SessionListModel) -> some View {
        modifier(SessionActionDialogs(state: state, model: model))
    }
}

/// The Archived list (issue #64): rows with `archived=only`. The trailing swipe is Unarchive, then Delete.
struct ArchivedSessionsScreen: View {
    let model: SessionListModel
    @State private var actions = SessionActionState()

    var body: some View {
        List {
            ForEach(model.archivedSessions) { item in
                NavigationLink(value: ChatRoute.session(item.id)) {
                    SessionRow(item: item)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Unarchive", systemImage: "tray.and.arrow.up") { actions.unarchive(item.id, model) }
                        .tint(.indigo)
                    // No destructive role: that role removes the row before the dialog answers.
                    Button("Delete", systemImage: "trash") { actions.deleteTarget = SessionActionTarget(item) }
                        .tint(.red)
                }
            }
        }
        .listStyle(.plain)
        .overlay {
            if !model.hasLoadedArchived {
                ProgressView()
            } else if model.archivedSessions.isEmpty {
                ContentUnavailableView("No Archived Chats", systemImage: "archivebox")
            }
        }
        .refreshable { await model.refreshArchived() }
        .navigationTitle(SessionActionText.archivedTitle)
        .navigationBarTitleDisplayMode(.inline)
        .sessionActionDialogs(actions, model: model)
        .task { await model.refreshArchived() }
    }
}
