import Foundation

public struct Connection: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var institution: String
    public var hostname: String
    public var port: UInt16
    public var username: String
    public var keyReference: String?
    public init(id: UUID = UUID(), institution: String, hostname: String, port: UInt16 = 22, username: String, keyReference: String? = nil) {
        self.id = id; self.institution = institution; self.hostname = hostname
        self.port = port; self.username = username; self.keyReference = keyReference
    }
    public func validate() throws {
        // Plain ASCII checks, one condition at a time. A single combined guard with
        // CharacterSet method references was miscompiled in optimized builds.
        func ascii(_ value: String, extra: String) -> Bool {
            value.utf8.allSatisfy { byte in
                (97...122).contains(byte) || (65...90).contains(byte) || (48...57).contains(byte) || extra.utf8.contains(byte)
            }
        }
        let trimmedInstitution = institution.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedInstitution.isEmpty, institution.count <= 128 else { throw ConnectionError.invalid }
        guard !hostname.isEmpty, hostname.utf8.count <= 253, !hostname.hasPrefix("-"), ascii(hostname, extra: ".-:") else { throw ConnectionError.invalid }
        guard port > 0 else { throw ConnectionError.invalid }
        guard !username.isEmpty, username.utf8.count <= 128, !username.hasPrefix("-"), ascii(username, extra: "._-@") else { throw ConnectionError.invalid }
        if let keyReference {
            guard keyReference.hasPrefix("/"), keyReference.utf8.count <= 4096,
                  !keyReference.utf8.contains(where: { $0 < 32 || $0 == 127 }) else { throw ConnectionError.invalid }
        }
    }
}
public enum ConnectionError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? { "Enter an institution, valid SSH hostname, port (1–65535), and account username." }
}

public enum RouteSource: String, Codable, Sendable { case builtIn, custom }

public struct Route: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public let domain: Domain
    public var enabled: Bool
    public let source: RouteSource
    public init(id: String = UUID().uuidString, domain: Domain, enabled: Bool = true, source: RouteSource = .custom) {
        self.id = id; self.domain = domain; self.enabled = enabled; self.source = source
    }
}

public struct RoutePack: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var enabled: Bool
    public var routes: [Route]
    public init(id: String, name: String, enabled: Bool = true, routes: [Route]) {
        self.id = id; self.name = name; self.enabled = enabled; self.routes = routes
    }

    public static func defaults() throws -> [RoutePack] {
        // The assembled app uses a conventional Contents/Resources layout. The
        // SwiftPM bundle remains the fallback for tests and unbundled executables.
        guard let url = Bundle.main.url(forResource: "route-packs", withExtension: "json")
                ?? Bundle.module.url(forResource: "route-packs", withExtension: "json") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return try JSONDecoder().decode([RoutePack].self, from: Data(contentsOf: url))
    }

    /// Brings saved packs up to date with the bundled list: adds new built-in
    /// packs and routes, drops built-ins that are no longer bundled, and keeps
    /// the user's toggles and custom routes.
    public static func merging(saved: [RoutePack], defaults: [RoutePack]) -> [RoutePack] {
        var result = saved.map { pack -> RoutePack in
            var pack = pack
            let bundled = defaults.first { $0.id == pack.id }?.routes ?? []
            pack.routes.removeAll { route in
                route.source == .builtIn && !bundled.contains { $0.id == route.id && $0.domain == route.domain }
            }
            return pack
        }
        for pack in defaults {
            guard let index = result.firstIndex(where: { $0.id == pack.id }) else { result.append(pack); continue }
            for route in pack.routes where !result[index].routes.contains(where: { $0.id == route.id }) {
                result[index].routes.append(route)
            }
        }
        return result
    }
}

public struct RouteSet: Equatable, Sendable {
    public let domains: [Domain]
    public init(packs: [RoutePack]) {
        domains = Array(Set(packs.filter(\.enabled).flatMap(\.routes).filter(\.enabled).map(\.domain))).sorted()
    }
    public init(domains: [Domain]) { self.domains = Array(Set(domains)).sorted() }
    public func matches(host: String) -> Bool { domains.contains { $0.matches(host: host) } }
}

public enum TunnelState: String, Codable, Sendable {
    case disabled, connecting, connected, reconnecting, disconnecting, error
}
public enum RoutingState: String, Codable, Sendable { case inactive, experimental, active, degraded, error }
public struct RuntimeStatus: Codable, Sendable {
    public var requestedEnabled: Bool = false
    public var tunnel: TunnelState = .disabled
    public var routing: RoutingState = .inactive
    public var error: String?
    public var reason: String?
    public var ownerPID: Int32?
    public var tunnelPID: Int32?
    public init() {}
}

public struct AppConfiguration: Codable, Equatable, Sendable {
    public var version = 1
    public var connection: Connection?
    public var packs: [RoutePack]
    public var launchAtLogin = false
    public var connectOnLaunch = false
    public var selectedServiceIDs: [String]?
    public var networkLocationID: String?
    public init(packs: [RoutePack]) { self.packs = packs }
}

public protocol RoutingBackend: Sendable {
    func activate(routes: RouteSet, socksPort: UInt16) async throws
    func applyRoutes(_ routes: RouteSet) async throws
    func deactivate() async throws
    func status() async -> RuntimeStatus
}
