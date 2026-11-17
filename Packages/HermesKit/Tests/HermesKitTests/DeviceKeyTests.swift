import CryptoKit
import Foundation
import Testing
@testable import HermesKit

/// RFC 6979 A.2.5 P-256 test key. `ssh-keygen -y` and `ssh-keygen -l` give the expected values.
private enum Vector {
    static let privateKey = Data(hex: "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721")
    static let blobBase64 = "AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGD+1LolWp0xyWHrdMY1bWjASbiSO2H6bOZpYi5g8p+2eQP+EAi4vJmkGunpVii8ZPLxsgwtfp9Rd6PClNRGIpk="
    static let fingerprint = "SHA256:hfuNWmjIYvsBGZ6dpCLTTAEa5LxbZABRHHVoynAxFlo"
    static let slot = "c5a99f5a035055f97cd0fad883cb82cb"
}

@Suite struct OpenSSHPublicKeyTests {
    @Test func blobHasTheRFC5656Layout() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Vector.privateKey).publicKey
        let ssh = OpenSSHPublicKey(publicKey: key, comment: "x")
        var reader = SSHReader(ssh.blob)
        #expect(try reader.string() == Data("ecdsa-sha2-nistp256".utf8))
        #expect(try reader.string() == Data("nistp256".utf8))
        let point = try reader.string()
        #expect(point.count == 65)
        #expect(point.first == 0x04)
        #expect(point == key.x963Representation)
        #expect(reader.isAtEnd)
        #expect(ssh.blob.count == 104)
    }

    @Test func lineAndFingerprintMatchSSHKeygen() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: Vector.privateKey).publicKey
        let ssh = OpenSSHPublicKey(publicKey: key, comment: "hermesconnect@iPhone")
        #expect(ssh.line == "ecdsa-sha2-nistp256 \(Vector.blobBase64) hermesconnect@iPhone")
        #expect(ssh.fingerprint == Vector.fingerprint)
    }

    @Test func commentHasNoSpacesOrNewlines() {
        let ssh = OpenSSHPublicKey(x963Point: Data([0x04] + Array(repeating: 1, count: 64)),
                                   comment: OpenSSHPublicKey.defaultComment(deviceName: "Mark’s iPhone\n"))
        #expect(ssh.comment == "hermesconnect@Mark-s-iPhone-")
        #expect(ssh.line.split(separator: " ").count == 3)
    }

    @Test func emptyCommentGivesTwoFields() {
        let ssh = OpenSSHPublicKey(x963Point: Data([0x04] + Array(repeating: 1, count: 64)), comment: "")
        #expect(ssh.line.split(separator: " ").count == 2)
    }
}

@Suite struct DeviceKeyStoreTests {
    private func makeStore() -> (KeychainDeviceKeyStore, InMemorySecretStore) {
        let secrets = InMemorySecretStore()
        return (KeychainDeviceKeyStore(secrets: secrets, factory: SoftwareKeyFactory()), secrets)
    }

    @Test func noKeyBeforeCreate() throws {
        let (store, _) = makeStore()
        #expect(try store.loadKey() == nil)
    }

    @Test func createStoresTheKeyAndLoadReturnsTheSameKey() throws {
        let (store, secrets) = makeStore()
        let created = try store.createKey()
        #expect(try secrets.read()?.label == DeviceKeyKind.software.rawValue)
        let loaded = try #require(try store.loadKey())
        #expect(loaded.publicKey.x963Representation == created.publicKey.x963Representation)
        #expect(loaded.kind == .software)
    }

    @Test func loadOrCreateCreatesOnce() throws {
        let (store, _) = makeStore()
        let first = try store.loadOrCreateKey()
        let second = try store.loadOrCreateKey()
        #expect(first.publicKey.x963Representation == second.publicKey.x963Representation)
    }

    @Test func resetMakesANewKey() throws {
        let (store, _) = makeStore()
        let old = try store.createKey()
        let new = try store.resetKey()
        #expect(old.publicKey.x963Representation != new.publicKey.x963Representation)
        #expect(try store.loadKey()?.publicKey.x963Representation == new.publicKey.x963Representation)
    }

