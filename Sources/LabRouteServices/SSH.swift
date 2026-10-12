import Foundation
import Security
import LocalAuthentication
import LabRouteCore

public enum SSHOptions {
    public static func base(_ connection: Connection, knownHosts: URL, trustNewHost: Bool = false) throws -> [String] {
        try connection.validate()
        return ["-F", "/dev/null", "-p", String(connection.port), "-l", connection.username,
                "-o", "UserKnownHostsFile=\(knownHosts.path)", "-o", "GlobalKnownHostsFile=/dev/null",
                "-o", "StrictHostKeyChecking=\(trustNewHost ? "ask" : "yes")",
                "-o", "UpdateHostKeys=no", "-o", "ForwardAgent=no", "-o", "ControlMaster=no",
                "-o", "ControlPath=none", "-o", "PermitLocalCommand=no", "-o", "RequestTTY=no",
                "-o", "ConnectTimeout=15", "-o", "ConnectionAttempts=1", "-o", "NumberOfPasswordPrompts=1",
                "-o", "KbdInteractiveAuthentication=no", "-o", "ServerAliveInterval=30", "-o", "ServerAliveCountMax=3"]
    }
    public static func key(_ connection: Connection, knownHosts: URL, trustNewHost: Bool = false) throws -> [String] {
        guard let path = connection.keyReference, path.hasPrefix("/"), !path.contains("\n") else {
            throw RuntimeError.message("Choose or create an SSH private key first.")
        }
        return try base(connection, knownHosts: knownHosts, trustNewHost: trustNewHost) +
            ["-i", path, "-o", "IdentitiesOnly=yes", "-o", "PreferredAuthentications=publickey", "-o", "PasswordAuthentication=no"]
    }
    public static func tunnel(_ connection: Connection, knownHosts: URL, port: UInt16) throws -> [String] {
        guard port > 0 else { throw RuntimeError.message("Invalid SOCKS port.") }
        return try key(connection, knownHosts: knownHosts) + ["-N", "-D", "127.0.0.1:\(port)",
                "-o", "ExitOnForwardFailure=yes", "--", connection.hostname]
    }
    public static func classify(_ diagnostic: String) -> (message: String, retry: Bool) {
        let text = diagnostic.lowercased()
        if text.contains("host key verification failed") || text.contains("remote host identification has changed") {
            return ("The SSH host key is unknown or changed. Verify it with your institution before reconnecting.", false)
        }
        if text.contains("permission denied") || text.contains("authentication failed") || text.contains("load key") {
            return ("SSH key authentication failed. Check the account, key, and institution's authentication policy.", false)
        }
        if text.contains("address already in use") || text.contains("cannot listen") || text.contains("could not request local forwarding") {
            return ("The managed SOCKS port is occupied. Disconnect before trying again.", false)
        }
        if ["bad configuration", "bad permissions", "invalid format", "no such identity", "no matching host key", "no matching key exchange", "no mutual signature"].contains(where: text.contains) {
            return ("SSH configuration or key compatibility needs attention before reconnecting.", false)
        }
        return ("The SSH connection was interrupted or could not be established.", true)
    }
    public static func retryDelay(attempt: Int, jitter: Double = Double.random(in: 0.85...1.15)) -> Double {
        min(60, pow(2, Double(min(max(attempt, 0), 6)))) * min(max(jitter, 0.5), 1.5)
    }
    // Fixed remote command, never interpolated. Only a generated/validated public
    // key line enters stdin. Existing authorized_keys bytes are never replaced.
    public static let installPublicKey = """
    umask 077
    IFS= read -r key || exit 20
    case "$key" in 'ssh-ed25519 '*) ;; *) exit 21 ;; esac
    test ! -L "$HOME/.ssh" || exit 22
    mkdir -p "$HOME/.ssh" || exit 23
    chmod 700 "$HOME/.ssh" || exit 23
    file="$HOME/.ssh/authorized_keys"
    test ! -L "$file" || exit 22
    touch "$file" || exit 24
    chmod 600 "$file" || exit 24
    grep -qxF "$key" "$file" || printf '\\n%s\\n' "$key" >> "$file" || exit 25
    """
}

