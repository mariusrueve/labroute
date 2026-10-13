import Combine
import Foundation
import LabRouteCore

/// Managed ssh config and the hook lines in ~/.ssh/config and ~/.zshrc.
@MainActor extension ApplicationController {
    public var sshIncludeLine: String { environment.terminal.includeLine }
    public var shellHookLine: String { environment.terminal.shellLine }

    public func refreshTerminalHooks() {
        sshHookState = HookLines.state(of: environment.terminal.userSSHConfig, line: sshIncludeLine, mustPrecedeHosts: true)
        shellHookState = HookLines.state(of: environment.terminal.zshrc, line: shellHookLine,
                                         legacy: environment.terminal.legacyShellLines, mustPrecedeHosts: false)
    }

    @discardableResult public func saveSSHHost(_ host: SSHHostEntry) -> Bool {
        var updated = sshIntegration
        if let index = updated.hosts.firstIndex(where: { $0.id == host.id }) { updated.hosts[index] = host } else { updated.hosts.append(host) }
        return saveSSH(updated)
    }

    /// Whether ssh to this host can use the tunnel: its HostName lies in a custom routed domain.
    public func sshHostRouted(_ host: SSHHostEntry) -> Bool {
        host.hostname.lowercased() != configuredConnection?.hostname.lowercased()
            && RouteSet(domains: configuration?.customDomains ?? []).matches(host: host.hostname)
    }

    public func removeSSHHost(_ id: UUID) {
        var updated = sshIntegration
        updated.hosts.removeAll { $0.id == id }
        saveSSH(updated)
    }

    @discardableResult public func saveSSHGateway(_ gateway: SSHGateway) -> Bool {
        var updated = sshIntegration
        updated.gateway = gateway
        return saveSSH(updated)
    }

    @discardableResult func saveSSH(_ updated: SSHIntegration) -> Bool {
        do {
            guard !busy, var saved = configuration else { throw RuntimeError.message("Wait for the current operation to finish.") }
            try updated.gateway.validate()
            for host in updated.hosts { try host.validate() }
            saved.ssh = updated
            try store.save(saved)
            configuration = saved; sshIntegration = updated; error = nil
            record("SSH hosts saved")
            scheduleSSHSync()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func scheduleSSHSync() {
        sshSyncTask?.cancel()
        sshSyncTask = Task { [weak self] in await self?.syncSSHConfig() }
    }

    func syncSSHConfig() async {
        guard let configuration, let ssh = configuration.ssh else {
            sshConfigStatus = "Add a host or gateway alias to generate the ssh configuration."; return
        }
        guard let connection = configuredConnection else { sshConfigStatus = "Complete SSH setup first; it defines the jump host."; return }
        let files = environment.terminal
        do {
            let text = try SSHConfigGenerator.render(connection: connection, integration: ssh,
                customDomains: configuration.customDomains, labroutePath: files.labroutePath)
            let aliases = [SSHGateway.alias] + ssh.gateway.aliases + ssh.hosts.map { $0.aliases.first ?? $0.hostname }
            let changed = try await SSHConfigWriter.write(text, to: files.managedSSHConfig, verify: environment.verifySSHConfig(aliases))
            guard !Task.isCancelled else { return }
            if changed { record("SSH configuration written") }
            sshConfigStatus = configuration.customDomains.isEmpty
                ? "No custom routed domains: hosts always use the jump host. Add your internal domain above."
                : "SSH configuration is up to date."
        } catch {
            guard !Task.isCancelled else { return }
            sshConfigStatus = "SSH configuration not updated: " + error.localizedDescription
        }
    }

    public func setSSHHook(_ installed: Bool) {
        let files = environment.terminal
        do {
            if installed {
                try HookLines.add(sshIncludeLine, to: files.userSSHConfig, prepend: true)
                record("SSH Include line added")
                verifySSHHook()
            } else {
                try HookLines.remove(sshIncludeLine, from: files.userSSHConfig)
                record("SSH Include line removed")
            }
            error = nil
        } catch { self.error = error.localizedDescription }
        refreshTerminalHooks()
    }

    public func setShellHook(_ installed: Bool) {
        let files = environment.terminal
        do {
            if installed { try HookLines.add(shellHookLine, to: files.zshrc, prepend: false, replacing: files.legacyShellLines); record("Shell line added") }
            else { try HookLines.remove(shellHookLine, from: files.zshrc, legacy: files.legacyShellLines); record("Shell line removed") }
            error = nil
        } catch { self.error = error.localizedDescription }
        refreshTerminalHooks()
    }

    /// Confirms through the user's real config that the first routed host gets a LabRoute route.
    func verifySSHHook() {
        guard let host = sshIntegration.hosts.first?.aliases.first ?? sshIntegration.hosts.first?.hostname else { return }
        Task { [weak self] in
            guard let self, let output = await self.environment.effectiveSSH(host) else { return }
            let routed = output.split(separator: "\n").contains { $0.hasPrefix("proxyjump ") || $0.hasPrefix("proxycommand ") }
            self.sshConfigStatus = routed ? "Verified: ssh \(host) uses LabRoute's routes."
                : "ssh \(host) does not use LabRoute's routes yet. Is its HostName inside a custom routed domain?"
        }
    }

    /// The terminal proxy runs while the app runs, connected or not, so shells
    /// that exported it keep working; routed hosts fail fast while disconnected.
    func startHTTPProxy() {
        if let port = environment.httpProxyPort {
            do {
                let bound = try httpProxy.start(port: port)
                httpProxyStatus = "Terminal proxy: http://127.0.0.1:\(bound)"
            } catch { httpProxyStatus = error.localizedDescription }
        }
        // Read after the run loop turn, when serving, tunnel state and the SOCKS port are all updated.
        routeObserver = Publishers.CombineLatest3($packs, $tunnelState, $serving)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.updateHTTPProxyRoutes() }
    }

    func updateHTTPProxyRoutes() {
        let ready = serving && tunnelState == .connected
        httpProxy.routes.update(routes: RouteSet(packs: packs), socksPort: ready ? activeSocksPort : nil)
    }
}
