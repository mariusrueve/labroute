import Foundation

public struct ProxyActivation: Sendable {
    public let pacURL: URL
    public let serviceIDs: Set<String>
    public let locationID: String
    public let runtime: RoutingRecovery?
    public let allowUserInteraction: Bool
    public init(pacURL: URL, serviceIDs: Set<String>, locationID: String, runtime: RoutingRecovery?, allowUserInteraction: Bool = true) {
        self.pacURL = pacURL; self.serviceIDs = serviceIDs; self.locationID = locationID; self.runtime = runtime
        self.allowUserInteraction = allowUserInteraction
    }
}

/// Each session is created, used, and released on this queue. No preference or
/// authorization object crosses the queue boundary; only immutable values do.
public final class ProxyWorker: Sendable {
    private let queue = DispatchQueue(label: "org.labroute.proxy-transactions", qos: .userInitiated)
    private let journal: URL
    public init(journal: URL) { self.journal = journal }
    func run<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
    public func install(_ activation: ProxyActivation) async throws {
        try await run { [journal] in
            try ProxyTransaction(journalURL: journal).install(pacURL: activation.pacURL,
                preferences: SystemProxyPreferences(writable: true, allowUserInteraction: activation.allowUserInteraction), serviceIDs: activation.serviceIDs,
                locationID: activation.locationID, runtime: activation.runtime,
                verifyEffective: { try Self.waitForEffective { SystemProxyPreferences.effectivePACURL() == activation.pacURL.absoluteString } })
        }
    }
    public func restore(allowUserInteraction: Bool = true) async throws -> OwnedSSHProcess? {
        try await run { [journal] in
            let transaction = ProxyTransaction(journalURL: journal)
            let record = try transaction.record()
            let process = record?.runtime?.ownedProcess
            let ownedURLs = Set(try (record?.applied ?? [:]).values.compactMap { try $0.dictionary()?["ProxyAutoConfigURLString"] as? String })
            if let record {
                try transaction.restore(preferences: SystemProxyPreferences(writable: record.phase == .applied, allowUserInteraction: allowUserInteraction), deferCleanup: true,
                    verifyEffective: { try Self.waitForEffective { !ownedURLs.contains(SystemProxyPreferences.effectivePACURL() ?? "") } })
            }
            return process
        }
    }
    public func completeCleanup() async throws {
        try await run { [journal] in
            let transaction = ProxyTransaction(journalURL: journal)
            guard let record = try transaction.record() else { return }
            try transaction.completeCleanup {
                let current = try SystemProxyPreferences(writable: false).read()
                guard record.original.allSatisfy({ current[$0.key] == $0.value }) else { throw ProxyError.externalChange }
                let ownedURLs = Set(try record.applied.values.compactMap { try $0.dictionary()?["ProxyAutoConfigURLString"] as? String })
                try Self.waitForEffective { !ownedURLs.contains(SystemProxyPreferences.effectivePACURL() ?? "") }
            }
        }
    }
    static func waitForEffective(_ ready: () -> Bool) throws {
        let deadline = ContinuousClock.now + .seconds(5)
        repeat {
            if ready() { return }
            Thread.sleep(forTimeInterval: 0.05)
        } while ContinuousClock.now < deadline
        throw ProxyError.verificationFailed
    }
    public func validate(_ pacURL: String) async throws -> RoutingValidation {
        try await run { [journal] in
            let preferences = try SystemProxyPreferences(writable: false)
            return try RoutingValidation.inspect(preferences: preferences, services: preferences.services(), primary: SystemProxyPreferences.primaryServices(),
                effectivePAC: SystemProxyPreferences.effectivePACURL(), journal: ProxyTransaction(journalURL: journal), pacURL: pacURL)
        }
    }
    public func services() async throws -> [NetworkService] {
        try await run { try SystemProxyPreferences(writable: false).services() }
    }
    public func recovery(_ connectionID: UUID) async throws -> RoutingRecovery {
        try await run { [journal] in
            try ProxyTransaction(journalURL: journal).recovery(preferences: SystemProxyPreferences(writable: false), connectionID: connectionID)
        }
    }
    public func updateProcess(_ process: OwnedSSHProcess?) async throws {
        try await run { [journal] in
            try ProxyTransaction(journalURL: journal).updateOwnedProcess(process, preferences: SystemProxyPreferences(writable: false))
        }
    }
}
