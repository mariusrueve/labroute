import Foundation

public struct RoutingValidation: Sendable {
    public let valid: Bool
    public let services: [NetworkService]
    public let reason: String?
    static func inspect(preferences: any ProxyPreferences, services: [NetworkService], primary: Set<String>, effectivePAC: String?, journal: ProxyTransaction, pacURL: String) throws -> Self {
        defer { preferences.finish() }
        guard let record = try journal.record() else { return Self(valid: false, services: services, reason: "recoveryRecordMissing") }
        let current = try preferences.read()
        let owned = record.applied.allSatisfy { current[$0.key] == $0.value }
        let activeSelected = !primary.isEmpty && primary.isSubset(of: Set(record.applied.keys))
        let locationMatches = services.contains { $0.locationID == record.locationID }
        let valid = record.phase == .applied && owned && activeSelected && locationMatches && effectivePAC == pacURL
        return Self(valid: valid, services: services, reason: valid ? nil : "routingMismatch")
    }
}
