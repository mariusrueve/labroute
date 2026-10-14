import Foundation

/// What a lab shares with colleagues: the server, its own domains and ssh hosts.
/// Never usernames, keys, identity files or extra ssh options: those are personal,
/// and extra options from someone else's file could run commands through ssh.
public struct LabSetup: Codable, Equatable, Sendable {
    public struct Host: Codable, Equatable, Sendable {
        public var hostname: String
        public var aliases: [String]
        public var port: UInt16?
    }
    /// File format marker and version.
    public var labroute = 1
    public var institution: String
    public var hostname: String
    public var port: UInt16
    public var internalDomains: [Domain]
    public var customDomains: [Domain]
    public var sshHosts: [Host]
    public var gatewayAliases: [String]

    public init?(_ configuration: AppConfiguration) {
        guard let connection = configuration.connection else { return nil }
        func domains(_ pack: String) -> [Domain] {
            configuration.packs.first { $0.id == pack }?.routes.filter { $0.enabled && $0.source == .custom }.map(\.domain) ?? []
        }
        institution = connection.institution; hostname = connection.hostname; port = connection.port
        internalDomains = domains("internal"); customDomains = domains("custom")
        sshHosts = (configuration.ssh?.hosts ?? []).map { Host(hostname: $0.hostname, aliases: $0.aliases, port: $0.port) }
        gatewayAliases = configuration.ssh?.gateway.aliases ?? []
    }

    /// Domains are validated while decoding; ssh hosts when they are saved.
    public func validate() throws {
        guard labroute == 1 else { throw LabSetupError.invalid }
        // Same rules as a real connection; each colleague adds their own username.
        do { try Connection(institution: institution, hostname: hostname, port: port, username: "colleague").validate() }
        catch { throw LabSetupError.invalid }
    }
}

public enum LabSetupError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? { "This is not a valid LabRoute lab setup file, or it was made by a newer LabRoute." }
}
