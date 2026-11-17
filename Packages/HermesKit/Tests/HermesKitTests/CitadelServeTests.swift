import Citadel
import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSH
import Testing
@testable import HermesKit

/// The real Citadel `serve` exec and loopback forward against an in-process NIOSSH server on 127.0.0.1.
/// The server acts like the gate (`serve` reads stdin to EOF) and like Hermes behind `direct-tcpip`.
@Suite(.serialized) struct CitadelServeTests {
    /// What the fake server saw.
    final class ServerLog: @unchecked Sendable {
        private let lock = NSLock()
        private var _commands: [String] = []
        private var _stdin: [Data] = []
        private var _targets: [String] = []

        var commands: [String] { lock.withLock { _commands } }
        var stdin: [Data] { lock.withLock { _stdin } }
        /// `host:port` of each `direct-tcpip` request.
        var targets: [String] { lock.withLock { _targets } }

        func command(_ text: String) { lock.withLock { _commands.append(text) } }
        func input(_ data: Data) { lock.withLock { _stdin.append(data) } }
        func target(_ text: String) { lock.withLock { _targets.append(text) } }
    }

    enum GateReply: Sendable {
        case stdout(String)
        case failure(stderr: String, exit: Int)
    }

    /// One exec channel: records the command, reads stdin to EOF, then replies.
    final class ExecHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData

        let log: ServerLog
        let reply: GateReply
        private var input = Data()

        init(log: ServerLog, reply: GateReply) {
            self.log = log
            self.reply = reply
        }

        func handlerAdded(context: ChannelHandlerContext) {
            context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { _ in }
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let data = unwrapInboundIn(data)
            if case .byteBuffer(let buffer) = data.data { input.append(contentsOf: buffer.readableBytesView) }
        }

