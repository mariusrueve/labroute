import Foundation
import Security
import SystemConfiguration

/// Short-lived, synchronous session. Never share one instance across threads.
public final class SystemProxyPreferences: ProxyPreferences {
    private let preferences: SCPreferences
    private var authorization: AuthorizationRef?
    private var locked: Bool

    public init(writable: Bool, allowUserInteraction: Bool = true) throws {
        var auth: AuthorizationRef?
        if writable {
            let status = AuthorizationCreate(nil, nil, [], &auth)
            guard status == errAuthorizationSuccess else { throw ProxyError.system(status) }
            if !allowUserInteraction, let auth {
                do { try authorizeNetworkPreferencesWithoutInteraction(auth) }
                catch { AuthorizationFree(auth, []); throw error }
            }
        }
        guard let prefs = SCPreferencesCreateWithAuthorization(nil, "LabRoute" as CFString, nil, auth) else {
            if let auth { AuthorizationFree(auth, []) }
            throw ProxyError.system(SCError())
        }
        if writable && !SCPreferencesLock(prefs, false) {
            if let auth { AuthorizationFree(auth, []) }
            throw ProxyError.system(SCError())
        }
        preferences = prefs
        authorization = auth
        locked = writable
    }


    public func finish() {
        if locked { SCPreferencesUnlock(preferences); locked = false }
    }

    deinit {
        if locked { SCPreferencesUnlock(preferences) }
        if let authorization { AuthorizationFree(authorization, []) }
    }

    public func read() throws -> [String: ProxySnapshot] {
        guard let services = SCNetworkServiceCopyAll(preferences) as? [SCNetworkService] else { throw ProxyError.system(SCError()) }
        var result: [String: ProxySnapshot] = [:]
        for service in services {
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  let serviceID = SCNetworkServiceGetServiceID(service) else { continue }
            let id = serviceID as String
            let dictionary = SCNetworkProtocolGetConfiguration(proto) as? [String: Any]
            result[id] = try ProxySnapshot(enabled: SCNetworkProtocolGetEnabled(proto), dictionary: dictionary)
        }
        return result
    }

    public func stage(_ snapshot: ProxySnapshot, for service: String) throws {
        guard locked,
              let service = SCNetworkServiceCopy(preferences, service as CFString),
              let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) else {
            throw ProxyError.system(SCError())
        }
        let dictionary = try snapshot.dictionary()
        guard SCNetworkProtocolSetConfiguration(proto, dictionary as CFDictionary?),
              SCNetworkProtocolSetEnabled(proto, snapshot.enabled) else { throw ProxyError.system(SCError()) }
    }

    public func commitAndApply() throws {
        guard locked, SCPreferencesCommitChanges(preferences), SCPreferencesApplyChanges(preferences) else {
            throw ProxyError.system(SCError())
        }
    }

    public func services() throws -> [NetworkService] {
        guard let location = SCNetworkSetCopyCurrent(preferences),
              let locationID = SCNetworkSetGetSetID(location),
              let services = SCNetworkSetCopyServices(location) as? [SCNetworkService] else { throw ProxyError.noServices }
        let primary = Self.primaryServices()
        return services.compactMap { service in
            guard SCNetworkServiceGetEnabled(service), let id = SCNetworkServiceGetServiceID(service),
                  SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies) != nil else { return nil }
            let kind = SCNetworkServiceGetInterface(service).flatMap { SCNetworkInterfaceGetInterfaceType($0) } as String? ?? "Unknown"
            return NetworkService(id: id as String, name: SCNetworkServiceGetName(service) as String? ?? kind,
                                  locationID: locationID as String, isPrimary: primary.contains(id as String), kind: kind)
        }.sorted { $0.name < $1.name }
    }

    public static func primaryServices() -> Set<String> {
        guard let store = SCDynamicStoreCreate(nil, "LabRoute" as CFString, nil, nil) else { return [] }
        var result = Set<String>()
        for family in ["IPv4", "IPv6"] {
            if let value = SCDynamicStoreCopyValue(store, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
               let id = value["PrimaryService"] as? String { result.insert(id) }
        }
        return result
    }

    public static func effectivePACURL() -> String? {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any],
              (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true else { return nil }
        return settings["ProxyAutoConfigURLString"] as? String
    }
}

/// Preauthorize the same right checked by Apple's preference helper, which would
/// otherwise request interactive authorization inside SCPreferencesLock.
/// https://github.com/apple-oss-distributions/configd/blob/main/SystemConfiguration.fproj/helper/SCHelper_server.c
func authorizeNetworkPreferencesWithoutInteraction(
    _ authorization: AuthorizationRef,
    copyRights: (AuthorizationRef, UnsafePointer<AuthorizationRights>, AuthorizationFlags) -> OSStatus = {
        AuthorizationCopyRights($0, $1, nil, $2, nil)
    }
) throws {
    try authorizeNetworkPreferences(authorization, interaction: false, copyRights: copyRights)
}

func authorizeNetworkPreferences(
    _ authorization: AuthorizationRef, interaction: Bool,
    copyRights: (AuthorizationRef, UnsafePointer<AuthorizationRights>, AuthorizationFlags) -> OSStatus = {
        AuthorizationCopyRights($0, $1, nil, $2, nil)
    }
) throws {
    let status = "system.services.systemconfiguration.network".withCString { name in
        var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
        return withUnsafeMutablePointer(to: &item) { pointer in
            var rights = AuthorizationRights(count: 1, items: pointer)
            return copyRights(authorization, &rights, interaction ? [.extendRights, .interactionAllowed] : [.extendRights])
        }
    }
    guard status == errAuthorizationSuccess else { throw ProxyError.authorizationRequired }
}

public enum LabRoutePaths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LabRoute", isDirectory: true)
    }
    public static var journal: URL { support.appendingPathComponent("proxy-restoration.json") }
}

public struct NetworkService: Identifiable, Sendable {
    public let id: String
    public let name: String
    public let locationID: String
    public let isPrimary: Bool
    public let kind: String
}
