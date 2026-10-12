import Foundation
import AppKit
import LabRouteCore
import LabRouteServices

@MainActor enum AgentCLI {
    static func run(_ raw: [String]) async throws {
        var args = raw
        let json = takeFlag("--json", &args), wait = takeFlag("--wait", &args)
        let nonInteractive = takeFlag("--non-interactive", &args)
        let newInstance = takeFlag("--new-instance", &args)
        var socket = LocalSocket.control
        var fixtureID: String?
        func option(_ name: String) throws -> String? {
            guard let i = args.firstIndex(of: name) else { return nil }
            guard i + 1 < args.count else { throw CLIError(.invalidRequest, "Missing option value") }
            let value = args[i + 1]; args.removeSubrange(i...i+1); return value
        }
        do {
            let timeoutText = try option("--timeout") ?? "30"
            guard let timeout = Double(timeoutText), timeout.isFinite, timeout > 0, timeout <= 300 else { throw CLIError(.invalidRequest, "Timeout must be 0–300 seconds, exclusive of zero") }
            if let fixture = try option("--fixture") {
                #if DEBUG
                fixtureID = fixture
                socket = try FixturePaths.root(fixture).appendingPathComponent("control.sock")
                #else
                _ = fixture
                throw CLIError(.invalidRequest, "Fixture mode is unavailable in release builds")
                #endif
            }
            let pack = try option("--pack")
            if args.prefix(2) == ["app", "launch"] {
                guard let path = try option("--path"), args == ["app", "launch"] else { throw CLIError(.invalidRequest, "Use app launch --path <LabRoute.app>") }
                let url = URL(fileURLWithPath: path)
                guard let bundle = Bundle(url: url), bundle.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "LabRouteApp",
                      ["org.labroute.experimental", "org.labroute.development"].contains(bundle.bundleIdentifier ?? "") else { throw CLIError(.invalidRequest, "Not a LabRoute application bundle") }
                if fixtureID != nil && bundle.bundleIdentifier != "org.labroute.development" { throw CLIError(.invalidRequest, "Fixture launch requires the development app") }
                if fixtureID == nil && bundle.bundleIdentifier == "org.labroute.development" { throw CLIError(.invalidRequest, "Launch the development app with --fixture UUID") }
                let configuration = NSWorkspace.OpenConfiguration(); configuration.activates = false
                if let fixtureID { configuration.arguments = ["--fixture", fixtureID] }
                if nonInteractive { configuration.arguments.append("--non-interactive") }
                configuration.createsNewApplicationInstance = fixtureID != nil || newInstance
                let application = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
                let deadline = ContinuousClock.now + .seconds(timeout)
                while ContinuousClock.now < deadline {
                    if let response = try? await send(ControlRequest(.status), socket: socket), response.success {
                        if newInstance && response.status?.ownerPID != application.processIdentifier { throw CLIError(.busy, "Another runtime owner won application startup") }
                        emit(response, json: json); return
                    }
                    try await Task.sleep(for: .milliseconds(100))
                }
                throw CLIError(.timeout, "Application readiness timed out")
            }
            var request: ControlRequest
            if args.count == 1, let command = AppCommand(rawValue: args[0]) { request = ControlRequest(command) }
            else if args.count == 3, args[0] == "route", ["add", "enable", "disable"].contains(args[1]) {
                request = ControlRequest(command: "route." + args[1], domain: args[2], pack: pack)
            } else if args.count == 3, args[0] == "pack", ["enable", "disable"].contains(args[1]) {
                request = ControlRequest(command: "pack.set", id: args[2], enabled: args[1] == "enable")
            } else if args.count >= 3, args.prefix(2) == ["services", "select"] {
                request = ControlRequest(command: "services.set", serviceIDs: Array(args.dropFirst(2)))
            } else if args.count == 4, args.prefix(2) == ["preferences", "set"], ["true", "false"].contains(args[3]) {
                request = ControlRequest(command: "preference.set", id: args[2], enabled: args[3] == "true")
            } else if args.count == 2, ["operation", "cancel"].contains(args[0]) {
                request = ControlRequest(command: args[0], id: args[1])
            } else { throw CLIError(.invalidRequest, "Use status|services|routes|preferences|diagnostics|connect|disconnect|recover|cancel|quit; route add|enable|disable DOMAIN [--pack ID]; pack enable|disable ID; services select ID...; preferences set autoConnect|launchAtLogin true|false; operation ID; app launch --path APP. Options: --json --wait --timeout SECONDS") }
            request.nonInteractive = nonInteractive ? true : nil
            let deadline = ContinuousClock.now + .seconds(timeout)
            var response = try await send(request, socket: socket)
            if wait, let operation = response.operation, !operation.terminal {
                while response.operation?.terminal == false {
                    guard ContinuousClock.now < deadline else {
                        response.success = false; response.errorCode = .timeout
                        response.message = "Wait timed out; operation remains active"
                        emit(response, json: json); exit(4)
                    }
                    try await Task.sleep(for: .milliseconds(50))
                    response = try await send(ControlRequest(command: "operation", id: operation.id), socket: socket)
                }
            }
            emit(response, json: json)
            if !response.success { exit(exitCode(response.errorCode)) }
        } catch let error as CLIError {
            var response = ControlResponse(success: false, message: error.message); response.errorCode = error.code
            emit(response, json: json); exit(exitCode(error.code))
        } catch {
            var response = ControlResponse(success: false, message: "LabRoute is not running, unavailable, or returned an invalid response")
            response.errorCode = .unavailable; emit(response, json: json); exit(3)
        }
    }
    static func send(_ request: ControlRequest, socket: URL) async throws -> ControlResponse {
        let data = try JSONEncoder().encode(request)
        return try await Task.detached {
            let response = try JSONDecoder().decode(ControlResponse.self, from: LocalSocket.request(data, at: socket, timeoutSeconds: 5))
            guard response.version == 2 else { throw CLIError(.unsupportedVersion, "Update the app and CLI together") }
            return response
        }.value
    }
    static func takeFlag(_ flag: String, _ args: inout [String]) -> Bool {
        guard let i = args.firstIndex(of: flag) else { return false }; args.remove(at: i); return true
    }
    static func emit(_ response: ControlResponse, json: Bool) {
        if json {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            if let data = try? encoder.encode(response) { print(String(decoding: data, as: UTF8.self)) }
        } else {
            print(response.message)
            if let status = response.status { print("SSH: \(status.tunnel.rawValue); routing: \(status.routing.rawValue)") }
            if let operation = response.operation { print("\(operation.id): \(operation.phase.rawValue)") }
            if let services = response.services { for service in services { print("\(service.id)\t\(service.name)\tselected=\(service.selected)") } }
            if let routes = response.routes { for pack in routes { print("\(pack.id): \(pack.enabled)"); for route in pack.routes { print("  \(route.domain.value): \(route.enabled)") } } }
            if let preferences = response.preferences { for key in preferences.keys.sorted() { print("\(key): \(preferences[key]!)") } }
            if let events = response.events { events.forEach { print($0) } }
        }
    }
    static func exitCode(_ code: ControlErrorCode?) -> Int32 {
        switch code { case .invalidRequest, .unsupportedVersion: 2; case .unavailable: 3; case .timeout: 4; case .humanInteractionRequired: 5; default: 1 }
    }
}
private struct CLIError: Error { let code: ControlErrorCode; let message: String; init(_ code: ControlErrorCode, _ message: String) { self.code = code; self.message = message } }
