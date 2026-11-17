import Foundation
import Testing
@testable import HermesKit

/// Reference keys made with `ssh-keygen -t ed25519` and `-t ecdsa -b 256`. The fingerprints are the `ssh-keygen -lf` output.
enum ReferenceKeys {
    static let ed25519 = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIG0Q9WLxnfi5juAjpmIL2kHJweMCGhDR7osk4FMf0vNA"
    static let ed25519Fingerprint = "SHA256:T5r/itS9RPNL3Q51yC/t1XyFZRF5xlbwU8SBKTbVUQQ"
    static let ecdsa = "ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBJVT2+kjIylAw8aaFC1C5Va8MlJKu99QSvllaNp0xlsrmsXrifXPjRayV+vMQScwOQbrLNkj2EPtqRVYCsUIRtc="
    static let ecdsaFingerprint = "SHA256:1HTdE1YGPc7mvvcsM2WF5Ks29nWGPzbv8p+9+umBTM8"
}

@Suite struct HostKeyTests {
    @Test func fingerprintMatchesSSHKeygen() throws {
        let ed = try #require(HostKey(openSSH: ReferenceKeys.ed25519))
        #expect(ed.fingerprint == ReferenceKeys.ed25519Fingerprint)
        #expect(ed.displayType == "ED25519")
        let ec = try #require(HostKey(openSSH: ReferenceKeys.ecdsa + " root@host"))
        #expect(ec.fingerprint == ReferenceKeys.ecdsaFingerprint)
        #expect(ec.displayType == "ECDSA")
        #expect(ec.openSSH == ReferenceKeys.ecdsa)
    }

    @Test func shortAndSpokenFingerprint() throws {
        let key = try #require(HostKey(openSSH: ReferenceKeys.ed25519))
        #expect(key.shortFingerprint == "SHA256:T5r/itS9RPNL")
        #expect(key.spokenFingerprint.hasPrefix("SHA256, T5r/, itS9, RPNL, 3Q51, "))
        #expect(key.spokenFingerprint.hasSuffix(", UQQ"))
    }

    @Test(arguments: [
        "", "ssh-ed25519", "ssh-ed25519 not-base64!", "ssh-rsa AAAAC3NzaC1lZDI1NTE5AAAAIG0Q9WLxnfi5juAjpmIL2kHJweMCGhDR7osk4FMf0vNA",
        "ssh-ed25519 AAAA",
    ])
    func rejectsInvalidText(text: String) {
        #expect(HostKey(openSSH: text) == nil)
    }

    @Test func codableUsesTheOpenSSHString() throws {
        let key = try #require(HostKey(openSSH: ReferenceKeys.ecdsa))
        let data = try JSONEncoder().encode(key)
        #expect(String(decoding: data, as: UTF8.self) == "\"\(ReferenceKeys.ecdsa.replacingOccurrences(of: "/", with: "\\/"))\"")
        #expect(try JSONDecoder().decode(HostKey.self, from: data) == key)
    }

    @Test func verdict() {
        #expect(HostKeyVerdict.evaluate(received: .sample, pinned: nil) == .unknown(.sample))
        #expect(HostKeyVerdict.evaluate(received: .sample, pinned: .sample) == .trusted)
        #expect(HostKeyVerdict.evaluate(received: .otherSample, pinned: .sample)
                == .changed(saved: .sample, received: .otherSample))
    }

    @Test func samplesAreValidAndDifferent() {
        #expect(HostKey(openSSH: HostKey.sample.openSSH) == .sample)
        #expect(HostKey.sample.fingerprint != HostKey.otherSample.fingerprint)
    }
}

@Suite struct ServerProfileHostKeyTests {
    @Test func versionOneFileHasNoPin() throws {
        let json = #"{"version":1,"host":"h","port":22,"user":"hermes","displayName":"h"}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.hostKey == nil)
        #expect(profile.host == "h")
    }

    @Test func pinRoundTrips() throws {
        let profile = ServerProfile(host: "vps.example.com", hostKey: .sample)
        let decoded = try JSONDecoder().decode(ServerProfile.self, from: JSONEncoder().encode(profile))
        #expect(decoded == profile)
        #expect(decoded.hostKey == .sample)
        #expect(decoded.version == 2)
    }

    @Test func corruptPinCountsAsNoPin() throws {
        let json = #"{"version":2,"host":"h","hostKey":"ssh-ed25519 garbage"}"#
        let profile = try JSONDecoder().decode(ServerProfile.self, from: Data(json.utf8))
        #expect(profile.hostKey == nil)
        #expect(profile.host == "h")
    }

    @Test func differentServer() {
        let base = ServerProfile(host: "vps.example.com", port: 22)
        #expect(!base.isDifferentServer(from: ServerProfile(host: "VPS.example.com", displayName: "Box")))
        #expect(base.isDifferentServer(from: ServerProfile(host: "other.example.com")))
        #expect(base.isDifferentServer(from: ServerProfile(host: "vps.example.com", port: 2222)))
        #expect(base.isDifferentServer(from: ServerProfile(host: "vps.example.com", user: "root")))
    }
}
