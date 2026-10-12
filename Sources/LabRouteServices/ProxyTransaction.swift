import Foundation
import Darwin
import LabRouteCore

public struct ProxySnapshot: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var data: Data?
    public init(enabled: Bool, dictionary: [String: Any]?) throws {
        self.enabled = enabled
        data = try dictionary.map { try PropertyListSerialization.data(fromPropertyList: $0, format: .binary, options: 0) }
    }
    public func dictionary() throws -> [String: Any]? {
        try data.map {
            guard let dictionary = try PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] else {
                throw ProxyError.invalidJournal
            }
            return dictionary
        }
    }
    public static func == (lhs: Self, rhs: Self) -> Bool {
        guard lhs.enabled == rhs.enabled else { return false }
        do {
            let a = try lhs.dictionary(), b = try rhs.dictionary()
            if a == nil || b == nil { return a == nil && b == nil }
            return NSDictionary(dictionary: a!).isEqual(to: b!)
        } catch { return false }
    }
}

/// Implementations hold the system preference lock for the whole transaction.
public protocol ProxyPreferences: AnyObject {
    func read() throws -> [String: ProxySnapshot]
    func stage(_ snapshot: ProxySnapshot, for service: String) throws
    func commitAndApply() throws
    func finish()
}

public extension ProxyPreferences {
    func finish() {}
}

public struct RoutingRecovery: Codable, Equatable, Sendable {
    public let connectionID: UUID
    public let socksPort: UInt16
    public let pacPort: UInt16
    public let domains: [Domain]
    public var ownedProcess: OwnedSSHProcess?
    public init(connectionID: UUID, socksPort: UInt16, pacPort: UInt16, domains: [Domain], ownedProcess: OwnedSSHProcess? = nil) {
        self.connectionID = connectionID; self.socksPort = socksPort
        self.pacPort = pacPort; self.domains = domains; self.ownedProcess = ownedProcess
    }
}

public enum JournalPhase: String, Codable, Sendable { case applied, pendingCleanup }
public struct ProxyJournal: Codable {
    public var version = 3
    public var phase: JournalPhase = .applied
    public var locationID: String?
    public var runtime: RoutingRecovery?
    public var original: [String: ProxySnapshot]
    public var applied: [String: ProxySnapshot]
    public init(locationID: String? = nil, runtime: RoutingRecovery? = nil, original: [String: ProxySnapshot], applied: [String: ProxySnapshot]) {
        self.locationID = locationID; self.runtime = runtime; self.original = original; self.applied = applied
    }
    enum CodingKeys: String, CodingKey { case version, phase, locationID, runtime, original, applied }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decode(Int.self, forKey: .version)
        phase = try values.decodeIfPresent(JournalPhase.self, forKey: .phase) ?? .applied
        locationID = try values.decodeIfPresent(String.self, forKey: .locationID)
        runtime = try values.decodeIfPresent(RoutingRecovery.self, forKey: .runtime)
        original = try values.decode([String: ProxySnapshot].self, forKey: .original)
        applied = try values.decode([String: ProxySnapshot].self, forKey: .applied)
    }
}

public final class ProxyTransaction {
    public let journalURL: URL
    public init(journalURL: URL) { self.journalURL = journalURL }
    public var needsRecovery: Bool { FileManager.default.fileExists(atPath: journalURL.path) }

