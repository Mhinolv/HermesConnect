import AVFoundation
import HermesKit
import WebRTC

/// The WebRTC peer of a Live session (issue #98), with `stasel/WebRTC` (BSD-3-Clause, no telemetry).
///
/// - One mic track and the `oai-events` data channel. No video. No remote tracks other than the voice.
/// - The offer goes out exactly as WebRTC made it (with the trailing CRLF).
/// - Media goes from the phone to OpenAI. The SSH forward carries only the SDP.
/// - Nothing here logs SDP, data channel text or audio. The log gets states and error codes only.
/// - Issue #109: the audio session goes back through `RTCAudioSession`, the same API that activated it.
///   If it does not, `RTCAudioSession.isActive` stays `true`, and each later start cannot activate audio.
@MainActor
final class WebRTCLiveConnection: LiveModeConnection {
    var onEvent: (@MainActor (LiveModeLinkEvent) -> Void)?

    /// What `close()` left. Tests read it (issue #109).
    struct Teardown: Equatable {
        var peerState: RTCPeerConnectionState?
        var channelState: RTCDataChannelState?
        var micEnabled: Bool?
        var senders: Int
        var audioReleased: Bool
    }

    private(set) var teardown: Teardown?

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    private let proxy = WebRTCDelegateProxy()
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var micTrack: RTCAudioTrack?
    private var statsTimer: Timer?
    private var speaking = false
    private var quietPolls = 0
    private var gathered: CheckedContinuation<Void, Never>?
    private var closed = false
    /// `true` after this connection activated `RTCAudioSession`, until `close()` gives it back.
    private var holdsAudio = false
    private let log = HermesLog(category: "live-webrtc")

    init() {
        proxy.owner = self
    }

    func makeOffer() async throws -> String {
        // An End before the start task ran: activate nothing, so no activation stays open.
        guard !closed else { throw LiveModeError.step(.offer, code: nil) }
        do {
            try activateAudio()
        } catch {
            log.notice("live audio session not active: \((error as NSError).code)")
            throw LiveModeError.step(.audioSession, code: (error as NSError).code)
        }
        do {
            return try await offer()
        } catch let error as LiveModeError {
            throw error
        } catch {
            log.notice("live offer failed: \((error as NSError).code)")
            throw LiveModeError.step(.offer, code: (error as NSError).code)
        }
    }

