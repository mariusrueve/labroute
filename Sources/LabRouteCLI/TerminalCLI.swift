import Foundation
import Darwin
import LabRouteCore
import LabRouteServices

/// Terminal integration. `proxy` runs as an ssh ProxyCommand, so its stdout
/// carries the ssh stream: messages go to stderr only.
enum TerminalCLI {
    static func run(_ args: [String]) -> Never {
        switch args.first {
        case "proxy" where args.count == 3 && args[1] == "--check":
            exit(resolve(args[2])?.usable == true ? 0 : 1)
        case "proxy" where args.count == 3:
            guard let port = UInt16(args[2]), port > 0 else { fail("Usage: labroute proxy HOST PORT", code: 2) }
            proxy(host: args[1], port: port)
        case "env" where args.count == 1:
            printEnvironment()
        default:
            fail("Usage: labroute proxy --check HOST | labroute proxy HOST PORT | labroute env", code: 2)
        }
    }

    static func request(_ request: ControlRequest, timeout: Int) -> ControlResponse? {
        guard let data = try? JSONEncoder().encode(request),
              let reply = try? LocalSocket.request(data, timeoutSeconds: timeout),
              let response = try? JSONDecoder().decode(ControlResponse.self, from: reply),
              response.version == 2, response.success else { return nil }
        return response
    }

    /// nil when the app is not running, too old, or the request failed: callers treat that as "not connected".
    static func resolve(_ host: String) -> RouteResolution? {
        request(ControlRequest(command: AppCommand.routeResolve.rawValue, domain: host), timeout: 1)?.resolution
    }

    static func proxy(host: String, port: UInt16) -> Never {
        guard let resolution = resolve(host) else {
            if request(ControlRequest(.status), timeout: 1) != nil { fail("The running LabRoute app is too old for terminal routing. Update it.") }
            fail("LabRoute is not running. ssh uses its fallback route on the next connection.")
        }
        guard resolution.routed else { fail("\(host) is not a routed domain in LabRoute.") }
        guard resolution.usable, let socksPort = resolution.socksPort else {
            fail("LabRoute is not connected. Connect it, or retry: ssh uses its fallback route on the next connection.")
        }
        let tunnel: (fd: Int32, leftover: [UInt8])
        do { tunnel = try SOCKS5Client.open(socksPort: socksPort, host: host, port: port) }
        catch { fail("\(host) port \(port) through the LabRoute tunnel: " + error.localizedDescription) }
        signal(SIGPIPE, SIG_IGN)
        StreamRelay.run(.init(read: STDIN_FILENO, write: STDOUT_FILENO), .init(socket: tunnel.fd), initialToA: tunnel.leftover)
        exit(0)
    }

    static func printEnvironment() -> Never {
        // Prints nothing unless the app's HTTP proxy is listening, so shells never get a dead proxy.
        guard let port = request(ControlRequest(.status), timeout: 1)?.httpProxyPort else { exit(0) }
        let proxy = "http://127.0.0.1:\(port)"
        let noProxy = "localhost,127.0.0.1,::1"
        print("export http_proxy=\(proxy) https_proxy=\(proxy) HTTP_PROXY=\(proxy) HTTPS_PROXY=\(proxy) no_proxy=\(noProxy) NO_PROXY=\(noProxy)")
        exit(0)
    }

    static func fail(_ message: String, code: Int32 = 1) -> Never {
        FileHandle.standardError.write(Data(("labroute: " + message + "\n").utf8))
        exit(code)
    }
}
