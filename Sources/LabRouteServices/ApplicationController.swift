import Combine
import Foundation
import LabRouteCore

@MainActor
open class ApplicationController: ObservableObject {
    @Published public var domain = ""
    @Published public var packs: [RoutePack] = []
    @Published public var destinationPack = "custom"
    @Published public var socksPort = "1080"
    @Published public var pacURL = ""
    @Published public var status = "Not routing · setup in progress"
    @Published public var error: String? { didSet { routingValidationOwnsError = false } }
    var routingValidationOwnsError = false
    @Published public private(set) var ownsRuntime = true
    var routingReason: String?
    var operationNonInteractive = false
    var validationTask: Task<Void, Never>?
    var validationEpoch = 0
    var validationAgain = false
    var networkRefreshTask: Task<Void, Never>?
    var networkObserver: NetworkObservation?

    @Published public var busy = false
    @Published public var serving = false
    var activeSocksPort: UInt16?
    @Published public var needsRecovery = false
    @Published public var services: [NetworkService] = []
    @Published public var selectedServices: Set<String> = []
    @Published public var institution = ""
    @Published public var hostname = ""
    @Published public var sshPort = "22"
    @Published public var username = ""
    @Published public var keyPath = ""
    @Published public var credential: CredentialQuestion?
    @Published public var credentialValue = ""
    @Published public var configuredConnection: Connection?
    @Published public var connectOnLaunch = false
    @Published public var loginEnabled = false
    @Published public var loginStatus = ""
    @Published public var events: [String] = []
    var setupID = UUID()
    var credentialContinuation: CheckedContinuation<String?, Never>?
    var setupTask: Task<Void, Never>?
    let store: ConfigurationStore
    let environment: ControllerEnvironment
    public var terminate: () -> Void = {}
    /// Called when a quit request could not restore settings; the app stays running.
    public var quitFailed: () -> Void = {}
    public var isShuttingDown: Bool { shutdownStarted }
    public var prompt: (@MainActor @Sendable (CredentialQuestion) async -> String?)?
    @Published public var routingState: RoutingState = .inactive
    @Published public var humanInteraction: String?
    var operations: [ControlOperation] = []
    var activeOperation: String?
    var cancellationRequested = false
    var proxyTransactionInProgress = false
    var shutdownRequested = false
    var handlingIPC = false
    var requestingPID: Int32?
    var quitRequesterPID: Int32?
    var quitAwaitingDelivery = false
    var shutdownTask: Task<Void, Never>?
    var shutdownStarted = false
    var runtimeGeneration = 0
    var configuration: AppConfiguration?
    var monitor: Task<Void, Never>?
    @Published public var tunnelState: TunnelState = .disabled
    @Published public var sshIntegration = SSHIntegration()
    @Published public var sshConfigStatus = ""
    @Published public var sshHookState: HookState = .missing
    @Published public var shellHookState: HookState = .missing
    var sshSyncTask: Task<Void, Never>?
    @Published public var httpProxyStatus = ""
    public let httpProxy = SplitHTTPProxy()
    var routeObserver: AnyCancellable?
    var controlServer: LocalServer?
    let tunnel: any TunnelController
    let server = PACServer()
    let transaction: ProxyTransaction

    public init(environment: ControllerEnvironment = .live(), startIPC: Bool = true) {
        self.environment = environment
        store = ConfigurationStore(url: environment.configuration)
        transaction = ProxyTransaction(journalURL: environment.journal)
        tunnel = environment.tunnel
        if startIPC { do {
            controlServer = try LocalServer(url: environment.socket, delivered: { [weak self] data, peer in
                await self?.responseDelivered(data, peerPID: peer.pid)
            }) { [weak self] data, peer in
                await self?.dispatch(data, peerPID: peer.pid) ?? Data()
            }
        } catch {
            self.error = error.localizedDescription
            ownsRuntime = false
            status = "Another LabRoute owner is active · this instance is inactive"
            return
        }
        }
        server.changed = { [weak self] ready in
            guard let self, !ready, self.serving else { return }
            self.routingState = .degraded; self.routingReason = "pacUnavailable"
            self.status = "Routing degraded · PAC unavailable"
        }
        needsRecovery = transaction.needsRecovery || environment.runtimeNeedsRecovery() || tunnel.cleanupRequired
        if needsRecovery { routingState = .degraded; status = "Restoration record found · inspect or restore settings" }
        do {
            configuration = try store.load() ?? AppConfiguration(packs: RoutePack.defaults())
            packs = configuration?.packs ?? []
            connectOnLaunch = configuration?.connectOnLaunch ?? false
            configuredConnection = configuration?.connection
            selectedServices = Set(configuration?.selectedServiceIDs ?? [])
            sshIntegration = configuration?.ssh ?? SSHIntegration()
            if let connection = configuredConnection {
                institution = connection.institution; hostname = connection.hostname
                username = connection.username; sshPort = String(connection.port)
                keyPath = connection.keyReference ?? ""; setupID = connection.id
            }
        } catch { self.error = "Configuration recovery required: " + error.localizedDescription }
        refreshServices()
        refreshLoginStatus()
        refreshTerminalHooks()
        scheduleSSHSync()
        startHTTPProxy()
        tunnel.changed = { [weak self] state, message in
            guard let self else { return }
            self.tunnelState = state
            self.record("SSH " + state.rawValue)
            if let message { self.error = message }
            if state == .reconnecting || state == .error {
                self.routingState = self.needsRecovery ? .degraded : .inactive
                self.routingReason = "sshUnavailable"
                self.status = state == .reconnecting ? "Reconnecting · routing rules retained" : "SSH error · routing rules retained"
            }
            if state == .connected && self.needsRecovery {
                if !self.busy { self.error = nil }
                if !self.busy {
                    let generation = self.runtimeGeneration
                    let identity = self.tunnel.ownedProcess
                    Task { [weak self] in
                        guard let self, !self.busy, !self.shutdownRequested, generation == self.runtimeGeneration else { return }
                        do { try await self.environment.updateProxyProcess(identity) }
                        catch {
                            guard generation == self.runtimeGeneration, !self.busy else { return }
                            self.error = error.localizedDescription; self.routingState = .degraded; return
                        }
                        guard generation == self.runtimeGeneration, !self.busy, self.tunnel.ownedProcess == identity else { return }
                        self.revalidate()
                    }
                }
            }
        }
        if environment.allowsAutomaticConnection && connectOnLaunch && configuredConnection != nil && !needsRecovery && configuration != nil {
            Task { [weak self] in self?.connect() }
        }
        networkObserver = environment.observeNetwork { [weak self] in
            Task { @MainActor in self?.networkChanged() }
        }
        if environment.monitorEnabled { monitor = Task { [weak self] in
            while !Task.isCancelled {
                try? await environment.sleep(.seconds(30))
                guard let self else { return }
                if self.needsRecovery && self.serving { self.revalidate() }
            }
        }
    }

    }

