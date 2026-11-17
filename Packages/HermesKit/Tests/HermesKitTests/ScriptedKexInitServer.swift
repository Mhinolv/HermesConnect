import Foundation
import NIOCore
import NIOPosix

/// A scripted SSH server for the algorithm refusal tests (issue #59). It runs on 127.0.0.1. No real server is used.
///
/// It acts like OpenSSH: when the client connects, it sends its version line and its `SSH_MSG_KEXINIT` in one
/// flushed write. Then it reads the client packets until it gets the client `SSH_MSG_KEXINIT`, and closes.
/// It never runs a key exchange.
///
/// Why not the in-process Citadel server: the NIOSSH server writes its KEXINIT without a flush. If the client
/// version and KEXINIT arrive in one read, the server fails the negotiation in the same read. Citadel then
/// closes the channel and drops the unflushed KEXINIT. The client sees only a disconnect (`.unreachable`).
final class ScriptedKexInitServer: Sendable {
    /// What the client sent before the server closed.
    struct ClientHello: Sendable, Equatable {
        /// The message numbers of the client packets, in order. `20` is `SSH_MSG_KEXINIT`.
        var messageIDs: [UInt8]
        /// The key exchange names in the client `SSH_MSG_KEXINIT`.
        var keyExchanges: [String]
        /// The client-to-server cipher names in the client `SSH_MSG_KEXINIT`.
        var ciphers: [String]
    }

    struct NoClientKexInit: Error {}

    static let kexInit: UInt8 = 20

    let port: Int
    private let channel: any Channel
    private let hello: EventLoopPromise<ClientHello>

    private init(channel: any Channel, port: Int, hello: EventLoopPromise<ClientHello>) {
        self.channel = channel
        self.port = port
        self.hello = hello
    }

    /// Starts a server whose KEXINIT offers only these algorithms. The host key is `ssh-ed25519`.
    static func start(keyExchanges: [String], ciphers: [String], macs: [String] = ["hmac-sha2-256"]) async throws
        -> ScriptedKexInitServer {
        let group = MultiThreadedEventLoopGroup.singleton
        let hello = group.any().makePromise(of: ClientHello.self)
        let greeting = Self.greeting(keyExchanges: keyExchanges, ciphers: ciphers, macs: macs)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    try child.pipeline.syncOperations.addHandler(Handler(greeting: greeting, hello: hello))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else { throw NoClientKexInit() }
        return ScriptedKexInitServer(channel: channel, port: port, hello: hello)
    }

    /// Waits for the client `SSH_MSG_KEXINIT` of the first connection. The server reads it after the client
    /// failed, so a test must wait for it. Throws if the client closed first, or after `seconds`.
    func clientHello(timeoutSeconds seconds: Int64 = 5) async throws -> ClientHello {
        let hello = self.hello
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(seconds)) { hello.fail(NoClientKexInit()) }
        defer { timeout.cancel() }
        return try await hello.futureResult.get()
    }

    func close() async throws {
        hello.fail(NoClientKexInit())
        try await channel.close()
    }

    // MARK: Wire format (RFC 4253)

    /// The version line and one unencrypted binary packet with the server `SSH_MSG_KEXINIT`.
    private static func greeting(keyExchanges: [String], ciphers: [String], macs: [String]) -> [UInt8] {
        var payload: [UInt8] = [kexInit]
        payload += (0..<16).map { _ in UInt8.random(in: 0...255) }
        for list in [keyExchanges, ["ssh-ed25519"], ciphers, ciphers, macs, macs, ["none"], ["none"], [], []] {
            let names = Array(list.joined(separator: ",").utf8)
            payload += uint32(names.count) + names
        }
        payload += [0] + uint32(0)  // first_kex_packet_follows = false, reserved
        // The packet length field, the padding length byte, the payload and the padding are a multiple of 8.
        var padding = 8 - (5 + payload.count) % 8
        if padding < 4 { padding += 8 }
        let packet = uint32(1 + payload.count + padding) + [UInt8(padding)] + payload + [UInt8](repeating: 0, count: padding)
        return Array("SSH-2.0-OpenSSH_9.9 scripted\r\n".utf8) + packet
    }

    private static func uint32(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)]
    }

    /// Reads one SSH name-list at `offset` and moves `offset` past it.
    private static func nameList(_ bytes: [UInt8], _ offset: inout Int) -> [String]? {
        guard offset + 4 <= bytes.count else { return nil }
        let length = bytes[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
        offset += 4
        guard offset + length <= bytes.count else { return nil }
        let text = String(decoding: bytes[offset..<offset + length], as: UTF8.self)
        offset += length
        return text.isEmpty ? [] : text.split(separator: ",").map(String.init)
    }

    // MARK: Connection handler

    private final class Handler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let greeting: [UInt8]
        private let hello: EventLoopPromise<ClientHello>
        // Event loop only.
        private var buffer: [UInt8] = []
        private var versionDone = false
        private var messageIDs: [UInt8] = []

        init(greeting: [UInt8], hello: EventLoopPromise<ClientHello>) {
            self.greeting = greeting
            self.hello = hello
        }

        func channelActive(context: ChannelHandlerContext) {
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(bytes: greeting)), promise: nil)
            context.fireChannelActive()
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var bytes = unwrapInboundIn(data)
            buffer += bytes.readBytes(length: bytes.readableBytes) ?? []
            if !versionDone {
                guard let end = buffer.indices.dropLast().first(where: { buffer[$0] == 13 && buffer[$0 + 1] == 10 })
                else { return }
                buffer.removeFirst(end + 2)
                versionDone = true
            }
            var kexInit: ClientHello?
            while buffer.count >= 5 {
                let length = buffer[0..<4].reduce(0) { $0 << 8 | Int($1) }
                guard buffer.count >= 4 + length, length >= 2 else { break }
                let padding = Int(buffer[4])
                let payload = Array(buffer[5..<(4 + length - padding)])
                buffer.removeFirst(4 + length)
                guard let id = payload.first else { continue }
                messageIDs.append(id)
                if id == ScriptedKexInitServer.kexInit, kexInit == nil {
                    var offset = 17  // message number and cookie
                    let kexes = ScriptedKexInitServer.nameList(payload, &offset) ?? []
                    _ = ScriptedKexInitServer.nameList(payload, &offset)  // host key algorithms
                    let ciphers = ScriptedKexInitServer.nameList(payload, &offset) ?? []
                    kexInit = ClientHello(messageIDs: [], keyExchanges: kexes, ciphers: ciphers)
                }
            }
            // Close after the client KEXINIT, with every packet of this read recorded.
            if var kexInit {
                kexInit.messageIDs = messageIDs
                hello.succeed(kexInit)
                context.close(promise: nil)
            }
        }

        func channelInactive(context: ChannelHandlerContext) {
            hello.fail(NoClientKexInit())
            context.fireChannelInactive()
        }

        func errorCaught(context: ChannelHandlerContext, error: any Error) {
            context.close(promise: nil)
        }
    }
}
