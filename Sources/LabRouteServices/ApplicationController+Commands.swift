import Foundation
import LabRouteCore

@MainActor extension ApplicationController {
    public func selectService(_ id: String, enabled: Bool) {
        var ids = selectedServices
        if enabled { ids.insert(id) } else { ids.remove(id) }
        let result = execute(ControlRequest(command: "services.set", serviceIDs: ids.sorted()))
        if !result.success { error = result.message }
    }
    public func handleSleep() { tunnel.suspend() }
    public func handleWake() { tunnel.resume(); refreshServices(); if needsRecovery && serving { revalidate() } }
    public func shutdownControl() { httpProxy.stop(); routeObserver = nil; monitor?.cancel(); validationTask?.cancel(); networkRefreshTask?.cancel(); networkObserver?.stop(); controlServer?.stop() }
    func finishOperation(_ result: Result<Void, ControlFailure>) {
        humanInteraction = nil
        guard let id = activeOperation, let index = operations.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success: operations[index].phase = .completed; operations[index].errorCode = nil; operations[index].reason = nil
        case .failure(let failure):
            operations[index].phase = failure.code == .cancelled ? .cancelled : .failed
            operations[index].errorCode = failure.code
            operations[index].reason = failure.reason
        }
        activeOperation = nil
    }
    struct ControlFailure: Error { let code: ControlErrorCode; var reason: String? = nil }
    func operationFailure(_ error: Error) -> Result<Void, ControlFailure> {
        if case ProxyError.authorizationRequired = error { return .failure(ControlFailure(code: .humanInteractionRequired, reason: "authorizationRequired")) }
        if case CredentialError.interactionRequired = error { return .failure(ControlFailure(code: .humanInteractionRequired, reason: "keychainAccessRequired")) }
        return .failure(ControlFailure(code: error is CancellationError ? .cancelled : .operationFailed,
            reason: error is CancellationError ? "cancelled" : "operationFailed"))
    }
    func responseDelivered(_ data: Data, peerPID: Int32? = nil) {
        guard shutdownRequested, quitAwaitingDelivery, peerPID == quitRequesterPID,
              let response = try? JSONDecoder().decode(ControlResponse.self, from: data),
              let operation = response.operation, operation.command == "quit", operation.phase == .completed,
              operation.id == operations.last?.id else { return }
        beginShutdown()
    }
    func scheduleShutdown() {
        if !quitAwaitingDelivery { beginShutdown(); return }
        // A CLI may disconnect without polling completion. Do not wait forever.
        shutdownTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            self?.beginShutdown()
        }
    }
    func beginShutdown() {
        guard !shutdownStarted else { return }
        shutdownStarted = true; shutdownTask?.cancel()
        Task { [self] in
            shutdownControl()
            await controlServer?.stopAndDrain(timeout: .seconds(2))
            terminate()
        }
    }
    public func dispatch(_ data: Data, peerPID: Int32? = nil) -> Data {
        handlingIPC = true; requestingPID = peerPID
        defer { handlingIPC = false; requestingPID = nil }
        let response: ControlResponse
        do { response = execute(try JSONDecoder().decode(ControlRequest.self, from: data)) }
        catch {
            var failure = ControlResponse(success: false, message: "Invalid command frame")
            failure.errorCode = .invalidRequest; response = failure
        }
        return (try? JSONEncoder().encode(response)) ?? Data()
    }
    @discardableResult public func execute(_ request: ControlRequest) -> ControlResponse {
        func failure(_ code: ControlErrorCode, _ message: String) -> ControlResponse {
            var result = ControlResponse(success: false, message: message)
            result.errorCode = code; result.version = request.version == 1 ? 1 : 2
            return result
        }
        guard [1, 2].contains(request.version) else { return failure(.unsupportedVersion, "Unsupported protocol version") }
        guard ownsRuntime else { return failure(.unavailable, "This instance does not own LabRoute runtime") }
        if let owner = request.expectedOwnerPID, owner != ProcessInfo.processInfo.processIdentifier {
            return failure(.unavailable, "Runtime owner changed")
        }
        if shutdownRequested, !["status", "operation", "diagnostics", "routes", "services", "preferences", "route.resolve"].contains(request.command) {
            return failure(.busy, "LabRoute is shutting down")
        }
        guard let command = AppCommand(rawValue: request.command) else { return failure(.invalidRequest, "Unknown command") }
        var response = ControlResponse(success: true, message: "Completed")
        response.version = request.version
        do {
            switch command {
            case .status:
                var runtime = RuntimeStatus()
                runtime.requestedEnabled = serving || needsRecovery
                runtime.tunnel = tunnelState; runtime.routing = routingState
                runtime.reason = routingReason
                runtime.ownerPID = ProcessInfo.processInfo.processIdentifier
                runtime.tunnelPID = tunnel.ownedProcess?.pid
                // Detailed native errors can contain paths. The control API exposes a fixed summary.
                runtime.error = error == nil ? nil : "An operation needs attention in LabRoute."
                response.status = runtime; response.message = request.version == 1 ? status : "Runtime status"
                response.recoveryRequired = needsRecovery; response.humanInteraction = humanInteraction
                response.operation = operations.last
                response.httpProxyPort = httpProxy.port
            case .routeResolve:
                // Read-only and never recorded: ssh calls this for every connection.
                guard let host = request.domain, !host.isEmpty, host.utf8.count <= 255 else { return failure(.invalidRequest, "A host is required") }
                let tunnel = serving && tunnelState == .connected && activeSocksPort != nil
                response.resolution = RouteResolution(routed: RouteSet(packs: packs).matches(host: host), tunnel: tunnel, socksPort: tunnel ? activeSocksPort : nil)
                response.message = "Route resolution"
            case .diagnostics:
                response.events = events; response.message = "Operational events"
            case .routes: response.routes = packs
            case .services:
                refreshServices()
                response.services = services.map { ServiceInfo(id: $0.id, name: $0.name, active: $0.isPrimary, selected: selectedServices.contains($0.id)) }
            case .preferences:
                response.preferences = ["autoConnect": connectOnLaunch, "launchAtLogin": loginEnabled]
            case .operation:
                guard let operation = operations.first(where: { $0.id == request.id }) else { return failure(.notFound, "Operation not found; it may belong to a previous app session") }
                response.operation = operation
                response.success = operation.phase != .failed && operation.phase != .cancelled
                response.errorCode = operation.errorCode
            case .cancel:
                guard let activeOperation, request.id == nil || request.id == activeOperation else { return failure(.notFound, "No matching operation") }
                guard setupTask != nil else { return failure(.busy, "This operation cannot be cancelled safely") }
                cancelSetup()
                response.message = proxyTransactionInProgress ? "Cancellation deferred until the settings transaction completes" : "Cancellation requested"
            case .connect, .enable, .recover, .disconnect, .disable, .quit:
                guard !busy, activeOperation == nil else { return failure(.busy, "An operation is in progress") }
                if [.connect, .enable, .recover].contains(command) {
                    guard configuredConnection != nil, configuration != nil else { return failure(.setupRequired, "Complete native SSH setup first") }
                    if command == .recover {
                        guard needsRecovery, transaction.needsRecovery, !serving else { return failure(.recoveryRequired, "Disconnect to complete runtime cleanup before reconnecting") }
                    } else {
                        guard !needsRecovery, !serving else { return failure(.recoveryRequired, "Disconnect or recover the recorded session first") }
                    }
                }
                var operation = ControlOperation(command: command.rawValue)
                operation.phase = .running
                operations.append(operation); if operations.count > 100 { operations.removeFirst() }
                runtimeGeneration += 1
                activeOperation = operation.id; cancellationRequested = false
                operationNonInteractive = request.nonInteractive == true || environment.forceNonInteractive
                if command == .quit { shutdownRequested = true; quitAwaitingDelivery = handlingIPC; quitRequesterPID = requestingPID }
                switch command {
                case .connect, .enable: connectImpl()
                case .recover: reconnectRecoveryImpl()
                default: restoreImpl(quitAfter: command == .quit)
                }
                response.operation = operation; response.message = "Accepted"
            default:
                guard !busy, activeOperation == nil else { return failure(.busy, "An operation is in progress") }
                error = nil
                switch command {
                case .routeAdd, .routeEnable, .routeDisable, .routeRemove:
                    guard let domain = request.domain else { return failure(.invalidRequest, "A domain is required") }
                    do { try saveRoutes(RouteEditing.apply(String(command.rawValue.dropFirst(6)), domain: domain, packID: request.pack ?? "custom", to: packs)) }
                    catch let error where error is DomainError || error is RouteEditError || error is RuntimeError {
                        // Fixed, path-free messages: show the user what to change.
                        return failure(.invalidRequest, error.localizedDescription)
                    }
                case .packSet:
                    guard let id = request.id, let enabled = request.enabled, packs.contains(where: { $0.id == id }) else { return failure(.invalidRequest, "Unknown pack or missing enabled value") }
                    setPackImpl(id, enabled: enabled)
                case .routeSet:
                    guard let id = request.id, let pack = request.pack, let enabled = request.enabled,
                          packs.contains(where: { $0.id == pack && $0.routes.contains(where: { $0.id == id }) }) else { return failure(.invalidRequest, "Unknown route or missing enabled value") }
                    setRouteImpl(packID: pack, routeID: id, enabled: enabled)
                case .servicesSet:
                    guard !serving, !needsRecovery, let ids = request.serviceIDs, var saved = configuration else { return failure(.recoveryRequired, "Disconnect before selecting services") }
                    let available = try environment.services()
                    guard Set(ids).isSubset(of: Set(available.map(\.id))) else { return failure(.invalidRequest, "Unknown service") }
                    saved.selectedServiceIDs = Array(Set(ids)).sorted()
                    try store.save(saved); configuration = saved; selectedServices = Set(ids)
                case .preferenceSet:
                    guard let enabled = request.enabled else { return failure(.invalidRequest, "An enabled value is required") }
                    switch request.id {
                    case "autoConnect": setAutoConnectImpl(enabled)
                    case "launchAtLogin":
                        guard request.nonInteractive != true && !environment.forceNonInteractive else { return failure(.humanInteractionRequired, "Login registration requires interactive settings") }
                        setLoginImpl(enabled)
                    default: return failure(.invalidRequest, "Unknown preference")
                    }
                default: return failure(.invalidRequest, "Unsupported command")
                }
                if error != nil { return failure(.operationFailed, "Operation failed; inspect the app for recovery") }
            }
        } catch {
            return failure(.operationFailed, "Operation failed; settings and recovery records were preserved")
        }
        response.cancellationDeferred = proxyTransactionInProgress && cancellationRequested
        response.shuttingDown = shutdownRequested
        response.humanInteraction = humanInteraction
        return response
    }
    public func connect() { _ = execute(ControlRequest(.connect)) }
    public func reconnectRecovery() { _ = execute(ControlRequest(.recover)) }
    public func restore(quitAfter: Bool = false) { _ = execute(ControlRequest(quitAfter ? .quit : .disconnect)) }
    public func setLogin(_ enabled: Bool) { _ = execute(ControlRequest(command: "preference.set", id: "launchAtLogin", enabled: enabled)) }
    public func setAutoConnect(_ enabled: Bool) { _ = execute(ControlRequest(command: "preference.set", id: "autoConnect", enabled: enabled)) }
    public func setPack(_ id: String, enabled: Bool) { _ = execute(ControlRequest(command: "pack.set", id: id, enabled: enabled)) }
    public func setRoute(packID: String, routeID: String, enabled: Bool) { _ = execute(ControlRequest(command: "route.set", id: routeID, pack: packID, enabled: enabled)) }


}
