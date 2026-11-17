import CryptoKit
import Foundation
import Testing
@testable import HermesKit

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func fix(_ lat: Double = 37.3349, _ lon: Double = -122.009, at time: Date = t0, accuracy: Double = 12.5,
                 speed: Double? = nil, course: Double? = nil) -> LocationFix {
    LocationFix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy, timestamp: time,
                speed: speed, course: course)!
}

private func json(_ data: Data) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// A clock that tests move by hand.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
}

@Suite struct LocationFixTests {
    @Test func validFixKeepsTheValues() {
        let value = fix(speed: 3.5, course: 90)
        #expect(value.latitude == 37.3349)
        #expect(value.speed == 3.5)
        #expect(value.course == 90)
    }

    @Test(arguments: [(91.0, 0.0, 5.0), (-90.5, 0.0, 5.0), (0.0, 180.1, 5.0), (0.0, -181.0, 5.0),
                      (Double.nan, 0.0, 5.0), (0.0, .infinity, 5.0), (0.0, 0.0, -1.0), (0.0, 0.0, .nan)])
    func invalidValuesGiveNoFix(lat: Double, lon: Double, accuracy: Double) {
        #expect(LocationFix(latitude: lat, longitude: lon, horizontalAccuracy: accuracy, timestamp: t0) == nil)
    }

    @Test func edgeValuesAreValid() {
        #expect(LocationFix(latitude: 90, longitude: 180, horizontalAccuracy: 0, timestamp: t0) != nil)
        #expect(LocationFix(latitude: -90, longitude: -180, horizontalAccuracy: 0, timestamp: t0) != nil)
    }

    @Test func unknownSpeedAndCourseBecomeNil() {
        let value = fix(speed: -1, course: -1)
        #expect(value.speed == nil)
        #expect(value.course == nil)
        #expect(fix(course: 360).course == 360)
        #expect(fix(course: 360.5).course == nil)
        #expect(fix(speed: .nan).speed == nil)
    }

    @Test func descriptionHidesTheCoordinates() {
        let value = fix()
        #expect("\(value)" == "LocationFix(<redacted>)")
        #expect(String(reflecting: value) == "LocationFix(<redacted>)")
        #expect(!"\(value)".contains("37"))
    }

    @Test func visitUsesDepartureThenArrivalThenNow() throws {
        let now = t0.addingTimeInterval(3600)
        let departed = try #require(LocationFix(visitLatitude: 1, longitude: 2, horizontalAccuracy: 30,
                                                arrival: t0, departure: t0.addingTimeInterval(600), now: now))
        #expect(departed.timestamp == t0.addingTimeInterval(600))
        let arrived = try #require(LocationFix(visitLatitude: 1, longitude: 2, horizontalAccuracy: 30,
                                               arrival: t0, departure: .distantFuture, now: now))
        #expect(arrived.timestamp == t0)
        let unknown = try #require(LocationFix(visitLatitude: 1, longitude: 2, horizontalAccuracy: 30,
                                               arrival: .distantPast, departure: .distantFuture, now: now))
        #expect(unknown.timestamp == now)
        // A time in the future is never used: the gate refuses fixes from the future.
        let future = try #require(LocationFix(visitLatitude: 1, longitude: 2, horizontalAccuracy: 30,
                                              arrival: now.addingTimeInterval(60), departure: .distantFuture, now: now))
        #expect(future.timestamp == now)
    }

    @Test func distanceIsInMeters() {
        // 0.01 degree of latitude is about 1112 m.
        let distance = fix(0, 0).distance(to: fix(0.01, 0))
        #expect(abs(distance - 1112) < 2)
        #expect(fix().distance(to: fix()) == 0)
    }
}

