import Foundation
import LabRouteCore
import LabRouteServices
import CryptoKit

@main
struct ExperimentalCLI {
    @MainActor
    static func main() async {
        var json = false
        var noninteractive = false
        var journal = LabRoutePaths.journal
        do {
            var arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first != "experiment" {
                try await AgentCLI.run(arguments)
                return
            }
            json = arguments.contains("--json")
            noninteractive = arguments.contains("--non-interactive")
            arguments.removeAll { $0 == "--json" || $0 == "--non-interactive" }
            if let index = arguments.firstIndex(of: "--journal"), index + 1 < arguments.count {
                journal = URL(fileURLWithPath: arguments[index + 1])
                arguments.removeSubrange(index...index + 1)
            }
            guard arguments.first == "experiment", arguments.count >= 2 else {
                throw UsageError()
            }
            #if !DEBUG
            guard !["apply", "restore", "serve-pac"].contains(arguments[1]) else { throw UsageError() }
            #endif
            let transaction = ProxyTransaction(journalURL: journal)
            switch arguments[1] {
            case "check-resources" where arguments.count == 2:
                print("Validated \(try RoutePack.defaults().count) bundled route packs.")
            case "inspect" where arguments.count == 2:
                let settings = try SystemProxyPreferences(writable: false).read()
                if json {
                    try printJSON(["version": 1, "ok": true, "serviceCount": settings.count,
                                   "effectivePACEnabled": SystemProxyPreferences.effectivePACURL() != nil,
                                   "recoveryRequired": transaction.needsRecovery])
                } else {
                    print("Enabled services with proxy settings: \(settings.count)")
                    print("Effective PAC enabled: \(SystemProxyPreferences.effectivePACURL() != nil)")
                    print("Restoration record present: \(transaction.needsRecovery)")
                }
            case "services" where arguments.count == 2:
                let services = try SystemProxyPreferences(writable: false).services()
                if json {
                    let configuration = try ConfigurationStore(url: LabRoutePaths.support.appendingPathComponent("configuration.json")).load()
                    let selected = Set(configuration?.selectedServiceIDs ?? [])
                    let snapshots = try SystemProxyPreferences(writable: false).read()
                    try printJSON(["version": 1, "ok": true, "recoveryRequired": FileManager.default.fileExists(atPath: LabRoutePaths.journal.path) || FileManager.default.fileExists(atPath: LabRoutePaths.support.appendingPathComponent("ssh-runtime.json").path),
                                   "services": try services.map { service -> [String: Any] in
                        let dictionary = try snapshots[service.id]?.dictionary() ?? [:]
                        let fingerprint = SHA256.hash(data: try JSONSerialization.data(withJSONObject: ["enabled": snapshots[service.id]?.enabled ?? false, "settings": dictionary], options: [.sortedKeys]))
                        let conflict = ["HTTPEnable", "HTTPSEnable", "FTPEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"].contains { (dictionary[$0] as? NSNumber)?.boolValue == true } ||
                            !(dictionary["ProxyAutoConfigURLString"] as? String ?? "").isEmpty || !(dictionary["ProxyAutoConfigJavaScript"] as? String ?? "").isEmpty
                        return ["id": service.id, "locationID": service.locationID, "isPrimary": service.isPrimary, "selected": selected.contains(service.id), "conflicting": conflict,
                                "settingsSHA256": fingerprint.map { String(format: "%02x", $0) }.joined()]
                    }])
                } else {
                    for service in services { print("\(service.id)\t\(service.name)\t\(service.isPrimary ? "active" : "inactive")") }
                }
            #if DEBUG
            case "apply" where arguments.count >= 4:
                guard let url = URL(string: arguments[2]) else { throw ProxyError.invalidPACURL }
                let preferences = try SystemProxyPreferences(writable: true, allowUserInteraction: !noninteractive)
                let selected = Set(arguments.dropFirst(3))
                let services = try preferences.services().filter { selected.contains($0.id) }
                guard !services.isEmpty, services.count == selected.count,
                      Set(services.map(\.locationID)).count == 1 else { throw ProxyError.noServices }
                try transaction.install(pacURL: url, preferences: preferences, serviceIDs: selected, locationID: services[0].locationID,
                                        verifyEffective: { try waitForEffectivePAC { SystemProxyPreferences.effectivePACURL() == url.absoluteString } })
                if json { try printJSON(["version": 1, "ok": true, "effectiveVerified": true, "recoveryRequired": transaction.needsRecovery]) }
                else { print("Experimental PAC applied. This is NOT fail-closed routing. Restore settings when finished.") }
            case "restore" where arguments.count == 2:
                let record = try transaction.record()
                let ownedProcess = record?.runtime?.ownedProcess
                let ownedURLs = Set(try (record?.applied ?? [:]).values.compactMap { try $0.dictionary()?["ProxyAutoConfigURLString"] as? String })
                if transaction.needsRecovery {
                    try transaction.restore(preferences: SystemProxyPreferences(writable: record?.phase == .applied, allowUserInteraction: !noninteractive), deferCleanup: true,
                                            verifyEffective: { try waitForEffectivePAC { !ownedURLs.contains(SystemProxyPreferences.effectivePACURL() ?? "") } })
                }
                try await ownedProcess?.stopIfStillOwned()
                if transaction.needsRecovery { try transaction.completeCleanup() }
                if json { try printJSON(["version": 1, "ok": true, "effectiveVerified": true, "recoveryRequired": transaction.needsRecovery]) }
                else { print("Restoration complete.") }
            #endif
            case "generate-pac" where arguments.count == 4:
                guard let port = UInt16(arguments[3]) else { throw PACError.invalidPort }
                print(try PACGenerator.generate(routes: RouteSet(domains: [Domain(arguments[2])]), socksPort: port))
            #if DEBUG
            case "serve-pac" where arguments.count == 5:
                guard let socks = UInt16(arguments[3]), let port = UInt16(arguments[4]) else { throw PACError.invalidPort }
                let server = PACServer()
                let script = try PACGenerator.generate(routes: RouteSet(domains: [Domain(arguments[2])]), socksPort: socks)
                let bound = try await server.start(script: script, port: port)
                print("Experimental PAC: http://127.0.0.1:\(bound)/proxy.pac")
                while true { try await Task.sleep(for: .seconds(30)) }
            #endif
            default: throw UsageError()
            }
        } catch {
            if json || noninteractive {
                let code: String
                switch error {
                case ProxyError.authorizationRequired: code = "authorization-required"
                case ProxyError.existingProxy: code = "proxy-conflict"
                case ProxyError.recoveryRequired: code = "recovery-required"
                case ProxyError.noServices: code = "invalid-service-selection"
                case ProxyError.externalChange: code = "external-proxy-edit"
                case ProxyError.verificationFailed: code = "effective-verification-failed"
                default: code = "experimental-command-failed"
                }
                try? printJSON(["version": 1, "ok": false, "errorCode": code,
                                "recoveryRequired": FileManager.default.fileExists(atPath: journal.path)])
                exit(code == "authorization-required" ? 3 : 1)
            }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}

private func printJSON(_ value: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    print(String(decoding: data, as: UTF8.self))
}

private func waitForEffectivePAC(_ ready: () -> Bool) throws {
    let deadline = ProcessInfo.processInfo.systemUptime + 5
    repeat {
        if ready() { return }
        Thread.sleep(forTimeInterval: 0.05)
    } while ProcessInfo.processInfo.systemUptime < deadline
    throw ProxyError.verificationFailed
}

private struct UsageError: Error, LocalizedError {
    var errorDescription: String? {
        """
        LabRoute commands (the app must be running):
          labroute status|connect|disconnect|enable|disable|routes|recover
          labroute route add|enable|disable <domain>
        The app owns SSH; credentials are entered only in its native setup.
        Experimental developer commands:
          labroute experiment services
          labroute experiment inspect
          labroute experiment check-resources
          labroute experiment generate-pac <domain> <socks-port>
          labroute experiment serve-pac <domain> <socks-port> <pac-port-or-0>
          labroute experiment apply http://127.0.0.1:<port>/proxy.pac <service-id> [...]
          labroute experiment restore
        Optional --journal <path> selects an isolated restoration record for tests.
        --json emits structured experimental results; --non-interactive refuses authorization prompts.
        """
    }
}
