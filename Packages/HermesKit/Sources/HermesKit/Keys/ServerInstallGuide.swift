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

    /// The restricted key options (D2): no shell, no agent or X11 forwarding,
    /// local forwards to 127.0.0.1 only, no remote forwards.
    public var keyOptions: String {
        let command = slot.map { "\(gatePath) --slot \($0)" } ?? gatePath
        return #"restrict,port-forwarding,permitopen="127.0.0.1:*",permitlisten="127.0.0.1:1",command="\#(command)""#
    }

    /// The command that installs the gate and the key line (issue #2).
    public var installCommand: String {
        "sudo \(Self.serverFolder)/install.sh '\(publicKeyLine)'"
    }

    /// One line for `~<user>/.ssh/authorized_keys`.
    public var authorizedKeysLine: String {
        "\(keyOptions) \(publicKeyLine)"
    }

    public var authorizedKeysPath: String {
        "/home/\(user)/.ssh/authorized_keys"
    }

    /// A `Match` block for the end of `/etc/ssh/sshd_config`. Key auth only, no remote forwards,
    /// local forwards to 127.0.0.1 only.
    public var sshdMatchBlock: String {
        """
        Match User \(user)
            AuthenticationMethods publickey
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            AllowAgentForwarding no
            AllowStreamLocalForwarding no
            X11Forwarding no
            PermitTunnel no
            GatewayPorts no
            AllowTcpForwarding local
            PermitOpen 127.0.0.1:*
            PermitListen none
        """
    }

    public static let sshdConfigPath = "/etc/ssh/sshd_config"
    public static let reloadCommand = "sudo sshd -t && sudo systemctl reload ssh"
}
