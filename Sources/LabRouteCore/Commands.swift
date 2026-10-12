import Foundation

public enum AppCommand: String, Codable, Sendable {
    case status, connect, disconnect, enable, disable, recover, routes, services, preferences, diagnostics, operation, cancel, quit
    case routeAdd = "route.add", routeEnable = "route.enable", routeDisable = "route.disable"
    case packSet = "pack.set", routeSet = "route.set", servicesSet = "services.set", preferenceSet = "preference.set"
}
public struct ControlRequest: Codable, Sendable {
    public var version = 2
    public var command: String
    public var domain: String?
    public var id: String?
    public var pack: String?
    public var enabled: Bool?
    public var serviceIDs: [String]?
    public var nonInteractive: Bool?
    public var expectedOwnerPID: Int32?
    public init(command: String, domain: String? = nil, id: String? = nil, pack: String? = nil, enabled: Bool? = nil, serviceIDs: [String]? = nil) {
        self.command = command; self.domain = domain; self.id = id; self.pack = pack; self.enabled = enabled; self.serviceIDs = serviceIDs
    }
    public init(_ command: AppCommand) { self.command = command.rawValue }
}
public enum ControlErrorCode: String, Codable, Sendable {
    case invalidRequest, unsupportedVersion, busy, recoveryRequired, setupRequired, operationFailed, cancelled, notFound, unavailable, timeout, humanInteractionRequired
}
public enum OperationPhase: String, Codable, Sendable { case accepted, running, completed, failed, cancelled }
public struct ControlOperation: Codable, Sendable {
    public var id: String
    public var command: String
    public var phase: OperationPhase
    public var errorCode: ControlErrorCode?
    public var reason: String?
    public init(command: String) { id = UUID().uuidString; self.command = command; phase = .accepted }
    public var terminal: Bool { [.completed, .failed, .cancelled].contains(phase) }
}
public struct ServiceInfo: Codable, Sendable {
    public var id: String
    public var name: String
    public var active: Bool
    public var selected: Bool
    public init(id: String, name: String, active: Bool, selected: Bool) { self.id = id; self.name = name; self.active = active; self.selected = selected }
}
public struct ControlResponse: Codable, Sendable {
    public var version = 2
    public var success: Bool
    public var message: String
    public var status: RuntimeStatus?
    public var routes: [RoutePack]?
    public var errorCode: ControlErrorCode?
    public var operation: ControlOperation?
    public var services: [ServiceInfo]?
    public var preferences: [String: Bool]?
    public var events: [String]?
    public var recoveryRequired: Bool?
    public var humanInteraction: String?
    public var cancellationDeferred: Bool?
    public var shuttingDown: Bool?
    public init(success: Bool, message: String, status: RuntimeStatus? = nil, routes: [RoutePack]? = nil) {
        self.success = success; self.message = message; self.status = status; self.routes = routes
    }
}
