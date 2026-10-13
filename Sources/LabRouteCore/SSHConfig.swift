import Foundation

/// One host the app writes into the managed ssh_config.
public struct SSHHostEntry: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    /// Names that `ssh <alias>` accepts. The HostName itself is always added as a pattern too.
    public var aliases: [String]
    public var hostname: String
    public var port: UInt16?
    public var user: String?
    public var identityFile: String?
    public var identitiesOnly: Bool
    /// Additional `Key value` lines, validated against keys that would break routing.
    public var extraOptions: [String]
    public init(id: UUID = UUID(), aliases: [String], hostname: String, port: UInt16? = nil, user: String? = nil,
                identityFile: String? = nil, identitiesOnly: Bool = false, extraOptions: [String] = []) {
        self.id = id; self.aliases = aliases; self.hostname = hostname; self.port = port; self.user = user
        self.identityFile = identityFile; self.identitiesOnly = identitiesOnly; self.extraOptions = extraOptions
    }

    public func validate() throws {
        guard SSHConfigText.isHostname(hostname) else { throw SSHConfigError.invalid("Enter a valid HostName, e.g. gerrit.example.org.") }
        for alias in aliases where !SSHConfigText.isAlias(alias) {
            throw SSHConfigError.invalid("Aliases are single words without spaces, quotes, wildcards, commas or %.")
        }
        if let port, port == 0 { throw SSHConfigError.invalid("Port must be 1–65535.") }
        if let user, !SSHConfigText.isUser(user) { throw SSHConfigError.invalid("Enter a valid user name.") }
        if let identityFile { try SSHConfigText.validatePath(identityFile) }
        for line in extraOptions { _ = try SSHConfigText.option(line) }
    }
}

/// The jump host used when the LabRoute tunnel is not available. HostName, port
/// and user come from the LabRoute connection.
public struct SSHGateway: Codable, Equatable, Sendable {
    public static let alias = "labroute-gateway"
    public var aliases: [String]
    public var identityFile: String?
    public init(aliases: [String] = [], identityFile: String? = nil) { self.aliases = aliases; self.identityFile = identityFile }
    public func validate() throws {
        for alias in aliases where !SSHConfigText.isAlias(alias) {
            throw SSHConfigError.invalid("Gateway aliases are single words without spaces, quotes, wildcards, commas or %.")
        }
        if let identityFile { try SSHConfigText.validatePath(identityFile) }
    }
}

public struct SSHIntegration: Codable, Equatable, Sendable {
    public var gateway: SSHGateway
    public var hosts: [SSHHostEntry]
    public init(gateway: SSHGateway = SSHGateway(), hosts: [SSHHostEntry] = []) { self.gateway = gateway; self.hosts = hosts }
}

public enum SSHConfigError: Error, LocalizedError, Equatable {
    case invalid(String)
    public var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

enum SSHConfigText {
    static let forbiddenKeys: Set<String> = ["host", "match", "include", "proxycommand", "proxyjump", "proxyusefdpass", "hostname"]

    static func isHostname(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, !value.hasPrefix("-"), !value.hasPrefix(".") else { return false }
        return value.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || $0 == 46 || $0 == 45 }
    }
    static func isAlias(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, !value.hasPrefix("-") else { return false }
        return value.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || "._-".utf8.contains($0) }
    }
    static func isUser(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128, !value.hasPrefix("-") else { return false }
        return value.utf8.allSatisfy { (97...122).contains($0) || (65...90).contains($0) || (48...57).contains($0) || "._-@".utf8.contains($0) }
    }
    static func validatePath(_ value: String) throws {
        guard value.hasPrefix("/") || value.hasPrefix("~/"), value.utf8.count <= 1024,
              !value.utf8.contains(where: { $0 < 32 || $0 == 127 || $0 == 34 || $0 == 39 || $0 == 37 }) else {
            throw SSHConfigError.invalid("Paths must start with / or ~/ and contain no quotes, % or control characters.")
        }
    }
    /// Splits `Key value` (or `Key=value`) and rejects keys owned by LabRoute's routing layers.
    static func option(_ line: String) throws -> (key: String, value: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.utf8.contains(where: { $0 < 32 && $0 != 9 || $0 == 127 }),
              let separator = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" || $0 == "=" }) else {
            throw SSHConfigError.invalid("Extra options are lines like `LocalForward 8080 localhost:80`.")
        }
        let key = String(trimmed[..<separator])
        let value = trimmed[separator...].drop(while: { $0 == " " || $0 == "\t" || $0 == "=" }).trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, key.unicodeScalars.allSatisfy({ ($0.value >= 65 && $0.value <= 90) || ($0.value >= 97 && $0.value <= 122) }), !value.isEmpty else {
            throw SSHConfigError.invalid("Extra options are lines like `LocalForward 8080 localhost:80`.")
        }
        guard !forbiddenKeys.contains(key.lowercased()) else {
            throw SSHConfigError.invalid("\(key) is managed by LabRoute and cannot be set as an extra option.")
        }
        return (key, value)
    }
}

