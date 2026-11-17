import CryptoKit
import Foundation

/// The text that the owner installs on the server for the device key (research.md D1, D2).
public struct ServerInstallGuide: Sendable, Equatable {
    /// The forced-command gate from issue #2 (`server/install.sh --gate-dest` default).
    public static let defaultGatePath = "/usr/local/libexec/hermesconnect/hermesconnect-gate"
    /// Where the owner copies the `server/` folder before the install.
    public static let serverFolder = "/tmp/hermesconnect-server"

    public let publicKeyLine: String
    public let user: String
    public let gatePath: String

    public init(publicKeyLine: String, user: String = ServerProfile.defaultUser,
                gatePath: String = ServerInstallGuide.defaultGatePath) {
        self.publicKeyLine = publicKeyLine
        self.user = user
        self.gatePath = gatePath
    }

    /// The key slot of the gate: the first 32 hex digits of SHA-256 over the base64 blob text.
    /// `server/install.sh` computes the same value.
    public var slot: String? {
        let fields = publicKeyLine.split(separator: " ")
        guard fields.count >= 2 else { return nil }
        let digest = SHA256.hash(data: Data(fields[1].utf8))
        return String(digest.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// The first fixed port of the gate slots. `server/install.sh` and the gate use the same rule (issue #29).
    public static let slotPortBase = 47100
    /// The count of slot ports after `slotPortBase`.
    public static let slotPortCount = 100

    /// The fixed server port of the slot: `47100 + (slot as an integer) % 100`, as in `server/install.sh`.
    public var slotPort: Int? {
        guard let slot else { return nil }
        var remainder = 0
        for digit in slot {
            guard let value = digit.hexDigitValue else { return nil }
            remainder = (remainder * 16 + value) % Self.slotPortCount
        }
        return Self.slotPortBase + remainder
    }

    /// The key as `server/install.sh` writes it: type, blob, and the comment with only `[A-Za-z0-9@._+:=-]`,
    /// 64 characters at most, or `hermesconnect` if nothing is left.
    public var installedKeyLine: String? {
        let fields = publicKeyLine.split(whereSeparator: \.isWhitespace)
        guard fields.count >= 2 else { return nil }
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@._+:=-")
        let comment = String(fields.dropFirst(2).joined(separator: "-").filter { allowed.contains($0) }.prefix(64))
        return "\(fields[0]) \(fields[1]) \(comment.isEmpty ? "hermesconnect" : comment)"
    }

    /// The restricted key options (D2): no shell, no agent or X11 forwarding, no remote forwards,
    /// and local forwards to the one slot port on 127.0.0.1 only (issue #41).
    public var keyOptions: String? {
        guard let slot, let port = slotPort else { return nil }
        let command = "\(gatePath) --slot \(slot) --port \(port)"
        return #"restrict,port-forwarding,permitopen="127.0.0.1:\#(port)",permitlisten="127.0.0.1:1",command="\#(command)""#
    }

    /// The command that installs the gate and the key line (issue #2).
    public var installCommand: String {
        "sudo \(Self.serverFolder)/install.sh '\(publicKeyLine)'"
    }

    /// The line that `server/install.sh` adds to `~<user>/.ssh/authorized_keys`. Nil for a bad key line.
    public var authorizedKeysLine: String? {
        guard let keyOptions, let installedKeyLine else { return nil }
        return "\(keyOptions) \(installedKeyLine)"
    }

    public var authorizedKeysPath: String {
        "/home/\(user)/.ssh/authorized_keys"
    }

    /// One step of the install screen. `text` is Markdown.
    public struct Step: Sendable, Equatable {
        public let text: String
        public let code: String?
        public let copyTitle: String?
        public let codeLabel: String?
    }

    /// The install steps. `install.sh` does all of the server work, so no step edits `sshd_config` (issue #41).
    public var steps: [Step] {
        var steps = [Step(text: "Copy the `server` folder of HermesConnect to `\(Self.serverFolder)` on the server. "
                            + "Then run `install.sh` to install the gate and the key:",
                          code: installCommand, copyTitle: "Copy Command",
                          codeLabel: "Install command with the public key of this iPhone")]
        if let authorizedKeysLine {
            steps.append(Step(text: "Make sure that `\(authorizedKeysPath)` has this line:",
                              code: authorizedKeysLine, copyTitle: "Copy Line",
                              codeLabel: "authorized_keys line with the public key of this iPhone"))
        }
        return steps
    }

    /// The footer of the steps.
    public static let footnote = "`install.sh` sets all of the limits of this key. Do not change the SSH server configuration."
}