    @Test func deleteRemovesTheKey() throws {
        let (store, _) = makeStore()
        _ = try store.createKey()
        try store.deleteKey()
        #expect(try store.loadKey() == nil)
    }

    @Test func keyOfAnotherKindIsRejected() throws {
        let secrets = InMemorySecretStore()
        try secrets.write(Data(repeating: 1, count: 32), label: DeviceKeyKind.secureEnclave.rawValue)
        let store = KeychainDeviceKeyStore(secrets: secrets, factory: SoftwareKeyFactory())
        #expect(throws: DeviceKeyError.kindMismatch) { try store.loadKey() }
    }

    @Test func corruptKeyThrows() throws {
        let secrets = InMemorySecretStore()
        try secrets.write(Data([1, 2, 3]), label: DeviceKeyKind.software.rawValue)
        let store = KeychainDeviceKeyStore(secrets: secrets, factory: SoftwareKeyFactory())
        #expect(throws: DeviceKeyError.corruptKey) { try store.loadKey() }
    }

    @Test func signatureVerifiesWithThePublicKey() throws {
        let (store, _) = makeStore()
        let key = try store.createKey()
        let data = Data("session-id-and-userauth-request".utf8)
        let signature = try key.sign(data)
        #expect(key.publicKey.isValidSignature(signature, for: data))
        #expect(!key.publicKey.isValidSignature(signature, for: Data("other".utf8)))
    }

    @Test func descriptionShowsNoPrivateKeyBytes() throws {
        let raw = Vector.privateKey
        let key = SoftwareKeyFactory.wrap(try P256.Signing.PrivateKey(rawRepresentation: raw))
        let texts = [String(describing: key), String(reflecting: key), "\(key)"]
        for text in texts {
            #expect(!text.contains(raw.base64EncodedString()))
            #expect(!text.lowercased().contains(raw.hexString))
            #expect(text.contains(Vector.fingerprint))
        }
    }

    @Test func errorsShowNoKeyBytes() {
        let texts = [DeviceKeyError.accessControl, .corruptKey, .keychain(-34018), .kindMismatch]
            .map { String(describing: $0) }
        #expect(texts.allSatisfy { $0.count < 80 })
    }
}

@Suite struct ServerInstallGuideTests {
    /// `bash server/install.sh --dry-run "$(cat key.pub)"` prints this line for the RFC 6979 key (issue #41).
    @Test func authorizedKeysLineMatchesInstallScript() {
        let line = "ecdsa-sha2-nistp256 \(Vector.blobBase64) hermesconnect@iPhone"
        let guide = ServerInstallGuide(publicKeyLine: line)
        #expect(guide.slot == Vector.slot)
        #expect(guide.authorizedKeysLine ==
            #"restrict,port-forwarding,permitopen="127.0.0.1:47107",permitlisten="127.0.0.1:1",command="/usr/local/libexec/hermesconnect/hermesconnect-gate --slot \#(Vector.slot) --port 47107" "# + line)
        #expect(guide.authorizedKeysPath == "/home/hermes/.ssh/authorized_keys")
        #expect(guide.installCommand == "sudo /tmp/hermesconnect-server/install.sh '\(line)'")
    }

    /// Issue #41: the guide line and the `install.sh` line must not drift. Run the real script for some keys.
    @Test func authorizedKeysLineEqualsInstallScriptDryRun() throws {
        var lines = ["ecdsa-sha2-nistp256 \(Vector.blobBase64) hermesconnect@iPhone",
                     "ecdsa-sha2-nistp256 \(Vector.blobBase64)",
                     "ecdsa-sha2-nistp256 \(Vector.blobBase64) hermesconnect@" + String(repeating: "Long-iPhone-", count: 8)]
        for index in 0..<8 {
            let key = P256.Signing.PrivateKey().publicKey
            lines.append(OpenSSHPublicKey(publicKey: key, comment: "hermesconnect@iPhone-\(index)").line)
        }
        for line in lines {
            let script = try installScriptDryRun(line)
            let guide = ServerInstallGuide(publicKeyLine: line).authorizedKeysLine
            #expect(guide == script)
        }
    }

