import Foundation
import LabRouteCore

@MainActor extension ApplicationController {
    func connectImpl() {
        guard !busy, !needsRecovery, configuration != nil, let connection = configuredConnection else { return }
        busy = true; error = nil; status = "Connecting to your institution"
        setupTask = Task { [self] in
            var outcome: Result<Void, ControlFailure> = .success(())
            defer { busy = false; setupTask = nil; needsRecovery = transaction.needsRecovery || environment.runtimeNeedsRecovery() || tunnel.cleanupRequired; finishOperation(outcome) }
            do {
                guard let port = UInt16(socksPort), port > 1023 else { throw PACError.invalidPort }
                guard !selectedServices.isEmpty else { throw ProxyError.noServices }
                let routes = RouteSet(packs: packs)
                guard !routes.domains.isEmpty else { throw RuntimeError.message("Enable at least one domain before connecting.") }
                let script = try PACGenerator.generate(routes: routes, socksPort: port)
                let bound = try await server.start(script: script)
                pacURL = "http://127.0.0.1:\(bound)/proxy.pac"; serving = true; activeSocksPort = port
                humanInteraction = "keychainAccess"
                try await tunnel.start(connection: connection, port: port,
                    helper: environment.helper, secrets: operationNonInteractive ? NonInteractiveSecrets(base: environment.secrets) : environment.secrets)
                humanInteraction = nil
                while tunnel.state == .connecting || tunnel.state == .reconnecting {
                    try Task.checkCancellation()
                    try await environment.sleep( .milliseconds(100))
                }
                guard tunnel.state == .connected else { throw RuntimeError.message(error ?? "SSH connection failed.") }
                try Task.checkCancellation()
                humanInteraction = "systemAuthorization"
                let available = try environment.services()
                let selected = available.filter { selectedServices.contains($0.id) }
                guard selected.count == selectedServices.count, !selected.isEmpty,
                      Set(selected.map(\.locationID)).count == 1 else { throw ProxyError.noServices }
                proxyTransactionInProgress = true
                do {
                    try await environment.installProxy(ProxyActivation(pacURL: URL(string: pacURL)!,
                        serviceIDs: selectedServices, locationID: selected[0].locationID,
                        runtime: RoutingRecovery(connectionID: connection.id, socksPort: port, pacPort: bound, domains: routes.domains, ownedProcess: tunnel.ownedProcess), allowUserInteraction: !operationNonInteractive))
                } catch { proxyTransactionInProgress = false; throw error }
                proxyTransactionInProgress = false
                if cancellationRequested { throw CancellationError() }
                humanInteraction = nil
                if var saved = configuration {
                    saved.selectedServiceIDs = selectedServices.sorted()
                    saved.networkLocationID = selected[0].locationID
                    try store.save(saved); configuration = saved
                }
                needsRecovery = transaction.needsRecovery
                try await verifyRouting()
            } catch {
                outcome = operationFailure(error)
                self.error = error is CancellationError ? "Connection cancelled." : error.localizedDescription
                if transaction.needsRecovery { routingState = .degraded }
                // A partial proxy apply retains its journal, PAC, and tunnel for recovery.
                if !transaction.needsRecovery {
                    do { try await tunnel.stop() }
                    catch {
                        outcome = .failure(ControlFailure(code: .operationFailed, reason: "processCleanupFailed"))
                        self.error = "SSH cleanup failed; retry Disconnect."; routingReason = "processCleanupFailed"
                    }
                    server.stop(); serving = false; pacURL = ""; activeSocksPort = nil
                    if tunnel.cleanupRequired {
                        routingState = .degraded; routingReason = "processCleanupFailed"
                        status = "SSH cleanup needs attention · retry Disconnect"
                    } else {
                        routingState = .inactive; status = "Connection needs attention · system settings unchanged"
                    }
                } else {
                    status = "Routing needs attention · recovery remains available"
                }
            }
        }
    }

    func reconnectRecoveryImpl() {
        guard !busy, needsRecovery, !serving, let connection = configuredConnection else { return }
        busy = true; error = nil; status = "Reconnecting recorded routes"
        setupTask = Task { [self] in
            var outcome: Result<Void, ControlFailure> = .success(())
            defer { busy = false; setupTask = nil; finishOperation(outcome) }
            do {
                let recovery = try await environment.recoverProxy(connection.id)
                try await recovery.ownedProcess?.stopIfStillOwned()
                try environment.requireAvailable(recovery.socksPort)
                let script = try PACGenerator.generate(routes: RouteSet(domains: recovery.domains), socksPort: recovery.socksPort)
                let bound = try await server.start(script: script, port: recovery.pacPort)
                pacURL = "http://127.0.0.1:\(bound)/proxy.pac"; serving = true; activeSocksPort = recovery.socksPort
                humanInteraction = "keychainAccess"
                try await tunnel.start(connection: connection, port: recovery.socksPort,
                    helper: environment.helper, secrets: operationNonInteractive ? NonInteractiveSecrets(base: environment.secrets) : environment.secrets)
                humanInteraction = nil
                while tunnel.state == .connecting || tunnel.state == .reconnecting {
                    try Task.checkCancellation()
                    try await environment.sleep( .milliseconds(100))
                }
                guard tunnel.state == .connected else { throw RuntimeError.message(error ?? "SSH recovery failed.") }
                try await environment.updateProxyProcess(tunnel.ownedProcess)
                try await verifyRouting()
            } catch {
                outcome = operationFailure(error)
                self.error = error.localizedDescription
                status = "Recovery needs attention · restoration remains available"
                // The durable record and owned system settings are never removed here.
            }
        }
    }