@Suite struct LocationPayloadTests {
    @Test func preciseHasTheGateFields() throws {
        let body = try json(LocationPayload.encode(fix(speed: 1.5, course: 270), precision: .precise))
        #expect(Set(body.keys) == ["lat", "lon", "accuracy_m", "timestamp", "speed", "course"])
        #expect(body["lat"] as? Double == 37.3349)
        #expect(body["lon"] as? Double == -122.009)
        #expect(body["accuracy_m"] as? Double == 12.5)
        #expect(body["timestamp"] as? String == "2027-01-15T08:00:00.000Z")
        #expect(body["speed"] as? Double == 1.5)
        #expect(body["course"] as? Double == 270)
    }

    @Test func unknownSpeedAndCourseAreLeftOut() throws {
        let body = try json(LocationPayload.encode(fix(), precision: .precise))
        #expect(Set(body.keys) == ["lat", "lon", "accuracy_m", "timestamp"])
    }

    @Test func approximateRoundsToAboutOneKilometer() throws {
        let body = try json(LocationPayload.encode(fix(37.33494, -122.00897, speed: 2, course: 10), precision: .approximate))
        let lat = try #require(body["lat"] as? Double)
        let lon = try #require(body["lon"] as? Double)
        #expect(abs(lat - 37.33) < 1e-9)
        #expect(abs(lon - -122.01) < 1e-9)
        #expect(body["accuracy_m"] as? Double == 1000)
        #expect(body["speed"] == nil)
        #expect(body["course"] == nil)
        let coarse = try json(LocationPayload.encode(fix(accuracy: 3000), precision: .approximate))
        #expect(coarse["accuracy_m"] as? Double == 3000)
    }

    @Test func approximateStaysInRange() throws {
        let body = try json(LocationPayload.encode(fix(89.999, 179.999), precision: .approximate))
        #expect((body["lat"] as? Double ?? 99) <= 90)
        #expect((body["lon"] as? Double ?? 999) <= 180)
    }

    @Test func fractionalSecondsAreKept() {
        #expect(LocationPayload.timestampText(t0.addingTimeInterval(0.25)) == "2027-01-15T08:00:00.250Z")
    }

    @Test func payloadIsSmallerThanTheGateLimit() {
        let data = LocationPayload.encode(fix(-89.123456789, -179.123456789, accuracy: 123456.789,
                                              speed: 1234.5678, course: 359.999), precision: .precise)
        #expect(data.count < LocationPayload.maxBytes)
    }

    /// The real gate (`server/gate/hermesconnect-gate`) accepts the payload and stores the same values.
    @Test(arguments: [LocationPrecision.precise, .approximate])
    func realGateAcceptsThePayload(precision: LocationPrecision) throws {
        let gate = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../../../server/gate/hermesconnect-gate")
            .standardizedFileURL
        let python = URL(filePath: "/usr/bin/python3")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: gate.path) else { return }
        let home = FileManager.default.temporaryDirectory.appending(path: "gate-home-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }

        let value = fix(speed: 1.25, course: 45.5).with(timestamp: Date().addingTimeInterval(-30))
        let process = Process()
        process.executableURL = python
        process.arguments = [gate.path]
        process.environment = ["HOME": home.path, "SSH_ORIGINAL_COMMAND": "location", "PATH": "/usr/bin:/bin"]
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        input.fileHandleForWriting.write(LocationPayload.encode(value, precision: precision))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "\(stderr)")
        #expect(stdout == "OK\n")

        let stored = try json(Data(contentsOf: home.appending(path: ".hermes/hermesconnect/location.json")))
        let sent = try json(LocationPayload.encode(value, precision: precision))
        #expect(stored["lat"] as? Double == sent["lat"] as? Double)
        #expect(stored["lon"] as? Double == sent["lon"] as? Double)
        #expect(stored["accuracy_m"] as? Double == sent["accuracy_m"] as? Double)
        #expect(stored["timestamp"] as? String == sent["timestamp"] as? String)
        #expect((stored["speed"] as? Double) == (sent["speed"] as? Double))
    }
}

private extension LocationFix {
    func with(timestamp: Date) -> LocationFix {
        var copy = self
        copy.timestamp = timestamp
        return copy
    }
}

@Suite struct LocationRateLimitTests {
    let limit = LocationRateLimit()

