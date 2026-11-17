import Citadel
import Foundation
import NIOCore
import NIOPosix
import NIOSSH

/// A listener on `127.0.0.1:<random port>` of this device. Each accepted TCP connection opens one
/// `direct-tcpip` channel to `127.0.0.1:<remotePort>` on the server and copies bytes both ways.
///
/// - The listener binds to the loopback only, so other devices on the network cannot use it.
/// - The target host is always `LoopbackForwardTarget.remoteHost`. The gate key line allows only that host.
/// - The listener and the SSH channels use the event loop of the SSH client, so the glue needs no locks.
final class CitadelLoopbackForward: LoopbackForward, @unchecked Sendable {
    let localPort: Int
    private let listener: any Channel
    private let connections: ConnectionSet

    private init(localPort: Int, listener: any Channel, connections: ConnectionSet) {
        self.localPort = localPort
        self.listener = listener
        self.connections = connections
    }

    /// The `direct-tcpip` request for one connection. The target is always the server loopback.
    static func channelRequest(remotePort: Int, originatorPort: Int) throws -> SSHChannelType.DirectTCPIP {
        SSHChannelType.DirectTCPIP(
            targetHost: LoopbackForwardTarget.remoteHost, targetPort: remotePort,
            originatorAddress: try SocketAddress(ipAddress: LoopbackForwardTarget.localHost, port: originatorPort))
    }

    static func open(client: SSHClient, remotePort: Int) async throws -> CitadelLoopbackForward {
        let box = ClientBox(client: client)
        let connections = ConnectionSet()
        let listener = try await ServerBootstrap(group: client.eventLoop)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(.allowRemoteHalfClosure, value: true)
            .childChannelInitializer { inbound in
                let (ours, theirs) = GlueHandler.matchedPair()
                let local = NIOLoopBound(ours, eventLoop: inbound.eventLoop)
                let remote = NIOLoopBound(theirs, eventLoop: inbound.eventLoop)
                let promise = inbound.eventLoop.makePromise(of: Void.self)
                promise.completeWithTask {
                    let request = try channelRequest(remotePort: remotePort,
                                                     originatorPort: inbound.remoteAddress?.port ?? 0)
                    let ssh = try await box.client.createDirectTCPIPChannel(using: request) { channel in
                        channel.eventLoop.makeCompletedFuture {
                            try channel.pipeline.syncOperations.addHandler(remote.value)
                        }
                    }
                    do {
                        try await inbound.eventLoop.submit {
                            try inbound.pipeline.syncOperations.addHandler(local.value)
                        }.get()
                    } catch {
                        ssh.close(promise: nil)
                        throw error
                    }
                    connections.add(inbound)
                }
                return promise.futureResult
            }
            .bind(host: LoopbackForwardTarget.localHost, port: 0)
            .get()
        guard let port = listener.localAddress?.port else {
            try? await listener.close()
            throw SSHConnectionError.forwardFailed
        }
        return CitadelLoopbackForward(localPort: port, listener: listener, connections: connections)
    }

    func close() async {
        try? await listener.close()
        for connection in connections.takeAll() {
            try? await connection.close()
        }
    }
}

/// `SSHClient` is not `Sendable`. Citadel serializes its work on the client event loop.
private struct ClientBox: @unchecked Sendable {
    let client: SSHClient
}

/// The open local connections of one forward.
private final class ConnectionSet: @unchecked Sendable {
    private let lock = NSLock()
    private var channels: [ObjectIdentifier: any Channel] = [:]

    func add(_ channel: any Channel) {
        let id = ObjectIdentifier(channel)
        lock.withLock { channels[id] = channel }
        channel.closeFuture.whenComplete { [weak self] _ in
            self?.lock.withLock { _ = self?.channels.removeValue(forKey: id) }
        }
    }

    func takeAll() -> [any Channel] {
        lock.withLock {
            defer { channels.removeAll() }
            return Array(channels.values)
        }
    }
}

/// Copies reads of one channel to the other channel. Both channels must use the same event loop.
/// After the SwiftNIO `GlueHandler` example (Apache 2.0).
final class GlueHandler: ChannelDuplexHandler {
    typealias InboundIn = NIOAny
    typealias OutboundIn = NIOAny
    typealias OutboundOut = NIOAny

    private var partner: GlueHandler?
    private var context: ChannelHandlerContext?
    private var pendingRead = false

    private init() {}

    static func matchedPair() -> (GlueHandler, GlueHandler) {
        let first = GlueHandler()
        let second = GlueHandler()
        first.partner = second
        second.partner = first
        return (first, second)
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.context = context
        // The partner may have asked to read before this side was in its pipeline.
        if context.channel.isWritable { partner?.partnerBecameWritable() }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        self.context = nil
        partner = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        partner?.context?.write(data, promise: nil)
    }

    func channelReadComplete(context: ChannelHandlerContext) {
        partner?.context?.flush()
    }

    func channelInactive(context: ChannelHandlerContext) {
        partner?.context?.close(promise: nil)
        context.fireChannelInactive()
    }

    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if let event = event as? ChannelEvent, case .inputClosed = event {
            // Half-close: the other side gets EOF, then it can still answer.
            partner?.context?.close(mode: .output, promise: nil)
        }
        context.fireUserInboundEventTriggered(event)
    }

    func errorCaught(context: ChannelHandlerContext, error: any Error) {
        partner?.context?.close(promise: nil)
        context.close(promise: nil)
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable { partner?.partnerBecameWritable() }
        context.fireChannelWritabilityChanged()
    }

    func read(context: ChannelHandlerContext) {
        if partner?.context?.channel.isWritable ?? false {
            context.read()
        } else {
            pendingRead = true
        }
    }

    private func partnerBecameWritable() {
        guard pendingRead else { return }
        pendingRead = false
        context?.read()
    }
}
