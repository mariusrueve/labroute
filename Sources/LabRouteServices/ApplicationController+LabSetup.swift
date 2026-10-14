import Foundation
import LabRouteCore

/// Lab setup files: colleagues share the server, their own domains and ssh hosts.
@MainActor extension ApplicationController {
    public func labSetupData() throws -> Data {
        guard let configuration, let setup = LabSetup(configuration) else { throw RuntimeError.message("Set up SSH before exporting a lab setup.") }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(setup)
    }

    /// Only adds what is missing: existing domains, hosts, gateway aliases and a
    /// verified connection are never changed.
    @discardableResult public func importLabSetup(_ data: Data) -> Bool {
        do {
            guard !busy, !serving, !needsRecovery, var candidate = configuration else {
                throw RuntimeError.message("Disconnect before importing a lab setup.")
            }
            guard data.count <= 65536, let setup = try? JSONDecoder().decode(LabSetup.self, from: data) else { throw LabSetupError.invalid }
            try setup.validate()
            var updated = packs
            for (pack, domains) in [("internal", setup.internalDomains), ("custom", setup.customDomains)] {
                for domain in domains where !updated.flatMap(\.routes).contains(where: { $0.domain == domain }) {
                    updated = try RouteEditing.apply("add", domain: domain.value, packID: pack, to: updated)
                }
            }
            var ssh = sshIntegration
            for host in setup.sshHosts where !ssh.hosts.contains(where: { $0.hostname.lowercased() == host.hostname.lowercased() }) {
                ssh.hosts.append(SSHHostEntry(aliases: host.aliases, hostname: host.hostname.lowercased(), port: host.port,
                                              user: configuredConnection?.username))
            }
            if ssh.gateway.aliases.isEmpty { ssh.gateway.aliases = setup.gatewayAliases }
            // Validate everything before saving anything, so a bad file changes nothing.
            candidate.packs = updated; candidate.ssh = ssh
            try ConfigurationStore.validate(candidate)
            try saveRoutes(updated)
            guard saveSSH(ssh) else { return false }
            if configuredConnection == nil {
                institution = setup.institution; hostname = setup.hostname; sshPort = String(setup.port)
            }
            record("Lab setup imported")
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
}