    @Test func firstFixIsAllowed() {
        #expect(limit.allows(fix(), lastSent: nil, lastSentAt: nil, now: t0))
    }

    @Test func secondFixWithinTwoMinutesWaits() {
        #expect(!limit.allows(fix(), lastSent: fix(), lastSentAt: t0, now: t0.addingTimeInterval(119)))
        #expect(limit.allows(fix(), lastSent: fix(), lastSentAt: t0, now: t0.addingTimeInterval(120)))
    }

    @Test func aMoveOverFiveHundredMetersGoesAtOnce() {
        // 0.005 degree of latitude is about 556 m. 0.004 degree is about 445 m.
        #expect(limit.allows(fix(37.3399, -122.009), lastSent: fix(), lastSentAt: t0, now: t0.addingTimeInterval(5)))
        #expect(!limit.allows(fix(37.3389, -122.009), lastSent: fix(), lastSentAt: t0, now: t0.addingTimeInterval(5)))
    }

    @Test func aClockThatWentBackDoesNotBlock() {
        #expect(limit.allows(fix(), lastSent: fix(), lastSentAt: t0, now: t0.addingTimeInterval(-60)))
    }
}

@Suite struct LocationSharingTests {
    private func make(uploader: ScriptedLocationUploader = ScriptedLocationUploader(),
                      store: InMemoryLocationStateStore = InMemoryLocationStateStore(),
                      clock: TestClock = TestClock(t0)) -> LocationSharing {
        LocationSharing(store: store, uploader: uploader, now: { clock.now })
    }

    @Test func aFixIsSentAndRecorded() async throws {
        let uploader = ScriptedLocationUploader()
        let store = InMemoryLocationStateStore()
        let sharing = make(uploader: uploader, store: store)
        #expect(await sharing.submit(fix(), precision: .precise) == .sent)
        #expect(uploader.payloads.count == 1)
        let state = store.load()
        #expect(state.pending == nil)
        #expect(state.lastSent == fix())
        #expect(state.lastSentAt == t0)
        #expect(await sharing.status == LocationShareStatus(lastSentAt: t0))
    }