public protocol KeySecretStore: Sendable {
    func read(_ id: String) throws -> String?
    func save(_ value: String, id: String) throws
    func delete(_ id: String) throws
    func read(_ id: String, allowUserInteraction: Bool) throws -> String?
}
public extension KeySecretStore {
    func read(_ id: String, allowUserInteraction: Bool) throws -> String? { try read(id) }
}
public struct NonInteractiveSecrets: KeySecretStore {
    let base: any KeySecretStore
    public func read(_ id: String) throws -> String? { try base.read(id, allowUserInteraction: false) }
    public func save(_ value: String, id: String) throws { throw RuntimeError.message("Noninteractive credential storage is unavailable.") }
    public func delete(_ id: String) throws { throw RuntimeError.message("Noninteractive credential deletion is unavailable.") }
}
public struct KeychainSecrets: KeySecretStore {
    public init() {}
    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "org.labroute.keys", kSecAttrAccount as String: id]
    }
    public func read(_ id: String) throws -> String? {
        try read(id, allowUserInteraction: true)
    }
    public func read(_ id: String, allowUserInteraction: Bool) throws -> String? {
        var query = query(id)
        if !allowUserInteraction {
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
        }
        query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        if !allowUserInteraction && [errSecInteractionNotAllowed, errSecAuthFailed].contains(status) { throw CredentialError.interactionRequired }
        guard status == errSecSuccess, let bytes = result as? Data, let string = String(data: bytes, encoding: .utf8) else {
            throw RuntimeError.message("Keychain could not unlock the SSH key (\(status)).")
        }
        return string
    }
    public func save(_ value: String, id: String) throws {
        let data = Data(value.utf8)
        let status = SecItemUpdate(query(id) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(id); item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw RuntimeError.message("Could not save the SSH key passphrase in Keychain.") }
        } else if status != errSecSuccess { throw RuntimeError.message("Could not update the SSH key passphrase in Keychain.") }
    }
    public func delete(_ id: String) throws {
        let status = SecItemDelete(query(id) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw RuntimeError.message("Could not remove the Keychain item.") }
    }
}

public enum CredentialError: Error, LocalizedError {
    case interactionRequired
    public var errorDescription: String? { "Keychain access requires approval in LabRoute. No prompt was requested." }
}

public struct CredentialQuestion: Identifiable, Sendable {
    public enum Kind: Sendable { case hostTrust, accountPassword, keyPassphrase }
    public let id = UUID()
    public let kind: Kind
    public let message: String
}
public struct CredentialReply: Codable, Sendable {
    public let value: String?
    public init(value: String?) { self.value = value }
}

@MainActor public final class CredentialSession {
    public var allowedPID: Int32?
    public private(set) var environment: [String: String] = [:]
    private var server: LocalServer?
    private let helper: String
    private var stopped = false
    public init(helper: URL, passphrase: String?, interactive: Bool,
                prompt: @escaping @MainActor @Sendable (CredentialQuestion) async -> String?) throws {
        self.helper = helper.resolvingSymlinksInPath().path
        guard FileManager.default.isExecutableFile(atPath: self.helper) else { throw RuntimeError.message("The bundled SSH credential helper is missing. Reinstall LabRoute.") }
        let url = LocalSocket.directory.appendingPathComponent(UUID().uuidString + ".sock")
        environment = ["SSH_ASKPASS": self.helper, "SSH_ASKPASS_REQUIRE": "force", "LABROUTE_ASKPASS_SOCKET": url.path]
        server = try LocalServer(url: url) { [weak self] data, peer in
            await self?.answer(data: data, peer: peer, passphrase: passphrase, interactive: interactive, prompt: prompt)
                ?? Data("{\"value\":null}".utf8)
        }
    }
    private func answer(data: Data, peer: LocalPeer, passphrase: String?, interactive: Bool,
                        prompt: @MainActor @Sendable (CredentialQuestion) async -> String?) async -> Data {
        var answer: String?
        if !stopped, let allowedPID, peer.parentPID == allowedPID, peer.executable == helper,
           let text = try? JSONDecoder().decode(String.self, from: data), text.count <= 4096 {
            let lower = text.lowercased()
            if lower.contains("passphrase") {
                answer = passphrase
                if answer == nil && interactive { answer = await prompt(CredentialQuestion(kind: .keyPassphrase, message: "Unlock the selected SSH private key.")) }
            } else if interactive && lower.contains("yes/no") {
                answer = await prompt(CredentialQuestion(kind: .hostTrust, message: text))
            } else if interactive && lower.contains("password") {
                answer = await prompt(CredentialQuestion(kind: .accountPassword, message: "Enter your institutional SSH account password. It is used for this setup attempt only and is not saved."))
            }
        }
        if stopped { answer = nil }
        return (try? JSONEncoder().encode(CredentialReply(value: answer))) ?? Data("{\"value\":null}".utf8)
    }
    public func stop() { stopped = true; server?.stop(); server = nil; allowedPID = nil }
}

