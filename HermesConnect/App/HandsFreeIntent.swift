import AppIntents
import Foundation
import HermesKit

/// Issue #124: a saved server, for the "Server" parameter of "Start Hands-Free".
struct ServerEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Server"
    static let defaultQuery = ServerEntityQuery()

    let id: UUID
    let name: String

    init(id: UUID, name: String) {
        self.id = id
        self.name = name
    }

    init(_ profile: ServerProfile) {
        self.init(id: profile.id, name: profile.name)
    }

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

/// The saved servers. Shortcuts can ask for them while the app is not open, so the query reads the server list
/// file. Tests give a fake list.
struct ServerEntityQuery: EntityQuery {
    @MainActor static var loadList: () -> ServerList = {
        (try? FileServerListStore.applicationSupport().load()) ?? ServerList()
    }

    init() {}

    func entities(for identifiers: [UUID]) async throws -> [ServerEntity] {
        let list = await Self.currentList()
        return identifiers.compactMap { id in list.server(id: id).map(ServerEntity.init) }
    }

    func suggestedEntities() async throws -> [ServerEntity] {
        await Self.currentList().servers.map(ServerEntity.init)
    }

    /// The default value of the parameter: the active server.
    func defaultResult() async -> ServerEntity? {
        await Self.currentList().active.map(ServerEntity.init)
    }

    @MainActor private static func currentList() -> ServerList { loadList() }
}

/// Issue #124: "Start Hands-Free". It opens the app on the Voice tab and starts a Hands-Free session with the
/// server. The root waits for setup and App Lock (`HandsFreeInbox`). Live mode from Siri is a later issue.
struct StartHandsFreeIntent: AppIntent {
    static let title: LocalizedStringResource = "Start Hands-Free"
    static let description = IntentDescription("Open the Voice tab and start Hands-Free with your agent.")
    /// The microphone needs the app in the foreground. `openAppWhenRun` is deprecated in iOS 26.
    static let supportedModes: IntentModes = .foreground

    /// `nil` uses the active server.
    @Parameter(title: "Server")
    var server: ServerEntity?

    init() {}

    init(server: ServerEntity?) {
        self.server = server
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        HandsFreeInbox.shared.post(server: server?.id)
        return .result()
    }
}

extension HandsFreeInbox {
    /// The inbox of the app process. `RootView` takes from it.
    static let shared = HandsFreeInbox()
}