    @Test func theSelectedPrecisionGoesToTheGate() async throws {
        let uploader = ScriptedLocationUploader()
        let sharing = make(uploader: uploader)
        _ = await sharing.submit(fix(37.33494, -122.00897), precision: .approximate)
        let body = try json(try #require(uploader.payloads.first))
        #expect(body["accuracy_m"] as? Double == 1000)
    }

    @Test func aSecondFixWithinTwoMinutesWaitsAsTheLatestFix() async throws {
        let uploader = ScriptedLocationUploader()
        let store = InMemoryLocationStateStore()
        let clock = TestClock(t0)
        let sharing = make(uploader: uploader, store: store, clock: clock)
        _ = await sharing.submit(fix(), precision: .precise)
        clock.advance(30)
        #expect(await sharing.submit(fix(37.3350, -122.009, at: t0.addingTimeInterval(30)), precision: .precise) == .deferred)
        clock.advance(30)
        let latest = fix(37.3351, -122.009, at: t0.addingTimeInterval(60))
        #expect(await sharing.submit(latest, precision: .precise) == .deferred)
        #expect(uploader.payloads.count == 1)
        #expect(store.load().pending == latest)
        // The rate limit holds a flush too. After two minutes the latest fix goes, and only that one.
        #expect(await sharing.flush(precision: .precise) == .deferred)
        clock.advance(61)
        #expect(await sharing.flush(precision: .precise) == .sent)
        #expect(uploader.payloads.count == 2)
        #expect(store.load().lastSent == latest)
        #expect(store.load().pending == nil)
    }

    @Test func aLongMoveSkipsTheRateLimit() async {
        let uploader = ScriptedLocationUploader()
        let clock = TestClock(t0)
        let sharing = make(uploader: uploader, clock: clock)
        _ = await sharing.submit(fix(), precision: .precise)
        clock.advance(10)
        #expect(await sharing.submit(fix(37.35, -122.009, at: t0.addingTimeInterval(10)), precision: .precise) == .sent)
        #expect(uploader.payloads.count == 2)
    }

    @Test func forceSkipsTheRateLimit() async {
        let uploader = ScriptedLocationUploader()
        let clock = TestClock(t0)
        let sharing = make(uploader: uploader, clock: clock)
        _ = await sharing.submit(fix(), precision: .precise)
        clock.advance(5)
        #expect(await sharing.submit(fix(at: t0.addingTimeInterval(5)), precision: .precise, force: true) == .sent)
        #expect(uploader.payloads.count == 2)
    }

    @Test func offlineKeepsOnlyTheLatestFixAndSendsItOnFlush() async throws {
        let uploader = ScriptedLocationUploader(failure: .connection(.unreachable))
        let store = InMemoryLocationStateStore()
        let clock = TestClock(t0)
        let sharing = make(uploader: uploader, store: store, clock: clock)
        #expect(await sharing.submit(fix(), precision: .precise) == .failed(.connection(.unreachable)))
        clock.advance(600)
        let newer = fix(37.40, -122.0, at: t0.addingTimeInterval(600))
        #expect(await sharing.submit(newer, precision: .precise) == .failed(.connection(.unreachable)))
        #expect(store.load().pending == newer)
        #expect(await sharing.status.waitingForConnection)
        #expect(await sharing.status.lastError == "The server is not reachable.")

        uploader.failure = nil
        #expect(await sharing.flush(precision: .precise) == .sent)
        #expect(uploader.payloads.count == 3)
        let last = try json(try #require(uploader.payloads.last))
        #expect(last["lat"] as? Double == 37.40)
        #expect(store.load().pending == nil)
        #expect(await sharing.status == LocationShareStatus(lastSentAt: t0.addingTimeInterval(600)))
    }

    @Test func anOlderFixDoesNotReplaceANewerPendingFix() async {
        let uploader = ScriptedLocationUploader(failure: .connection(.unreachable))
        let store = InMemoryLocationStateStore()
        let sharing = make(uploader: uploader, store: store)
        let newer = fix(at: t0.addingTimeInterval(100))
        _ = await sharing.submit(newer, precision: .precise)
        _ = await sharing.submit(fix(1, 1, at: t0), precision: .precise)
        #expect(store.load().pending == newer)
    }

    @Test func aRefusedFixIsDropped() async {
        let uploader = ScriptedLocationUploader(failure: .connection(.gateError("bad-location")))
        let store = InMemoryLocationStateStore()
        let sharing = make(uploader: uploader, store: store)
        _ = await sharing.submit(fix(), precision: .precise)
        #expect(store.load().pending == nil)
        #expect(store.load().lastError == "The server gate returned an error: bad-location.")
        #expect(await sharing.flush(precision: .precise) == .nothing)
    }

    @Test func discardDropsThePendingFix() async {
        let uploader = ScriptedLocationUploader(failure: .timedOut)
        let store = InMemoryLocationStateStore()
        let sharing = make(uploader: uploader, store: store)
        _ = await sharing.submit(fix(), precision: .precise)
        await sharing.discardPending()
        #expect(store.load().pending == nil)
        #expect(await sharing.status == LocationShareStatus())
    }

    @Test func stateSurvivesARelaunch() async {
        let store = InMemoryLocationStateStore()
        let clock = TestClock(t0)
        let first = make(uploader: ScriptedLocationUploader(failure: .timedOut), store: store, clock: clock)
        _ = await first.submit(fix(), precision: .precise)
        let uploader = ScriptedLocationUploader()
        let second = make(uploader: uploader, store: store, clock: clock)
        #expect(await second.flush(precision: .precise) == .sent)
        #expect(uploader.payloads.count == 1)
    }

    @Test func aFixDuringAnUploadIsSentAfterIt() async throws {
        let uploader = ScriptedLocationUploader()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        uploader.duringUpload = {
            started.continuation.yield()
            for await _ in release.stream { break }
        }
        let clock = TestClock(t0)
        let sharing = make(uploader: uploader, clock: clock)
        let first = Task { await sharing.submit(fix(), precision: .precise) }
        for await _ in started.stream { break }
        uploader.duringUpload = nil
        // 2 km away: the rate limit lets it go right after the first upload.
        let far = fix(37.355, -122.009, at: t0.addingTimeInterval(1))
        #expect(await sharing.submit(far, precision: .precise) == .deferred)
        release.continuation.yield()
        #expect(await first.value == .sent)
        #expect(uploader.payloads.count == 2)
        let last = try json(try #require(uploader.payloads.last))
        #expect(last["lat"] as? Double == 37.355)
    }

    @Test func oldStateFilesDecodeWithDefaults() throws {
        let state = try JSONDecoder().decode(LocationShareState.self, from: Data(#"{"lastError":"x","extra":1}"#.utf8))
        #expect(state.version == 1)
        #expect(state.lastError == "x")
        #expect(state.pending == nil)
        let broken = try JSONDecoder().decode(LocationShareState.self, from: Data(#"{"pending":{"latitude":"no"}}"#.utf8))
        #expect(broken.pending == nil)
    }

    @Test func fileStoreRoundTrips() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "loc-\(UUID().uuidString)/state.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = FileLocationStateStore(fileURL: url)
        #expect(store.load() == LocationShareState())
        let state = LocationShareState(pending: fix(), lastSent: fix(1, 2), lastSentAt: t0, lastError: "e")
        store.save(state)
        #expect(store.load() == state)
        try Data("not json".utf8).write(to: url)
        #expect(store.load() == LocationShareState())
    }
}

@Suite struct GateLocationUploaderTests {
    private let key = SoftwareKeyFactory.wrap(P256.Signing.PrivateKey())

    private func uploader(_ transport: ScriptedSSHTransport, pin: HostKey? = .sample,
                          timeout: Duration = .seconds(25)) -> GateLocationUploader {
        let credentials = LocationCredentials(profile: ServerProfile(host: "vps.example.com", hostKey: pin), key: key)
        return GateLocationUploader(connector: HostConnector(transport: transport), timeout: timeout) { credentials }
    }

    @Test func uploadRunsPingThenLocationWithThePayloadOnStdin() async throws {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let payload = LocationPayload.encode(fix(), precision: .precise)
        try await uploader(transport).upload(payload)
        #expect(transport.record.commands == [.ping, .location])
        #expect(transport.record.stdins == [nil, payload])
        #expect(transport.record.closedSessions == 1)
        #expect(transport.record.forwardPorts.isEmpty)
        #expect(transport.record.spawns == 0)
        #expect(GateCommand.location.rawValue == "location")
    }

    @Test func noPinnedKeyNeverAuthenticates() async {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        await #expect(throws: LocationUploadError.connection(.hostKeyUnknown(.sample))) {
            try await uploader(transport, pin: nil).upload(Data("{}".utf8))
        }
        #expect(transport.record.authentications == 0)
    }

    @Test func aChangedHostKeyNeverAuthenticates() async {
        let transport = ScriptedSSHTransport(hostKey: .otherSample)
        await #expect(throws: LocationUploadError.connection(.hostKeyChanged(saved: .sample, received: .otherSample))) {
            try await uploader(transport).upload(Data("{}".utf8))
        }
        #expect(transport.record.authentications == 0)
    }

    @Test func offlineGivesUnreachable() async {
        let transport = ScriptedSSHTransport(hostKey: .sample, connectFailure: .unreachable)
        await #expect(throws: LocationUploadError.connection(.unreachable)) {
            try await uploader(transport).upload(Data("{}".utf8))
        }
    }

    @Test func gateRefusalGivesTheCodeAndClosesTheSession() async {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        transport.locationFailure = .gateError("bad-location")
        await #expect(throws: LocationUploadError.connection(.gateError("bad-location"))) {
            try await uploader(transport).upload(Data("{}".utf8))
        }
        #expect(transport.record.closedSessions == 1)
        #expect(!LocationUploadError.connection(.gateError("bad-location")).isRetryable)
        #expect(LocationUploadError.connection(.unreachable).isRetryable)
    }

    @Test func aReplyOtherThanOKIsAnError() async {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        transport.locationReply = "PORT 1\n"
        await #expect(throws: LocationUploadError.connection(.unexpectedReply)) {
            try await uploader(transport).upload(Data("{}".utf8))
        }
    }

    @Test func noCredentialsGivesNotSetUp() async {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let uploader = GateLocationUploader(connector: HostConnector(transport: transport)) { nil }
        await #expect(throws: LocationUploadError.notSetUp) { try await uploader.upload(Data("{}".utf8)) }
        #expect(transport.record.connectAttempts == 0)
    }

    @Test func aSlowServerTimesOut() async {
        let uploader = GateLocationUploader(connector: HostConnector(transport: HangingTransport()),
                                            timeout: .milliseconds(100)) {
            LocationCredentials(profile: ServerProfile(host: "vps.example.com", hostKey: .sample), key: key)
        }
        await #expect(throws: LocationUploadError.timedOut) { try await uploader.upload(Data("{}".utf8)) }
    }

    @Test func cancelClosesTheSessionAndGivesTimedOut() async throws {
        let transport = SlowLocationTransport()
        let uploader = GateLocationUploader(connector: HostConnector(transport: transport)) {
            LocationCredentials(profile: ServerProfile(host: "vps.example.com", hostKey: .sample), key: key)
        }
        let upload = Task { () -> LocationUploadError? in
            do { try await uploader.upload(Data("{}".utf8)); return nil } catch { return error as? LocationUploadError }
        }
        while !transport.locationStarted { try await Task.sleep(for: .milliseconds(10)) }
        upload.cancel()
        #expect(await upload.value == .timedOut)
        #expect(transport.closedSessions == 1)
    }

    @Test func cancelBeforeTheCommandSendsNothing() async {
        let transport = ScriptedSSHTransport(hostKey: .sample)
        let upload = Task { () -> LocationUploadError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { try await self.uploader(transport).upload(Data("{}".utf8)); return nil } catch { return error as? LocationUploadError }
        }
        #expect(await upload.value == .timedOut)
        #expect(!transport.record.commands.contains(.location))
    }

    @Test func defaultTimeoutFitsABackgroundTask() {
        #expect(GateLocationUploader.defaultTimeout == .seconds(25))
    }
}

/// A transport that connects at once, answers `ping`, and holds `location` until the task is cancelled.
private final class SlowLocationTransport: SSHTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _closed = 0
    var locationStarted: Bool { lock.withLock { _started } }
    var closedSessions: Int { lock.withLock { _closed } }