    public func install(pacURL: URL, preferences: any ProxyPreferences, serviceIDs: Set<String>? = nil, locationID: String? = nil, runtime: RoutingRecovery? = nil, verifyEffective: () throws -> Void = {}) throws {
        defer { preferences.finish() }
        let lock = try JournalLock(url: journalURL)
        defer { lock.close() }
        guard pacURL.scheme == "http", pacURL.host == "127.0.0.1", pacURL.path == "/proxy.pac",
              let port = pacURL.port, (1...65535).contains(port),
              pacURL.user == nil, pacURL.password == nil, pacURL.query == nil, pacURL.fragment == nil
        else { throw ProxyError.invalidPACURL }
        guard !needsRecovery else { throw ProxyError.recoveryRequired }
        let available = try preferences.read()
        let selected = serviceIDs ?? Set(available.keys)
        guard !selected.isEmpty, selected.isSubset(of: Set(available.keys)) else { throw ProxyError.noServices }
        let original = available.filter { selected.contains($0.key) }
        guard !original.isEmpty else { throw ProxyError.noServices }
        var applied: [String: ProxySnapshot] = [:]
        for (id, snapshot) in original {
            var dictionary = try snapshot.dictionary() ?? [:]
            let switches = ["HTTPEnable", "HTTPSEnable", "FTPEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
            guard !switches.contains(where: { (dictionary[$0] as? NSNumber)?.boolValue == true }),
                  (dictionary["ProxyAutoConfigURLString"] as? String ?? "").isEmpty,
                  (dictionary["ProxyAutoConfigJavaScript"] as? String ?? "").isEmpty else { throw ProxyError.existingProxy }
            dictionary["ProxyAutoConfigEnable"] = 1
            dictionary["ProxyAutoConfigURLString"] = pacURL.absoluteString
            applied[id] = try ProxySnapshot(enabled: true, dictionary: dictionary)
        }
        let journal = ProxyJournal(locationID: locationID, runtime: runtime, original: original, applied: applied)
        try PrivateFile.write(JSONEncoder().encode(journal), to: journalURL)
        // Journal is durable before the first persistent mutation. On any failure,
        // retain it: a commit can succeed even when apply/verification fails.
        for id in applied.keys.sorted() { try preferences.stage(applied[id]!, for: id) }
        try preferences.commitAndApply()
        let current = try preferences.read()
        guard applied.allSatisfy({ current[$0.key] == $0.value }) else { throw ProxyError.verificationFailed }
        try verifyEffective()
    }

    public func record() throws -> ProxyJournal? {
        guard needsRecovery else { return nil }
        let value = try JSONDecoder().decode(ProxyJournal.self, from: Data(contentsOf: journalURL))
        guard [1, 2, 3].contains(value.version), !value.original.isEmpty,
              Set(value.original.keys) == Set(value.applied.keys) else { throw ProxyError.invalidJournal }
        return value
    }

    public func updateOwnedProcess(_ identity: OwnedSSHProcess?, preferences: any ProxyPreferences) throws {
        defer { preferences.finish() }
        let lock = try JournalLock(url: journalURL)
        defer { lock.close() }
        guard var journal = try record(), journal.phase == .applied, journal.runtime != nil else { throw ProxyError.invalidJournal }
        let current = try preferences.read()
        guard journal.applied.allSatisfy({ current[$0.key] == $0.value }) else { throw ProxyError.externalChange }
        journal.runtime?.ownedProcess = identity
        try PrivateFile.write(JSONEncoder().encode(journal), to: journalURL)
    }

    /// Records the routes served by a live session so recovery reconnects with them.
    public func updateDomains(_ domains: [Domain], preferences: any ProxyPreferences) throws {
        defer { preferences.finish() }
        let lock = try JournalLock(url: journalURL)
        defer { lock.close() }
        guard !domains.isEmpty, var journal = try record(), journal.phase == .applied, journal.runtime != nil else { throw ProxyError.invalidJournal }
        let current = try preferences.read()
        guard journal.applied.allSatisfy({ current[$0.key] == $0.value }) else { throw ProxyError.externalChange }
        journal.runtime = RoutingRecovery(connectionID: journal.runtime!.connectionID, socksPort: journal.runtime!.socksPort,
                                          pacPort: journal.runtime!.pacPort, domains: domains, ownedProcess: journal.runtime!.ownedProcess)
        try PrivateFile.write(JSONEncoder().encode(journal), to: journalURL)
    }

    public func recovery(preferences: any ProxyPreferences, connectionID: UUID) throws -> RoutingRecovery {
        defer { preferences.finish() }
        let lock = try JournalLock(url: journalURL)
        defer { lock.close() }
        guard let journal = try record(), journal.phase == .applied, let runtime = journal.runtime,
              runtime.connectionID == connectionID, runtime.socksPort > 1023,
              runtime.pacPort > 1023, !runtime.domains.isEmpty else { throw ProxyError.recoveryRequired }
        let current = try preferences.read()
        let expectedURL = "http://127.0.0.1:\(runtime.pacPort)/proxy.pac"
        for (id, snapshot) in journal.applied {
            guard current[id] == snapshot else { throw ProxyError.externalChange }
            guard try snapshot.dictionary()?["ProxyAutoConfigURLString"] as? String == expectedURL else {
                throw ProxyError.invalidJournal
            }
        }
        return runtime
    }

    public func restore(preferences: any ProxyPreferences, deferCleanup: Bool = false, verifyEffective: () throws -> Void = {}) throws {
        defer { preferences.finish() }
        let lock = try JournalLock(url: journalURL)
        defer { lock.close() }
        guard needsRecovery else { return }
        var journal = try record()!
        let current = try preferences.read()
        // Validate every service first. Never partly overwrite external changes.
        for id in journal.original.keys {
            guard current[id] == journal.original[id] || (journal.phase == .applied && current[id] == journal.applied[id]) else {
                throw ProxyError.externalChange
            }
        }
        if journal.phase == .applied {
            for id in journal.original.keys.sorted() {
                try preferences.stage(journal.original[id]!, for: id)
            }
            try preferences.commitAndApply()
        }
        let restored = try preferences.read()
        guard journal.original.allSatisfy({ restored[$0.key] == $0.value }) else { throw ProxyError.verificationFailed }
        try verifyEffective()
        journal.version = 3; journal.phase = .pendingCleanup
        try PrivateFile.write(JSONEncoder().encode(journal), to: journalURL)
        if !deferCleanup { try PrivateFile.remove(journalURL) }
    }

    public func completeCleanup(verify: () throws -> Void = {}) throws {
        let lock = try JournalLock(url: journalURL)
        defer { lock.close() }
        guard let journal = try record() else { return }
        guard journal.phase == .pendingCleanup else { throw ProxyError.recoveryRequired }
        if let process = journal.runtime?.ownedProcess, OwnedSSHProcess.capture(process.pid) == process { throw SSHFailure.cleanup }
        try verify()
        try PrivateFile.remove(journalURL)
    }
}

private final class JournalLock {
    private let descriptor: Int32
    init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        descriptor = Darwin.open(url.path + ".lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ProxyError.recoveryRequired }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor)
            throw ProxyError.recoveryRequired
        }
    }
    func close() { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
}

public enum ProxyError: Error, LocalizedError {
    case invalidPACURL, existingProxy, recoveryRequired, noServices, invalidJournal, externalChange, verificationFailed, authorizationRequired
    case system(Int32)
    public var errorDescription: String? {
        switch self {
        case .invalidPACURL: "LabRoute only accepts http://127.0.0.1:<port>/proxy.pac."
        case .existingProxy: "Existing proxy or PAC settings conflict with LabRoute. No settings were changed."
        case .recoveryRequired: "A proxy restoration record exists. Restore it before connecting."
        case .noServices: "No enabled network services with proxy settings are available."
        case .invalidJournal: "The restoration record is invalid. Preserve it and inspect network settings manually."
        case .externalChange: "Network settings changed outside LabRoute. Nothing was overwritten; manual recovery is required."
        case .verificationFailed: "Proxy settings could not be verified. The restoration record was retained."
        case .authorizationRequired: "Network-settings authorization is unavailable without user interaction. No authorization prompt was requested."
        case .system(let code): "macOS rejected the network-settings operation (code \(code)). Authorization or device management may prevent this operation."
        }
    }
}
