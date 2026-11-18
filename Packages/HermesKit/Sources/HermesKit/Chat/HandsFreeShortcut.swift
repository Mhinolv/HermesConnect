import Foundation
import Observation

/// One run of the "Start Hands-Free" App Shortcut (issue #124).
public struct HandsFreeRequest: Sendable, Equatable, Identifiable {
    public let id: UUID
    /// The server that the owner picked. `nil` uses the active server.
    public let server: UUID?

    public init(server: UUID?, id: UUID = UUID()) {
        self.id = id
        self.server = server
    }
}

/// What the root does with the request that waits.
public enum HandsFreeStep: Equatable, Sendable {
    /// Setup is not done: show the setup screen. The request is dropped.
    case dropForSetup
    /// Open the Voice tab, switch the server if necessary, and start Hands-Free.
    case run(HandsFreeRequest)
}

/// The shortcut puts its request here. The root takes it when the app is set up and App Lock is open.
@MainActor @Observable
public final class HandsFreeInbox {
    /// The request that waits. A newer run replaces it.
    public private(set) var pending: HandsFreeRequest?

    public init() {}

    @discardableResult
    public func post(server: UUID?) -> HandsFreeRequest {
        let request = HandsFreeRequest(server: server)
        pending = request
        return request
    }

    /// `nil` while nothing waits, or while App Lock covers the app (the request stays).
    /// Any other step removes the request, so it runs once.
    public func next(isSetUp: Bool, isLocked: Bool) -> HandsFreeStep? {
        guard let request = pending else { return nil }
        guard isSetUp else {
            pending = nil
            return .dropForSetup
        }
        guard !isLocked else { return nil }
        pending = nil
        return .run(request)
    }
}

@MainActor
public enum HandsFreeLaunch {
    /// The server to switch to first. `nil`: the request has no server, the server is active, or it was removed.
    public static func switchTarget(_ request: HandsFreeRequest, active: UUID?, servers: Set<UUID>) -> UUID? {
        guard let server = request.server, server != active, servers.contains(server) else { return nil }
        return server
    }

    /// Runs one request. A server that is not active becomes active with the normal switch before the session
    /// starts. A removed server falls back to the active server.
    public static func run(_ request: HandsFreeRequest, active: UUID?, servers: Set<UUID>,
                           switchServer: @MainActor (UUID) async -> Void,
                           start: @MainActor () async -> Void) async {
        if let server = switchTarget(request, active: active, servers: servers) {
            await switchServer(server)
        }
        await start()
    }
}