@MainActor public final class SSHOnboarding {
    private let runner: any ProcessRunner
    private let secrets: any KeySecretStore
    public init(runner: any ProcessRunner = SystemProcessRunner(), secrets: any KeySecretStore = KeychainSecrets()) {
        self.runner = runner; self.secrets = secrets
    }
    public static func directory(_ connection: Connection) -> URL {
        LabRoutePaths.support.appendingPathComponent("SSH/" + connection.id.uuidString, isDirectory: true)
    }
    public static func knownHosts(_ connection: Connection) -> URL { directory(connection).appendingPathComponent("known_hosts") }
    public func setup(_ initial: Connection, helper: URL,
                      prompt: @escaping @MainActor @Sendable (CredentialQuestion) async -> String?) async throws -> Connection {
        try initial.validate()
        var connection = initial
        let directory = Self.directory(connection)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let knownHosts = Self.knownHosts(connection)
        if !FileManager.default.fileExists(atPath: knownHosts.path) { try PrivateFile.write(Data(), to: knownHosts) }
        let creating = connection.keyReference == nil
        var passphrase: String?
        if creating {
            let path = directory.appendingPathComponent("id_ed25519").path
            connection.keyReference = path
            if FileManager.default.fileExists(atPath: path) {
                passphrase = try secrets.read(connection.id.uuidString)
                guard passphrase != nil else { throw RuntimeError.message("A generated key exists without its Keychain passphrase. Choose another setup or recover the key; it will not be overwritten.") }
            } else {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw RuntimeError.message("Could not generate a secure key passphrase.") }
            passphrase = Data(bytes).base64EncodedString()
            // No controlling terminal in the app: OpenSSH reads both passphrase
            // prompts from this private pipe. No -N/-P secret in argv.
            let result = try await collect(ProcessSpec("/usr/bin/ssh-keygen", ["-q", "-t", "ed25519", "-a", "64", "-C", "LabRoute", "-f", path],
                input: Data((passphrase! + "\n" + passphrase! + "\n").utf8)), runner: runner)
            guard result.0 == 0 else { throw RuntimeError.message("Could not generate the encrypted SSH key.") }
            connection.keyReference = path
            do { try secrets.save(passphrase!, id: connection.id.uuidString) } catch {
                try? FileManager.default.removeItem(atPath: path)
                try? FileManager.default.removeItem(atPath: path + ".pub")
                throw error
            }
            }
        } else {
            passphrase = try secrets.read(connection.id.uuidString)
        }
        var suppliedPassphrase: String?
        let session = try CredentialSession(helper: helper, passphrase: passphrase, interactive: true) { question in
            let value = await prompt(question)
            if case .keyPassphrase = question.kind { suppliedPassphrase = value }
            return value
        }
        defer { session.stop() }
        if creating {
            let publicKey = try String(contentsOfFile: connection.keyReference! + ".pub", encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            let fields = publicKey.split(separator: " ")
            guard fields.count >= 2, fields[0] == "ssh-ed25519", Data(base64Encoded: String(fields[1])) != nil,
                  !publicKey.contains("\n") else { throw RuntimeError.message("Generated public key is invalid.") }
            let args = try SSHOptions.base(connection, knownHosts: knownHosts, trustNewHost: true) +
                ["-o", "PubkeyAuthentication=no", "-o", "PreferredAuthentications=password", "--", connection.hostname, SSHOptions.installPublicKey]
            let result = try await collect(ProcessSpec("/usr/bin/ssh", args, environment: session.environment, input: Data((publicKey + "\n").utf8)),
                                           runner: runner, timeout: .seconds(180), started: { session.allowedPID = $0 })
            guard result.0 == 0 else { throw RuntimeError.message("Key installation failed. The institution may prohibit password authentication or authorized_keys changes; check the account details and permissions. Generated keys remain in LabRoute's SSH directory for recovery.") }
        }
        let args = try SSHOptions.key(connection, knownHosts: knownHosts, trustNewHost: !creating) + ["--", connection.hostname, "true"]
        let result = try await collect(ProcessSpec("/usr/bin/ssh", args, environment: session.environment), runner: runner,
                                       timeout: .seconds(180), started: { session.allowedPID = $0 })
        guard result.0 == 0 else { throw RuntimeError.message(SSHOptions.classify(result.2).message) }
        if let suppliedPassphrase { try secrets.save(suppliedPassphrase, id: connection.id.uuidString) }
        return connection
    }
}
