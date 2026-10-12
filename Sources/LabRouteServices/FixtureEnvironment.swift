#if DEBUG
import Foundation
import LabRouteCore

/// Development-only adapters. No system preferences, Keychain, or SSH execution.
public enum FixturePaths {
    public static func root(_ id: String) throws -> URL {
        guard UUID(uuidString: id) != nil else { throw RuntimeError.message("Fixture ID must be a UUID") }
        return LocalSocket.directory.appendingPathComponent("fixture-" + id.lowercased(), isDirectory: true)
    }
}
public struct FixtureSecrets: KeySecretStore {
    public init() {}
    public func delete(_ id: String) throws {}
    public func read(_ id: String) throws -> String? { nil }
    public func save(_ value: String, id: String) throws { throw RuntimeError.message("Fixture credentials cannot be saved") }
}
@MainActor private struct NoProcesses: ProcessRunner {
    func start(_ spec: ProcessSpec) throws -> any ChildProcess { throw RuntimeError.message("External execution is disabled in fixtures") }
}
public final class FixturePreferences: ProxyPreferences {
    public var current: [String: ProxySnapshot]
    public var refuseCommit = false
    public init() throws { current = ["fixture-wifi": try ProxySnapshot(enabled: true, dictionary: [:])] }
    public func read() throws -> [String: ProxySnapshot] { current }
    public func stage(_ snapshot: ProxySnapshot, for service: String) throws { staged[service] = snapshot }
    private var staged: [String: ProxySnapshot] = [:]
    public func commitAndApply() throws {
        guard !refuseCommit else { throw ProxyError.verificationFailed }
        current.merge(staged) { _, new in new }; staged.removeAll()
    }
    public func finish() { staged.removeAll() }
}
@MainActor public final class FixtureTunnel: TunnelController {
    public private(set) var state: TunnelState = .disabled
    public var ownedProcess: OwnedSSHProcess? { nil }
    public var changed: ((TunnelState, String?) -> Void)?
    public var startFailure = false
    public var suspended = false
    public init() {}
    public func start(connection: Connection, port: UInt16, helper: URL, secrets: any KeySecretStore) async throws {
        state = .connecting; changed?(state, nil)
        await Task.yield(); try Task.checkCancellation()
        if startFailure { state = .error; changed?(state, "Synthetic authentication failure"); throw RuntimeError.message("Synthetic authentication failure") }
        state = .connected; changed?(state, nil)
    }
    public func stop() async { state = .disabled; changed?(state, nil) }
    public func suspend() { suspended = true; state = .reconnecting; changed?(state, nil) }
    public func resume() { if suspended { suspended = false; state = .connected; changed?(state, nil) } }
}
@MainActor public final class FixtureEnvironment {
    public let proxy: FixturePreferences
    public let tunnel = FixtureTunnel()
    public var activeServices: Set<String> = ["fixture-wifi"]
    public let root: URL
    public init(id: String) throws {
        root = try FixturePaths.root(id)
        try LocalSocket.prepareDirectory()
        try LocalSocket.prepareDirectory(root)
        proxy = try FixturePreferences()
        // Reconstruct only the isolated fixture preferences after a host restart.
        let transaction = ProxyTransaction(journalURL: root.appendingPathComponent("journal.json"))
        if let record = try transaction.record() { proxy.current = record.phase == .applied ? record.applied : record.original }
        let store = ConfigurationStore(url: root.appendingPathComponent("configuration.json"))
        if try store.load() == nil {
            var config = AppConfiguration(packs: [RoutePack(id: "custom", name: "Synthetic", routes: [Route(domain: try Domain("selected.labroute.test"))])])
            config.connection = Connection(institution: "Fixture", hostname: "ssh.labroute.test", port: 22, username: "fixture", keyReference: "/nonexistent/fixture-key")
            config.selectedServiceIDs = ["fixture-wifi"]
            try store.save(config)
        }
    }
    public func environment() -> ControllerEnvironment {
        var result = ControllerEnvironment(configuration: root.appendingPathComponent("configuration.json"), journal: root.appendingPathComponent("journal.json"),
            socket: root.appendingPathComponent("control.sock"), helper: root.appendingPathComponent("no-helper"), tunnel: tunnel,
            secrets: FixtureSecrets(), preferences: { [self] _ in proxy },
            services: { [self] in [NetworkService(id: "fixture-wifi", name: "Wi-Fi", locationID: "fixture-location", isPrimary: activeServices.contains("fixture-wifi"), kind: "IEEE80211")] },
            primary: { [self] in activeServices }, effectivePAC: { [self] in try? proxy.current["fixture-wifi"]?.dictionary()?["ProxyAutoConfigURLString"] as? String },
            loginStatus: { (false, "Disabled in fixtures") }, setLogin: { _ in throw RuntimeError.message("Login registration is disabled in fixtures") },
            onboarding: SSHOnboarding(runner: NoProcesses(), secrets: FixtureSecrets()))
        result.onboardingAllowed = false
        result.requireAvailable = { _ in }
        return result
    }
}
#endif