    func verifyRouting() async throws {
        for _ in 0..<20 {
            try Task.checkCancellation()
            if cancellationRequested { throw CancellationError() }
            try await validateNow()
            if routingState == .active { error = nil; return }
            try await environment.sleep(.milliseconds(100))
        }
        throw ProxyError.verificationFailed
    }

    public func refreshServices() {
        guard ownsRuntime else { return }
        if let read = environment.readServices {
            Task { [weak self] in
                do { let services = try await read(); self?.acceptServices(services) }
                catch { self?.error = error.localizedDescription }
            }
        } else {
            do { acceptServices(try environment.services()) } catch { self.error = error.localizedDescription }
        }
    }
    func acceptServices(_ available: [NetworkService]) {
        services = available
        if selectedServices.isEmpty && configuration?.selectedServiceIDs == nil {
            selectedServices = Set(services.filter { $0.isPrimary && ["Ethernet", "IEEE80211"].contains($0.kind) }.map(\.id))
        }
    }
    func networkChanged() {
        guard ownsRuntime, !shutdownStarted else { return }
        validationEpoch += 1
        networkRefreshTask?.cancel()
        networkRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            self?.refreshServices()
            if self?.needsRecovery == true && self?.serving == true { self?.revalidate() }
        }
    }
    public func revalidate() {
        guard ownsRuntime, !proxyTransactionInProgress else { return }
        if environment.validateProxy != nil {
            guard validationTask == nil else { validationAgain = true; return }
            validationTask = Task { [weak self] in
                guard let self else { return }
                defer {
                    validationTask = nil
                    if validationAgain { validationAgain = false; revalidate() }
                }
                do { try await validateNow() }
                catch { if !(error is CancellationError) { validationError(error) } }
            }
        } else {
            do { applyValidation(try inspectValidation()) } catch { validationError(error) }
        }
    }
    func inspectValidation() throws -> RoutingValidation {
        try RoutingValidation.inspect(preferences: environment.preferences(false), services: environment.services(), primary: environment.primary(),
            effectivePAC: environment.effectivePAC(), journal: transaction, pacURL: pacURL)
    }
    func validateNow() async throws {
        let generation = runtimeGeneration
        let epoch = validationEpoch
        let result: RoutingValidation
        if let inspect = environment.validateProxy { result = try await inspect(pacURL) }
        else { result = try inspectValidation() }
        guard generation == runtimeGeneration, !shutdownStarted else { throw CancellationError() }
        guard epoch == validationEpoch else { return } // Retry a stale network snapshot; this is not user cancellation.
        applyValidation(result)
    }
    func applyValidation(_ result: RoutingValidation) {
        services = result.services
        if !server.isReady {
            routingState = .degraded; routingReason = "pacUnavailable"; status = "Routing degraded · PAC unavailable"
        } else if result.valid && tunnelState == .connected {
            routingState = .active; routingReason = nil
            if routingValidationOwnsError { error = nil }
            status = "Connected · restart Safari if pages still look locked"
        } else {
            routingState = .degraded; routingReason = result.reason ?? "sshUnavailable"
            status = "Routing degraded"
            error = "The active network, location, tunnel, or proxy settings no longer match LabRoute. Restore and select the current network service; external settings will not be overwritten."
            routingValidationOwnsError = true
        }
    }
    func validationError(_ failure: Error) {
        routingState = .degraded; routingReason = "verificationFailed"; status = "Routing degraded"
        error = failure.localizedDescription; routingValidationOwnsError = true
    }


    func restoreImpl(quitAfter: Bool = false) {
        guard !busy else { return }
        busy = true; error = nil
        Task { [self] in
            var outcome: Result<Void, ControlFailure> = .success(())
            defer { busy = false; needsRecovery = transaction.needsRecovery || environment.runtimeNeedsRecovery() || tunnel.cleanupRequired; finishOperation(outcome) }
            do {
                proxyTransactionInProgress = true; humanInteraction = "systemAuthorization"
                let recordedProcess: OwnedSSHProcess?
                do {
                    if operationNonInteractive, let restore = environment.restoreProxyWithoutInteraction { recordedProcess = try await restore() }
                    else { recordedProcess = try await environment.restoreProxy() }
                }
                catch { proxyTransactionInProgress = false; throw error }
                proxyTransactionInProgress = false; humanInteraction = nil
                // Explicit disconnect restores owned settings before stopping SSH.
                try await tunnel.stop()
                try await recordedProcess?.stopIfStillOwned()
                try await environment.cleanupRuntime()
                try await environment.completeProxyCleanup()
                server.stop(); serving = false; pacURL = ""; activeSocksPort = nil
                routingState = .inactive; routingReason = nil; error = nil
                status = "Disconnected · prior proxy settings restored"
                record("Disconnected; recovery complete")
                if quitAfter { scheduleShutdown() }
            } catch {
                outcome = operationFailure(error)
                self.error = error.localizedDescription
                routingState = .degraded
                routingReason = "restorationIncomplete"
                status = "Disconnect needs attention · recovery remains available"
                if quitAfter { shutdownRequested = false; quitAwaitingDelivery = false }
            }
        }
    }

    public func quit() { restore(quitAfter: true) }

    func perform(_ body: () throws -> Void) {
        guard !busy, !shutdownRequested else { return }
        busy = true; error = nil
            defer { busy = false; needsRecovery = transaction.needsRecovery || environment.runtimeNeedsRecovery() || tunnel.cleanupRequired }
        do { try body() } catch { self.error = error.localizedDescription }
    }
}
