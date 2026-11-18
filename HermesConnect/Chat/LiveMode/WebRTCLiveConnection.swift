import AVFoundation
import HermesKit
import WebRTC

/// The WebRTC peer of a Live session (issue #98), with `stasel/WebRTC` (BSD-3-Clause, no telemetry).
///
/// - One mic track and the `oai-events` data channel. No video. No remote tracks other than the voice.
/// - The offer goes out exactly as WebRTC made it (with the trailing CRLF).
/// - Media goes from the phone to OpenAI. The SSH forward carries only the SDP.
/// - Nothing here logs SDP, data channel text or audio.
@MainActor
final class WebRTCLiveConnection: LiveModeConnection {
    var onEvent: (@MainActor (LiveModeLinkEvent) -> Void)?

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

    init() {
        proxy.owner = self
    }

    func makeOffer() async throws -> String {
        try Self.configureAudio()
        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        configuration.bundlePolicy = .maxBundle
        configuration.rtcpMuxPolicy = .require
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = Self.factory.peerConnection(with: configuration, constraints: constraints, delegate: proxy) else {
            throw LiveModeError.connectionFailed
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
            throw LiveModeError.connectionFailed
        }
        channel.delegate = proxy
        self.channel = channel

        // Only the SDP text crosses the callback thread. It goes back in unchanged.
        let offerSDP: String = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: constraints) { description, error in
                if let sdp = description?.sdp { continuation.resume(returning: sdp) }
                else { continuation.resume(throwing: error ?? LiveModeError.connectionFailed) }
            }
        }
        let offer = RTCSessionDescription(type: .offer, sdp: offerSDP)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peer.setLocalDescription(offer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
        }
        await waitForGathering(peer)
        guard !closed, let sdp = peer.localDescription?.sdp, !sdp.isEmpty else { throw LiveModeError.connectionFailed }
        return sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        guard let peer, !closed else { throw LiveModeError.connectionFailed }
        let answer = RTCSessionDescription(type: .answer, sdp: sdp)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            peer.setRemoteDescription(answer) { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            }
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
        peer?.close()
        channel = nil
        peer = nil
        micTrack = nil
        proxy.owner = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Voice chat: echo cancel, Bluetooth or a headset, else the speaker.
    private static func configureAudio() throws {
        let session = RTCAudioSession.sharedInstance()
        session.lockForConfiguration()
        defer { session.unlockForConfiguration() }
        let configuration = RTCAudioSessionConfiguration.webRTC()
        configuration.category = AVAudioSession.Category.playAndRecord.rawValue
        configuration.mode = AVAudioSession.Mode.voiceChat.rawValue
        configuration.categoryOptions = [.allowBluetoothHFP, .defaultToSpeaker]
        try session.setConfiguration(configuration, active: true)
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
        switch state {
        case .connected: onEvent?(.connected)
        case .disconnected: onEvent?(.disconnected)
        case .failed: onEvent?(.failed)
        default: break
        }
    }

    fileprivate func gatheringChanged(_ state: RTCIceGatheringState) {
        guard state == .complete else { return }
        gathered?.resume()
        gathered = nil
    }

    fileprivate func channelStateChanged(_ state: RTCDataChannelState) {
        if state == .closed, !closed { onEvent?(.failed) }
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
    func peerConnection(_: RTCPeerConnection, didChange _: RTCIceConnectionState) {}
    func peerConnection(_: RTCPeerConnection, didGenerate _: RTCIceCandidate) {}
    func peerConnection(_: RTCPeerConnection, didRemove _: [RTCIceCandidate]) {}
    func peerConnection(_: RTCPeerConnection, didOpen _: RTCDataChannel) {}
}
