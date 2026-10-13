import Foundation
import Darwin
import LabRouteCore

/// Routing snapshot shared with proxy connection threads.
public final class RouteTable: @unchecked Sendable {
    private let lock = NSLock()
    private var routes = RouteSet(domains: [])
    private var socksPort: UInt16?
    public init() {}
    public func update(routes: RouteSet, socksPort: UInt16?) {
        lock.lock(); self.routes = routes; self.socksPort = socksPort; lock.unlock()
    }
    public func resolve(_ host: String) -> RouteResolution {
        lock.lock(); defer { lock.unlock() }
        return RouteResolution(routed: routes.matches(host: host), tunnel: socksPort != nil, socksPort: socksPort)
    }
}

/// Loopback HTTP proxy for terminal tools that ignore PAC (curl, git over
/// HTTPS, pip). Routed domains go through the SSH tunnel, everything else
/// directly. A routed domain never falls back to a direct connection.
/// Hosts and payloads are never logged.
public final class SplitHTTPProxy: @unchecked Sendable {
    public let routes: RouteTable
    private let state = NSLock()
    private var listener: Int32 = -1
    private var stopped = true
    private var active = 0
    private var boundPort: UInt16?
    private let maximumClients: Int
    private let connectTimeout: Duration

    public init(routes: RouteTable = RouteTable(), maximumClients: Int = 64, connectTimeout: Duration = .seconds(10)) {
        self.routes = routes; self.maximumClients = maximumClients; self.connectTimeout = connectTimeout
    }

    public var port: UInt16? { state.lock(); defer { state.unlock() }; return boundPort }

    /// Binds 127.0.0.1:`port` (0 picks a free port) and returns the bound port.
    @discardableResult public func start(port: UInt16) throws -> UInt16 {
        state.lock(); defer { state.unlock() }
        guard stopped else { return boundPort ?? port }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalSocket.posixError() }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian; address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        guard bound == 0, listen(fd, 64) == 0 else {
            Darwin.close(fd); throw RuntimeError.message("Port \(port) is in use; the terminal proxy is unavailable.")
        }
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        listener = fd; stopped = false; boundPort = UInt16(bigEndian: address.sin_port)
        let thread = Thread { [self] in acceptLoop(fd) }
        thread.name = "org.labroute.http-proxy"
        thread.start()
        return boundPort!
    }

    public func stop() {
        state.lock(); stopped = true; boundPort = nil; state.unlock()
    }

    private var isStopped: Bool { state.lock(); defer { state.unlock() }; return stopped }

    private func acceptLoop(_ fd: Int32) {
        defer { Darwin.close(fd) }
        while !isStopped {
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 200) > 0, !isStopped else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            state.lock()
            let admitted = active < maximumClients
            if admitted { active += 1 }
            state.unlock()
            guard admitted else { Darwin.close(client); continue }
            Thread.detachNewThread { [self] in
                defer { Darwin.close(client); state.lock(); active -= 1; state.unlock() }
                serve(client)
            }
        }
    }

    private func serve(_ client: Int32) {
        SocketIO.prepare(client)
        let deadline = ContinuousClock.now + .seconds(10)
        var buffer: [UInt8] = []
        let request: HTTPProxyRequest
        do {
            while true {
                if let parsed = try HTTPProxyRequest.parse(buffer) { request = parsed; break }
                buffer += try SocketIO.readSome(client, deadline: deadline)
            }
        } catch HTTPProxyError.badRequest {
            respond(client, 400, "LabRoute proxy: unsupported request. Use CONNECT or an http:// URL."); return
        } catch { return }
        if request.port == port && ["127.0.0.1", "localhost", "::1"].contains(request.host) {
            respond(client, 400, "LabRoute proxy: refusing to connect to itself."); return
        }

        let resolution = routes.resolve(request.host)
        let upstream: Int32
        var fromUpstream: [UInt8] = []
        do {
            if resolution.routed {
                guard let socksPort = resolution.socksPort else {
                    respond(client, 502, "LabRoute is not connected. \(request.host) is only reachable through the LabRoute tunnel."); return
                }
                (upstream, fromUpstream) = try SOCKS5Client.open(socksPort: socksPort, host: request.host, port: request.port, timeout: connectTimeout)
            } else {
                upstream = try TCPConnector.connect(host: request.host, port: request.port, timeout: connectTimeout)
            }
        } catch {
            respond(client, 502, "LabRoute proxy: " + (error.localizedDescription)); return
        }
        defer { Darwin.close(upstream) }
        let remainder = Array(buffer.dropFirst(request.headLength))
        switch request.kind {
        case .connect:
            guard (try? SocketIO.writeAll(client, Array("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), deadline: deadline)) != nil else { return }
            StreamRelay.run(.init(socket: client), .init(socket: upstream), initialToB: remainder, initialToA: fromUpstream)
        case .forward:
            StreamRelay.run(.init(socket: client), .init(socket: upstream), initialToB: request.upstreamHead + remainder, initialToA: fromUpstream)
        }
    }

    private func respond(_ client: Int32, _ code: Int, _ message: String) {
        let reason = code == 400 ? "Bad Request" : "Bad Gateway"
        let body = message + "\n"
        let response = "HTTP/1.1 \(code) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n" + body
        try? SocketIO.writeAll(client, Array(response.utf8), deadline: ContinuousClock.now + .seconds(2))
    }
}
