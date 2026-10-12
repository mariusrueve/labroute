import Foundation
import LabRouteCore
import ServiceManagement

@MainActor public protocol TunnelController: AnyObject {
    var state: TunnelState { get }
    var ownedProcess: OwnedSSHProcess? { get }
    var cleanupRequired: Bool { get }
    var changed: ((TunnelState, String?) -> Void)? { get set }
    func start(connection: Connection, port: UInt16, helper: URL, secrets: any KeySecretStore) async throws
    func stop() async throws
    func suspend()
    func resume()
}
extension TunnelController { public var cleanupRequired: Bool { false } }
extension SSHSupervisor: TunnelController {}

@MainActor public struct ControllerEnvironment {
    public var configuration: URL
    public var journal: URL
    public var socket: URL
    public var helper: URL
    public var tunnel: any TunnelController
    public var secrets: any KeySecretStore
    public var preferences: (Bool) throws -> any ProxyPreferences
    public var services: () throws -> [NetworkService]
    public var primary: () -> Set<String>
    public var effectivePAC: () -> String?
    public var loginStatus: () -> (Bool, String)
    public var setLogin: (Bool) throws -> Void
    public var sleep: (Duration) async throws -> Void
    public var now: () -> Date
    public var onboarding: SSHOnboarding
    public var onboardingAllowed = true
    public var requireAvailable: @MainActor (UInt16) throws -> Void = SSHSupervisor.requireAvailable
    public var installProxy: (ProxyActivation) async throws -> Void
    public var restoreProxy: () async throws -> OwnedSSHProcess?
    public var recoverProxy: (UUID) async throws -> RoutingRecovery
    public var updateProxyProcess: (OwnedSSHProcess?) async throws -> Void
    public var updateProxyDomains: ([Domain]) throws -> Void
    public var monitorEnabled = true
    public var forceNonInteractive = false
    public var allowsAutomaticConnection = true
    public var runtimeNeedsRecovery: () -> Bool = { false }
    public var cleanupRuntime: () async throws -> Void = {}
    public var validateProxy: ((String) async throws -> RoutingValidation)?
    public var readServices: (() async throws -> [NetworkService])?
    public var restoreProxyWithoutInteraction: (() async throws -> OwnedSSHProcess?)?
    public var completeProxyCleanup: () async throws -> Void
    public var observeNetwork: (@escaping @Sendable () -> Void) -> NetworkObservation? = { _ in nil }
    public init(configuration: URL, journal: URL, socket: URL, helper: URL, tunnel: any TunnelController,
                secrets: any KeySecretStore, preferences: @escaping (Bool) throws -> any ProxyPreferences,
                services: @escaping () throws -> [NetworkService], primary: @escaping () -> Set<String>,
                effectivePAC: @escaping () -> String?, loginStatus: @escaping () -> (Bool, String),
                setLogin: @escaping (Bool) throws -> Void, onboarding: SSHOnboarding,
                sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, now: @escaping () -> Date = Date.init) {
        self.configuration = configuration; self.journal = journal; self.socket = socket; self.helper = helper
        self.tunnel = tunnel; self.secrets = secrets; self.preferences = preferences; self.services = services
        self.primary = primary; self.effectivePAC = effectivePAC; self.loginStatus = loginStatus; self.setLogin = setLogin
        self.onboarding = onboarding; self.sleep = sleep; self.now = now
        // Injected fixture adapters remain on the main actor. Live sessions use
        // the serialized worker below and never block the controller actor.
        self.installProxy = { activation in
            try ProxyTransaction(journalURL: journal).install(pacURL: activation.pacURL, preferences: preferences(true),
                serviceIDs: activation.serviceIDs, locationID: activation.locationID, runtime: activation.runtime)
        }
        self.restoreProxy = {
            let transaction = ProxyTransaction(journalURL: journal)
            let process = try transaction.record()?.runtime?.ownedProcess
            if transaction.needsRecovery { try transaction.restore(preferences: preferences(true), deferCleanup: true) }
            return process
        }
        self.completeProxyCleanup = { try ProxyTransaction(journalURL: journal).completeCleanup() }
        self.recoverProxy = { id in try ProxyTransaction(journalURL: journal).recovery(preferences: preferences(false), connectionID: id) }
        self.updateProxyDomains = { domains in try ProxyTransaction(journalURL: journal).updateDomains(domains, preferences: preferences(false)) }
        self.updateProxyProcess = { process in try ProxyTransaction(journalURL: journal).updateOwnedProcess(process, preferences: preferences(false)) }
    }
    public static func live() -> Self {
        let runtime = RuntimeProcessStore(url: LabRoutePaths.support.appendingPathComponent("ssh-runtime.json"))
        var result = Self(configuration: LabRoutePaths.support.appendingPathComponent("configuration.json"), journal: LabRoutePaths.journal,
             socket: LocalSocket.control, helper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/LabRouteAskPass"),
             tunnel: SSHSupervisor(recordProcess: { try runtime.record($0) }, requiresProcessIdentity: true), secrets: KeychainSecrets(), preferences: { try SystemProxyPreferences(writable: $0) },
             services: { try SystemProxyPreferences(writable: false).services() }, primary: SystemProxyPreferences.primaryServices,
             effectivePAC: SystemProxyPreferences.effectivePACURL,
             loginStatus: {
                 let state = SMAppService.mainApp.status
                 switch state {
                 case .enabled: return (true, "Launch at login is enabled")
                 case .requiresApproval: return (true, "Allow LabRoute in System Settings → General → Login Items")
                 default: return (false, "Launch at login is off")
                 }
             }, setLogin: { if $0 { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }, onboarding: SSHOnboarding())
        let worker = ProxyWorker(journal: result.journal)
        result.installProxy = { try await worker.install($0) }
        result.restoreProxy = { try await worker.restore() }
        result.recoverProxy = { try await worker.recovery($0) }
        result.updateProxyProcess = { try await worker.updateProcess($0) }
        result.restoreProxyWithoutInteraction = { try await worker.restore(allowUserInteraction: false) }
        result.completeProxyCleanup = { try await worker.completeCleanup() }
        result.validateProxy = { try await worker.validate($0) }
        result.readServices = { try await worker.services() }
        result.observeNetwork = { NetworkObservation($0) }
        result.runtimeNeedsRecovery = { runtime.needsRecovery }
        result.cleanupRuntime = { try await runtime.cleanup() }
        return result
    }
}