    private func offer() async throws -> String {
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard !closed, let peer = Self.factory.peerConnection(with: configuration, constraints: constraints,
                                                              delegate: proxy) else {
            throw LiveModeError.step(.offer, code: nil)
        }
        self.peer = peer
        let source = Self.factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["googEchoCancellation": "true", "googAutoGainControl": "true",
                                  "googNoiseSuppression": "true"]))
        let track = Self.factory.audioTrack(with: source, trackId: "hermes-mic")
        micTrack = track
        peer.add(track, streamIds: ["hermes-live"])
        // The data channel goes in before the offer, so its m-line is in the SDP.
        guard let channel = peer.dataChannel(forLabel: LiveModeProtocol.dataChannel,
                                             configuration: RTCDataChannelConfiguration()) else {
            throw LiveModeError.step(.offer, code: nil)
        }
        channel.delegate = proxy
        self.channel = channel

        // Only the SDP text crosses the callback thread. It goes back in unchanged.
        let offerSDP: String = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                if let sdp = description?.sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? LiveModeError.step(.offer, code: nil)) }
            }
        }
        let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peer.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        await waitForGathering(peer)
        guard !closed, let sdp = peer.localDescription?.sdp, !sdp.isEmpty else {
            throw LiveModeError.step(.offer, code: nil)
        }
        return sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let peer, !closed else { throw LiveModeError.step(.answer, code: nil) }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                peer.setRemoteDescription(answer) { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                }
            }
        } catch {
            log.notice("live answer refused: \((error as NSError).code)")
            throw LiveModeError.step(.answer, code: (error as NSError).code)
        }
        startSpeakingProbe()
    }

    @discardableResult
    func send(_ text: String) -> Bool {
        guard let channel, channel.readyState == .open else { return false }
        return channel.sendData(RTCDataBuffer(data: Data(text.utf8), isBinary: false))
    }

    func setMuted(_ muted: Bool) {
        micTrack?.isEnabled = !muted
    }

    /// Stops the mic track, closes the data channel and the peer, then gives the audio session back.
    func close() {
        guard !closed else { return }
        closed = true
        onEvent = nil
        statsTimer?.invalidate()
        statsTimer = nil
        gathered?.resume()
        gathered = nil
        micTrack?.isEnabled = false
        channel?.delegate = nil
        channel?.close()
        if let peer {
            for sender in peer.senders { _ = peer.removeTrack(sender) }
            peer.close()
        }
        let released = releaseAudio()
        teardown = Teardown(peerState: peer?.connectionState, channelState: channel?.readyState,
                            micEnabled: micTrack?.isEnabled, senders: peer?.senders.filter { $0.track != nil }.count ?? 0,
                            audioReleased: released)
        log.info("live peer closed")
        channel = nil
        peer = nil
        micTrack = nil
        proxy.owner = nil
    }

    /// Voice chat: echo cancel, Bluetooth or a headset, else the speaker.
    private func activateAudio() throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        try session.setConfiguration(configuration, active: true)
        // `RTCAudioSession` counts each activation. One release in `close()` balances it.
        holdsAudio = true
    }

    /// Gives back the one activation of this connection. `RTCAudioSession` deactivates the system session
    /// on the last release, so a late close of an old session does not stop a newer one.
    private func releaseAudio() -> Bool {
        guard holdsAudio else { return false }
        holdsAudio = false
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        do {
            try session.setActive(false)
        } catch {
            // `RTCAudioSession` still counts the release when the system call fails.
            log.notice("live audio session release failed: \((error as NSError).code)")
        }
        return true
    }

    /// ICE gathering (host candidates). Trickle is fine after 10 s: the vendor answers with what it has.
    private func waitForGathering(_ peer: RTCPeerConnection) async {
        guard peer.iceGatheringState != .complete else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            gathered = continuation
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(10))
                self?.gathered?.resume()
                self?.gathered = nil
            }
        }
    }

    /// The voice speaks when the inbound audio level is up. 4 polls a second, no per-frame work.
    private func startSpeakingProbe() {
        statsTimer?.invalidate()
        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollLevel() }
        }
    }

    private func pollLevel() {
        guard let peer else { return }
        let proxy = proxy
        peer.statistics { report in
            var level = 0.0
            for stats in report.statistics.values where stats.type == "inbound-rtp" {
                if (stats.values["kind"] as? String) == "audio", let value = stats.values["audioLevel"] as? NSNumber {
                    level = max(level, value.doubleValue)
                }
            }
            proxy.deliver { owner in owner.levelChanged(level) }
        }
    }

    fileprivate func levelChanged(_ level: Double) {
        let loud = level > 0.02
        quietPolls = loud ? 0 : quietPolls + 1
        let now = loud || (speaking && quietPolls < 3)
        guard now != speaking else { return }
        speaking = now
        onEvent?(.speaking(now))
    }

    fileprivate func peerStateChanged(_ state: RTCPeerConnectionState) {
        log.info("live peer state: \(Self.name(state))")
        switch state {
        case .connected: onEvent?(.connected)
        case .disconnected: onEvent?(.disconnected)
        case .failed: onEvent?(.failed)
        default: break
        }
    }

    fileprivate func iceStateChanged(_ state: RTCIceConnectionState) {
        log.info("live ICE state: \(Self.name(state))")
    }

    fileprivate func gatheringChanged(_ state: RTCIceGatheringState) {
        guard state == .complete else { return }
        log.info("live ICE gathering complete")
        gathered?.resume()
        gathered = nil
    }

    /// The data channel has no close reason in WebRTC. The log says the state and that the app did not close it.
    fileprivate func channelStateChanged(_ state: RTCDataChannelState) {
        log.info("live data channel state: \(Self.name(state))")
        guard state == .closed, !closed else { return }
        log.notice("live data channel closed by the remote side, peer \(peer.map { Self.name($0.connectionState) } ?? "none")")
        onEvent?(.channelClosed)
    }

    private static func name(_ state: RTCPeerConnectionState) -> String {
        switch state {
        case .new: "new"
        case .connecting: "connecting"
        case .connected: "connected"
        case .disconnected: "disconnected"
        case .failed: "failed"
        case .closed: "closed"
        @unknown default: "unknown"
        }
    }

    private static func name(_ state: RTCIceConnectionState) -> String {
        switch state {
        case .new: "new"
        case .checking: "checking"
        case .connected: "connected"
        case .completed: "completed"
        case .failed: "failed"
        case .disconnected: "disconnected"
        case .closed: "closed"
        case .count: "count"
        @unknown default: "unknown"
        }
    }

    private static func name(_ state: RTCDataChannelState) -> String {
        switch state {
        case .connecting: "connecting"
        case .open: "open"
        case .closing: "closing"
        case .closed: "closed"
        @unknown default: "unknown"
        }
    }

    fileprivate func received(_ text: String) {
        onEvent?(.message(text))
    }
}

/// WebRTC calls its delegates on its own thread. This proxy hands each call to the main queue in order.
private final class WebRTCDelegateProxy: NSObject, RTCPeerConnectionDelegate, RTCDataChannelDelegate,
    @unchecked Sendable {
    /// Read and written on the main queue only.
    nonisolated(unsafe) weak var owner: WebRTCLiveConnection?

    func deliver(_ body: @escaping @MainActor (WebRTCLiveConnection) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let owner = self?.owner else { return }
                body(owner)
            }
        }
    }

    func peerConnection(_: RTCPeerConnection, didChange newState: RTCPeerConnectionState) {
        deliver { $0.peerStateChanged(newState) }
    }

    func peerConnection(_: RTCPeerConnection, didChange newState: RTCIceGatheringState) {
        deliver { $0.gatheringChanged(newState) }
    }

    func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {
        let state = dataChannel.readyState
        deliver { $0.channelStateChanged(state) }
    }

    func dataChannel(_: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        guard !buffer.isBinary else { return }
        let text = String(decoding: buffer.data, as: UTF8.self)
        deliver { $0.received(text) }
    }

    func peerConnection(_: RTCPeerConnection, didChange _: RTCSignalingState) {}
    func peerConnection(_: RTCPeerConnection, didAdd _: RTCMediaStream) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_: RTCPeerConnection) {}
    func peerConnection(_: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        deliver { $0.iceStateChanged(newState) }
    }
    func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}