    func connect(to endpoint: SSHEndpoint, key: DeviceKey,
                 checkHostKey: @escaping @Sendable (HostKey) throws -> Void) async throws -> any SSHSession {
        try checkHostKey(.sample)
        return Session(transport: self)
    }

    fileprivate func markStarted() { lock.withLock { _started = true } }
    fileprivate func markClosed() { lock.withLock { _closed += 1 } }

    private struct Session: SSHSession {
        let transport: SlowLocationTransport

        func execute(_ command: GateCommand, stdin: Data?) async throws -> String {
            if command == .ping { return "PONG 1\n" }
            transport.markStarted()
            try await Task.sleep(for: .seconds(60))
            return "OK\n"
        }

        func openLoopbackForward(remotePort: Int) async throws -> any LoopbackForward {
            throw SSHConnectionError.forwardFailed
        }

        func close() async { transport.markClosed() }
    }
}

/// A transport whose connect never ends (until the task is cancelled).
private struct HangingTransport: SSHTransport {
    func connect(to endpoint: SSHEndpoint, key: DeviceKey,
                 checkHostKey: @escaping @Sendable (HostKey) throws -> Void) async throws -> any SSHSession {
        try await Task.sleep(for: .seconds(60))
        throw SSHConnectionError.unreachable
    }
}
