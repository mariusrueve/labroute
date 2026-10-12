import Foundation
import SystemConfiguration

/// Observes configuration identities only, never requests or browsing destinations.
private final class NetworkCallback: @unchecked Sendable {
    let invoke: @Sendable () -> Void
    init(_ invoke: @escaping @Sendable () -> Void) { self.invoke = invoke }
}
public final class NetworkObservation: @unchecked Sendable {
    private var store: SCDynamicStore?
    public init?(_ callback: @escaping @Sendable () -> Void) {
        let box = NetworkCallback(callback)
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(box).toOpaque(), retain: { pointer in
            return UnsafeRawPointer(Unmanaged<NetworkCallback>.fromOpaque(pointer).retain().toOpaque())
        }, release: { pointer in
            Unmanaged<NetworkCallback>.fromOpaque(pointer).release()
        }, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "LabRoute events" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<NetworkCallback>.fromOpaque(info).takeUnretainedValue().invoke()
        }, &context) else { return nil }
        self.store = store
        let patterns = ["State:/Network/Global/.*", "State:/Network/Service/.*/Proxies", "Setup:/Network/.*"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns), SCDynamicStoreSetDispatchQueue(store, DispatchQueue(label: "org.labroute.network-events", qos: .utility)) else { self.store = nil; return nil }
    }
    public func stop() { if let store { SCDynamicStoreSetDispatchQueue(store, nil) }; store = nil }
    deinit { stop() }
}