    /// Issue #41: the guide has no sshd_config step and no reload command. `install.sh` does the server work.
    @Test func stepsHaveNoSSHDConfigOrReload() {
        let guide = ServerInstallGuide(publicKeyLine: "ecdsa-sha2-nistp256 \(Vector.blobBase64) hermesconnect@iPhone")
        #expect(guide.steps.count == 2)
        #expect(guide.steps.first?.code == guide.installCommand)
        #expect(guide.steps.last?.code == guide.authorizedKeysLine)
        let texts = guide.steps.flatMap { [$0.text, $0.code ?? ""] } + [ServerInstallGuide.footnote]
        for banned in ["sshd_config", "sshd -t", "systemctl", "reload", "Match User", "PermitOpen", "127.0.0.1:*"] {
            #expect(!texts.contains { $0.contains(banned) }, "\(banned)")
        }
    }

    @Test func slotPortUsesTheGateRule() {
        #expect(ServerInstallGuide(publicKeyLine: "ecdsa-sha2-nistp256 \(Vector.blobBase64)").slotPort == 47107)
        let ports = (0..<50).compactMap { _ in
            ServerInstallGuide(publicKeyLine: OpenSSHPublicKey(publicKey: P256.Signing.PrivateKey().publicKey,
                                                               comment: "x").line).slotPort
        }
        #expect(ports.count == 50)
        #expect(ports.allSatisfy { (47100..<47200).contains($0) })
    }

    @Test func badKeyLineHasNoAuthorizedKeysLine() {
        let guide = ServerInstallGuide(publicKeyLine: "k")
        #expect(guide.slotPort == nil)
        #expect(guide.authorizedKeysLine == nil)
        #expect(guide.steps.count == 1)
    }

    /// The host hint names Tailscale and only a generic example address.
    @Test func hostHintUsesAGenericTailscaleExample() {
        #expect(ServerProfile.exampleHost == "100.x.y.z")
        #expect(ServerProfile.hostHint.contains("Tailscale"))
        #expect(ServerProfile.hostHint.contains(ServerProfile.exampleHost))
    }
}

/// The line that `server/install.sh --dry-run` prints. It changes nothing on the Mac.
private func installScriptDryRun(_ keyLine: String) throws -> String {
    let script = URL(filePath: #filePath).deletingLastPathComponent()
        .appending(path: "../../../../server/install.sh").standardizedFileURL
    try #require(FileManager.default.fileExists(atPath: script.path), "server/install.sh is missing")
    let process = Process()
    process.executableURL = URL(filePath: "/bin/bash")
    process.arguments = [script.path, "--dry-run", keyLine]
    process.environment = ["PATH": "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin"]
    let output = Pipe(), errors = Pipe()
    process.standardOutput = output
    process.standardError = errors
    try process.run()
    process.waitUntilExit()
    let stdout = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    try #require(process.terminationStatus == 0, "install.sh: \(stderr)")
    return stdout.trimmingCharacters(in: .newlines)
}

// MARK: - Helpers

private struct SSHReader {
    private let data: Data
    private var offset = 0

    init(_ data: Data) { self.data = data }

    var isAtEnd: Bool { offset == data.count }

    mutating func string() throws -> Data {
        guard offset + 4 <= data.count else { throw ReadError.short }
        let length = data[data.startIndex + offset ..< data.startIndex + offset + 4]
            .reduce(0) { $0 << 8 | Int($1) }
        offset += 4
        guard offset + length <= data.count else { throw ReadError.short }
        defer { offset += length }
        return data[data.startIndex + offset ..< data.startIndex + offset + length]
    }

    enum ReadError: Error { case short }
}

extension Data {
    init(hex: String) {
        var bytes = [UInt8]()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            bytes.append(UInt8(hex[index..<next], radix: 16)!)
            index = next
        }
        self.init(bytes)
    }

    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