/// Renders `~/.ssh/labroute/config`. ssh uses the first value it obtains, and
/// `Match host` sees HostName only once a Host block has set it, so the order is:
/// host blocks (no proxy keys), then the tunnel layer, then the jump-host fallback.
public enum SSHConfigGenerator {
    public static let header = "# Generated by LabRoute. Edit hosts in the LabRoute app; changes here are overwritten."

    public static func render(connection: Connection, integration: SSHIntegration, customDomains: [Domain], labroutePath: String) throws -> String {
        try integration.gateway.validate()
        for host in integration.hosts { try host.validate() }
        guard SSHConfigText.isHostname(connection.hostname) else { throw SSHConfigError.invalid("The LabRoute SSH hostname cannot be used as a gateway.") }
        guard labroutePath.hasPrefix("/"), !labroutePath.utf8.contains(where: { $0 < 32 || $0 == 39 || $0 == 37 || $0 == 34 }) else {
            throw SSHConfigError.invalid("The LabRoute app path contains characters ssh cannot quote.")
        }
        var names = Set<String>()
        for name in [SSHGateway.alias] + integration.gateway.aliases + integration.hosts.flatMap(\.aliases) {
            guard names.insert(name.lowercased()).inserted else { throw SSHConfigError.invalid("The alias \(name) is used twice.") }
        }

        var lines = [header, ""]
        let gatewayNames = ([SSHGateway.alias] + integration.gateway.aliases).joined(separator: " ")
        lines += ["# Jump host for when the LabRoute tunnel is not connected", "Host \(gatewayNames)",
                  "  HostName \(connection.hostname)", "  Port \(connection.port)", "  User \(connection.username)"]
        if let identity = integration.gateway.identityFile { lines.append("  IdentityFile \"\(identity)\"") }
        lines += ["  ServerAliveInterval 30", "  ServerAliveCountMax 3", ""]

        for host in integration.hosts {
            var patterns = host.aliases
            if !patterns.contains(where: { $0.lowercased() == host.hostname.lowercased() }) { patterns.append(host.hostname) }
            lines += ["Host " + patterns.joined(separator: " "), "  HostName \(host.hostname)"]
            if let port = host.port { lines.append("  Port \(port)") }
            if let user = host.user { lines.append("  User \(user)") }
            if let identity = host.identityFile { lines.append("  IdentityFile \"\(identity)\"") }
            if host.identitiesOnly { lines.append("  IdentitiesOnly yes") }
            for option in host.extraOptions {
                let parsed = try SSHConfigText.option(option)
                lines.append("  \(parsed.key) \(parsed.value)")
            }
            lines.append("")
        }

        let domains = Array(Set(customDomains)).sorted()
        if !domains.isEmpty {
            // Exclude the gateway so ProxyJump never loops through itself.
            let pattern = "\"" + (domains.flatMap { [$0.value, "*." + $0.value] } + ["!" + connection.hostname.lowercased()]).joined(separator: ",") + "\""
            let command = "'" + labroutePath + "'"
            lines += ["# Through the LabRoute tunnel while it is connected",
                      "Match host \(pattern) exec \"\(command) proxy --check %h\"",
                      "  ProxyCommand \(command) proxy %h %p", "",
                      "# Otherwise through the jump host",
                      "Match host \(pattern)",
                      "  ProxyJump \(SSHGateway.alias)", ""]
        }
        return lines.joined(separator: "\n")
    }
}