    public func refreshLoginStatus() {
        (loginEnabled, loginStatus) = environment.loginStatus()
    }

    func setLoginImpl(_ enabled: Bool) {
        do {
            guard var saved = configuration else { throw RuntimeError.message("Resolve configuration recovery first.") }
            try environment.setLogin(enabled)
            refreshLoginStatus()
            saved.launchAtLogin = loginEnabled
            try store.save(saved); configuration = saved
            record("Login preference updated")
        } catch { self.error = error.localizedDescription; refreshLoginStatus() }
    }

    func setAutoConnectImpl(_ enabled: Bool) {
        do {
            guard var saved = configuration else { throw RuntimeError.message("Resolve configuration recovery first.") }
            saved.connectOnLaunch = enabled
            try store.save(saved); configuration = saved; connectOnLaunch = enabled
            record("Automatic connection preference updated")
        } catch { self.error = error.localizedDescription }
    }

    func record(_ event: String) {
        // Fixed operational event strings only: never routes, URLs, credentials, or raw SSH output.
        events.append(environment.now().formatted(date: .omitted, time: .standard) + " · " + event)
        if events.count > 100 { events.removeFirst(events.count - 100) }
    }

    func saveRoutes(_ updated: [RoutePack]) throws {
        guard !busy, var saved = configuration else {
            throw RuntimeError.message("Wait for the current operation to finish before editing routes.")
        }
        if serving {
            // Live edit: the PAC URL stays the same, so no network-settings change
            // or authorization is needed. Journal first, so recovery uses the new list.
            guard let port = activeSocksPort else { throw RuntimeError.message("Disconnect before editing routes; resolve any recovery error first.") }
            let routes = RouteSet(packs: updated)
            guard !routes.domains.isEmpty else { throw RuntimeError.message("Keep at least one domain enabled while connected, or disconnect first.") }
            let script = try PACGenerator.generate(routes: routes, socksPort: port)
            try environment.updateProxyDomains(routes.domains)
            saved.packs = updated
            try store.save(saved)
            server.update(script: script)
        } else {
            guard !needsRecovery else { throw RuntimeError.message("Disconnect to finish recovery before editing routes.") }
            saved.packs = updated
            try store.save(saved)
        }
        configuration = saved; packs = updated
        record("Routes saved")
        scheduleSSHSync()
    }

    public func addRoute() {
        let response = execute(ControlRequest(command: "route.add", domain: domain, pack: destinationPack))
        if response.success { domain = ""; error = nil } else { error = response.message }
    }

    public func removeRoute(_ domain: String) {
        let response = execute(ControlRequest(command: "route.remove", domain: domain))
        error = response.success ? nil : response.message
    }

    func setPackImpl(_ id: String, enabled: Bool) {
        var updated = packs
        guard let index = updated.firstIndex(where: { $0.id == id }) else { return }
        updated[index].enabled = enabled
        do { try saveRoutes(updated); error = nil } catch { self.error = error.localizedDescription }
    }

    func setRouteImpl(packID: String, routeID: String, enabled: Bool) {
        var updated = packs
        guard let p = updated.firstIndex(where: { $0.id == packID }),
              let r = updated[p].routes.firstIndex(where: { $0.id == routeID }) else { return }
        updated[p].routes[r].enabled = enabled
        do { try saveRoutes(updated); error = nil } catch { self.error = error.localizedDescription }
    }

}