        func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
            switch event {
            case let exec as SSHChannelRequestEvent.ExecRequest:
                log.command(exec.command)
                if exec.wantReply { context.triggerUserOutboundEvent(ChannelSuccessEvent(), promise: nil) }
            case let event as ChannelEvent where event == .inputClosed:
                log.input(input)
                let (type, text, exit): (SSHChannelData.DataType, String, Int) = switch reply {
                case .stdout(let text): (.channel, text, 0)
                case .failure(let text, let exit): (.stdErr, text, exit)
                }
                let buffer = context.channel.allocator.buffer(string: text)
                context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: type, data: .byteBuffer(buffer))), promise: nil)
                context.triggerUserOutboundEvent(SSHChannelRequestEvent.ExitStatus(exitStatus: exit), promise: nil)
                context.close(promise: nil)
            default:
                context.fireUserInboundEventTriggered(event)
            }
        }
    }

    /// One `direct-tcpip` channel: answers one HTTP request like `GET /api/health`.
    final class HTTPResponder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = SSHChannelData
        typealias OutboundOut = SSHChannelData
        private var request = ""

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard case .byteBuffer(let buffer) = unwrapInboundIn(data).data else { return }
            request += String(buffer: buffer)
            guard request.contains("\r\n\r\n") else { return }
            let path = request.split(separator: " ").dropFirst().first.map(String.init) ?? "?"
            let body = #"{"ok":true,"path":"\#(path)"}"#
            let text = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            let out = context.channel.allocator.buffer(string: text)
            context.writeAndFlush(wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(out))), promise: nil)
            context.close(promise: nil)
        }
    }

    final class AcceptAll: NIOSSHServerUserAuthenticationDelegate, @unchecked Sendable {
        let supportedAuthenticationMethods: NIOSSHAvailableUserAuthenticationMethods = .publicKey
        func requestReceived(request: NIOSSHUserAuthenticationRequest,
                             responsePromise: EventLoopPromise<NIOSSHUserAuthenticationOutcome>) {
            responsePromise.succeed(.success)
        }
    }

    struct Server {
        let channel: any Channel
        let port: Int
        let hostKey: HostKey
        let log: ServerLog
    }

    private func startServer(reply: GateReply) async throws -> Server {
        let serverKey = NIOSSHPrivateKey(ed25519Key: Curve25519.Signing.PrivateKey())
        let hostKey = try #require(HostKey(openSSH: String(openSSHPublicKey: serverKey.publicKey)))
        let log = ServerLog()
        let auth = AcceptAll()
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { child in
                child.eventLoop.makeCompletedFuture {
                    let handler = NIOSSHHandler(
                        role: .server(.init(hostKeys: [serverKey], userAuthDelegate: auth)),
                        allocator: child.allocator,
                        inboundChildChannelInitializer: { sshChild, type in
                            sshChild.eventLoop.makeCompletedFuture {
                                switch type {
                                case .session:
                                    try sshChild.pipeline.syncOperations.addHandler(ExecHandler(log: log, reply: reply))
                                case .directTCPIP(let request):
                                    log.target("\(request.targetHost):\(request.targetPort)")
                                    try sshChild.pipeline.syncOperations.addHandler(HTTPResponder())
                                default:
                                    throw ChannelError.operationUnsupported
                                }
                            }
                        })
                    try child.pipeline.syncOperations.addHandler(handler)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try #require(channel.localAddress?.port)
        return Server(channel: channel, port: port, hostKey: hostKey, log: log)
    }

    private func connect(_ server: Server) async throws -> any SSHSession {
        let profile = ServerProfile(host: "127.0.0.1", port: server.port, hostKey: server.hostKey)
        let key = SoftwareKeyFactory.wrap(P256.Signing.PrivateKey())
        return try await CitadelSSHTransport(connectTimeoutSeconds: 5)
            .connect(to: SSHEndpoint(profile: profile), key: key) { _ in }
    }

    @Test func serveSendsTheTokenOnStdinThenEOF() async throws {
        let server = try await startServer(reply: .stdout("PORT 41234\n"))
        let session = try await connect(server)
        let token = SessionToken.mint()
        let reply = try await session.execute(.serve, stdin: token.stdinBytes)

        #expect(reply == "PORT 41234\n")
        #expect(server.log.commands == ["serve"])
        #expect(server.log.stdin == [Data(token.value.utf8)])
        #expect(!server.log.commands.joined().contains(token.value))
        await session.close()
        try await server.channel.close()
    }

    @Test func gateErrorKeepsOnlyTheCode() async throws {
        let server = try await startServer(reply: .failure(stderr: "ERROR hermes-not-found: no hermes in /home/x\n", exit: 1))
        let session = try await connect(server)
        await #expect(throws: SSHConnectionError.gateError("hermes-not-found")) {
            try await session.execute(.serve, stdin: SessionToken.mint().stdinBytes)
        }
        await session.close()
        try await server.channel.close()
    }

    @Test func forwardReachesTheServerLoopback() async throws {
        let server = try await startServer(reply: .stdout("PORT 41234\n"))
        let session = try await connect(server)
        let forward = try await session.openLoopbackForward(remotePort: 41234)

        let url = try #require(URL(string: "http://127.0.0.1:\(forward.localPort)/api/health"))
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let (data, response) = try await URLSession(configuration: config).data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == #"{"ok":true,"path":"/api/health"}"#)
        #expect(server.log.targets == ["127.0.0.1:41234"])

        // A second request opens a second channel to the same target.
        _ = try await URLSession(configuration: config).data(from: url)
        #expect(server.log.targets == ["127.0.0.1:41234", "127.0.0.1:41234"])

        await forward.close()
        await session.close()
        try await server.channel.close()
    }

    @Test func fullBootstrapOverTheRealForward() async throws {
        // The fake Hermes answers every path with ok:true, so the ownership proof fails: this checks the
        // chain up to the ownership call, through the real exec, forward and URLSession.
        let server = try await startServer(reply: .stdout("PORT 41234\n"))
        let session = try await connect(server)
        let config = URLSessionConfiguration.ephemeral
        let bootstrap = ServeBootstrap(loader: URLSessionHTTPLoader(session: URLSession(configuration: config)),
                                       configuration: .init(serveTimeout: .seconds(10), healthAttempts: 2,
                                                            healthRetryDelay: .milliseconds(10)))
        await #expect(throws: SSHConnectionError.sessionTokenRejected) {
            try await bootstrap.start(on: session, reuse: nil)
        }
        #expect(server.log.commands == ["serve"])
        #expect(server.log.targets == ["127.0.0.1:41234", "127.0.0.1:41234"])
        await session.close()
        try await server.channel.close()
    }
}
