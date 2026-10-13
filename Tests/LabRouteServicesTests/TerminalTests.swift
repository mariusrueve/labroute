import Foundation
import Darwin
import Testing
import LabRouteCore
@testable import LabRouteServices

@MainActor private func fixture() throws -> (FixtureEnvironment, ApplicationController) {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    return (fixture, ApplicationController(environment: environment, startIPC: false))
}
@MainActor private func settled(_ controller: ApplicationController, _ response: ControlResponse) async throws {
    let id = try #require(response.operation?.id)
    for _ in 0..<1000 {
        if controller.execute(ControlRequest(command: "operation", id: id)).operation?.terminal == true { return }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw RuntimeError.message("Test operation did not settle")
}
@MainActor private func resolve(_ controller: ApplicationController, _ host: String) -> RouteResolution? {
    controller.execute(ControlRequest(command: "route.resolve", domain: host)).resolution
}

@Test @MainActor func routeResolveFollowsTunnelAndRoutes() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    #expect(resolve(controller, "git.selected.labroute.test") == RouteResolution(routed: true, tunnel: false, socksPort: nil))
    #expect(controller.execute(ControlRequest(command: "route.resolve")).errorCode == .invalidRequest)
    try await settled(controller, controller.execute(ControlRequest(.connect)))
    #expect(resolve(controller, "git.selected.labroute.test") == RouteResolution(routed: true, tunnel: true, socksPort: 1080))
    #expect(resolve(controller, "SELECTED.labroute.test.")?.usable == true)
    #expect(resolve(controller, "github.com") == RouteResolution(routed: false, tunnel: true, socksPort: 1080))
    controller.handleSleep()
    #expect(resolve(controller, "git.selected.labroute.test")?.usable == false)
    controller.handleWake()
    #expect(resolve(controller, "git.selected.labroute.test")?.usable == true)
    try await settled(controller, controller.execute(ControlRequest(.disconnect)))
    #expect(resolve(controller, "git.selected.labroute.test")?.tunnel == false)
}

private func socketPair() throws -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw LocalSocket.posixError() }
    return (fds[0], fds[1])
}
private func readAll(_ fd: Int32) -> [UInt8] {
    var result: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    while true {
        let count = read(fd, &chunk, chunk.count)
        if count <= 0 { return result }
        result += chunk.prefix(count)
    }
}
private func writeAndClose(_ fd: Int32, _ bytes: [UInt8]) {
    _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
    var offset = 0
    while offset < bytes.count {
        let count = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset) }
        if count <= 0 { break }
        offset += count
    }
    shutdown(fd, SHUT_WR)
}

@Test func relayCopiesBothWaysAndPropagatesHalfClose() async throws {
    let (clientOuter, clientInner) = try socketPair()
    let (serverInner, serverOuter) = try socketPair()
    defer { [clientOuter, clientInner, serverInner, serverOuter].forEach { close($0) } }
    let relay = Thread { StreamRelay.run(.init(socket: clientInner), .init(socket: serverInner), initialToA: [9]) }
    relay.start()
    let upload = [UInt8]((0..<200_000).map { UInt8($0 % 251) })
    let download = [UInt8](repeating: 7, count: 150_000)
    async let uploaded: [UInt8] = Task.detached { readAll(serverOuter) }.value
    async let downloaded: [UInt8] = Task.detached { readAll(clientOuter) }.value
    Thread.detachNewThread { writeAndClose(clientOuter, upload) }
    Thread.detachNewThread { writeAndClose(serverOuter, download) }
    #expect(await uploaded == upload)
    #expect(await downloaded == [9] + download)
}

/// Minimal loopback SOCKS5 server: accepts one CONNECT, records the target, then echoes.
private final class FakeSOCKSServer: @unchecked Sendable {
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var _target: (String, UInt16)?
    var target: (String, UInt16)? { lock.lock(); defer { lock.unlock() }; return _target }
    init(replyCode: UInt8 = 0, socks: Bool = true) throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) } }
        listen(fd, 4)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) } }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            defer { close(client) }
            func take(_ count: Int) -> [UInt8] {
                var buffer = [UInt8](repeating: 0, count: count), offset = 0
                while offset < count {
                    let n = buffer.withUnsafeMutableBytes { read(client, $0.baseAddress!.advanced(by: offset), count - offset) }
                    if n <= 0 { return [] }
                    offset += n
                }
                return buffer
            }
            if !socks {
                lock.lock(); _target = ("direct", 0); lock.unlock()
                var chunk = [UInt8](repeating: 0, count: 4096)
                while true { let n = read(client, &chunk, chunk.count); if n <= 0 { return }; _ = write(client, chunk, n) }
            }
            guard take(3) == [5, 1, 0] else { return }
            _ = write(client, [5, 0], 2)
            let head = take(5)
            guard head.count == 5, head[3] == 3 else { return }
            let name = take(Int(head[4])), portBytes = take(2)
            lock.lock(); _target = (String(decoding: name, as: UTF8.self), UInt16(portBytes[0]) << 8 | UInt16(portBytes[1])); lock.unlock()
            let reply: [UInt8] = [5, replyCode, 0, 1, 127, 0, 0, 1, 0, 0]
            _ = write(client, reply, reply.count)
            guard replyCode == 0 else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            while true {
                let n = read(client, &chunk, chunk.count)
                if n <= 0 { return }
                _ = write(client, chunk, n)
            }
        }
    }
    deinit { close(fd) }
}

@Test func socksClientConnectsByHostname() throws {
    let server = try FakeSOCKSServer()
    let tunnel = try SOCKS5Client.open(socksPort: server.port, host: "gerrit.example.org", port: 29418, timeout: .seconds(5))
    defer { close(tunnel.fd) }
    #expect(server.target?.0 == "gerrit.example.org" && server.target?.1 == 29418)
    let deadline = ContinuousClock.now + .seconds(5)
    try SocketIO.writeAll(tunnel.fd, Array("ping".utf8), deadline: deadline)
    var echoed: [UInt8] = []
    while echoed.count < 4 { echoed += try SocketIO.readSome(tunnel.fd, deadline: deadline) }
    #expect(echoed == Array("ping".utf8))
}

@Test func socksClientReportsTunnelFailures() throws {
    let server = try FakeSOCKSServer(replyCode: 4)
    #expect(throws: SOCKS5Error.failed(4)) { try SOCKS5Client.open(socksPort: server.port, host: "down.example.org", port: 22, timeout: .seconds(5)) }
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("labroute-test-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Test func sshConfigWriterRefusesForeignFilesAndSkipsUnchanged() async throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appendingPathComponent("labroute/config")
    let text = SSHConfigGenerator.header + "\nHost a\n"
    #expect(try await SSHConfigWriter.write(text, to: target, verify: { _ in }))
    #expect(try await !SSHConfigWriter.write(text, to: target, verify: { _ in Issue.record("unchanged content must not be verified") }))
    // A failed verification keeps the previous file.
    await #expect(throws: RuntimeError.self) {
        try await SSHConfigWriter.write(text + "Bad\n", to: target, verify: { _ in throw RuntimeError.message("rejected") })
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == text)
    try "Host mine\n".write(to: target, atomically: true, encoding: .utf8)
    await #expect(throws: RuntimeError.self) { try await SSHConfigWriter.write(text, to: target, verify: { _ in }) }
    #expect(try String(contentsOf: target, encoding: .utf8) == "Host mine\n")
}

@Test func hookLinesAreIdempotentBackedUpAndRemovable() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let config = root.appendingPathComponent("config")
    let line = "Include ~/.ssh/labroute/config"
    let original = "Host *\n  UseKeychain yes\n"
    try original.write(to: config, atomically: true, encoding: .utf8)
    #expect(HookLines.state(of: config, line: line, mustPrecedeHosts: true) == .missing)
    try HookLines.add(line, to: config, prepend: true)
    try HookLines.add(line, to: config, prepend: true)
    let added = try String(contentsOf: config, encoding: .utf8)
    #expect(added == HookLines.marker + "\n" + line + "\n\n" + original)
    #expect(HookLines.state(of: config, line: line, mustPrecedeHosts: true) == .installed)
    #expect(try String(contentsOfFile: config.path + ".labroute-backup", encoding: .utf8) == HookLines.marker + "\n" + line + "\n\n" + original)
    try HookLines.remove(line, from: config)
    #expect(try String(contentsOf: config, encoding: .utf8) == original)

    try (original + line + "\n").write(to: config, atomically: true, encoding: .utf8)
    #expect(HookLines.state(of: config, line: line, mustPrecedeHosts: true) == .misplaced)

    let zshrc = root.appendingPathComponent("zshrc")
    let shell = "[ -x '/x/labroute' ] && eval \"$('/x/labroute' env)\""
    try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
    try HookLines.add(shell, to: zshrc, prepend: false)
    #expect(try String(contentsOf: zshrc, encoding: .utf8) == "export A=1\n\n" + HookLines.marker + "\n" + shell + "\n")
    try HookLines.remove(shell, from: zshrc)
    #expect(try String(contentsOf: zshrc, encoding: .utf8) == "export A=1\n")

    let link = root.appendingPathComponent("linked")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: zshrc)
    #expect(HookLines.state(of: link, line: shell, mustPrecedeHosts: false) == .symlink)
    #expect(throws: RuntimeError.self) { try HookLines.add(shell, to: link, prepend: false) }
}

@Test @MainActor func controllerWritesManagedSSHConfigInsideFixture() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    #expect(controller.saveSSH(SSHIntegration(hosts: [SSHHostEntry(aliases: ["git"], hostname: "git.selected.labroute.test")])))
    await controller.sshSyncTask?.value
    let managed = fixture.root.appendingPathComponent("home/.ssh/labroute/config")
    let text = try String(contentsOf: managed, encoding: .utf8)
    #expect(text.contains("Host git git.selected.labroute.test"))
    #expect(text.contains("Match host \"selected.labroute.test,*.selected.labroute.test,!ssh.labroute.test\""))
    #expect(!controller.saveSSH(SSHIntegration(hosts: [SSHHostEntry(aliases: ["bad alias"], hostname: "x.example.org")])))
    controller.setSSHHook(true)
    #expect(controller.sshHookState == .installed)
    #expect(try String(contentsOf: fixture.root.appendingPathComponent("home/.ssh/config"), encoding: .utf8).contains(controller.sshIncludeLine))
}

private func exchange(_ port: UInt16, _ request: String, expect count: Int) throws -> String {
    let fd = try TCPConnector.connect(host: "127.0.0.1", port: port, timeout: .seconds(5))
    defer { close(fd) }
    let deadline = ContinuousClock.now + .seconds(5)
    try SocketIO.writeAll(fd, Array(request.utf8), deadline: deadline)
    var received: [UInt8] = []
    while received.count < count, let more = try? SocketIO.readSome(fd, deadline: deadline) { received += more }
    return String(decoding: received, as: UTF8.self)
}

@Test func splitProxyRoutesThroughTunnelDirectOrFailsFast() throws {
    let proxy = SplitHTTPProxy(connectTimeout: .seconds(5))
    let port = try proxy.start(port: 0)
    defer { proxy.stop() }
    let socks = try FakeSOCKSServer()
    proxy.routes.update(routes: RouteSet(domains: [try Domain("lab.example.org")]), socksPort: socks.port)
    let established = "HTTP/1.1 200 Connection Established\r\n\r\n"
    let routed = try exchange(port, "CONNECT gerrit.lab.example.org:29418 HTTP/1.1\r\n\r\nhello", expect: established.utf8.count + 5)
    #expect(routed == established + "hello")
    #expect(socks.target?.0 == "gerrit.lab.example.org" && socks.target?.1 == 29418)

    let echo = try FakeSOCKSServer(socks: false)
    let direct = try exchange(port, "CONNECT 127.0.0.1:\(echo.port) HTTP/1.1\r\n\r\nplain", expect: established.utf8.count + 5)
    #expect(direct == established + "plain")

    proxy.routes.update(routes: RouteSet(domains: [try Domain("lab.example.org")]), socksPort: nil)
    let refused = try exchange(port, "CONNECT gerrit.lab.example.org:443 HTTP/1.1\r\n\r\n", expect: 12)
    #expect(refused.hasPrefix("HTTP/1.1 502") && refused.contains("not connected"))
    #expect(try exchange(port, "GET /x HTTP/1.1\r\n\r\n", expect: 12).hasPrefix("HTTP/1.1 400"))
    #expect(try exchange(port, "CONNECT 127.0.0.1:\(port) HTTP/1.1\r\n\r\n", expect: 12).hasPrefix("HTTP/1.1 400"))
}

@Test func splitProxyForwardsPlainHTTPInOriginForm() throws {
    let proxy = SplitHTTPProxy(connectTimeout: .seconds(5))
    let port = try proxy.start(port: 0)
    defer { proxy.stop() }
    let echo = try FakeSOCKSServer(socks: false)
    let expected = "GET /hook HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\n\r\n"
    let reply = try exchange(port, "GET http://127.0.0.1:\(echo.port)/hook HTTP/1.1\r\nHost: 127.0.0.1\r\nProxy-Connection: keep-alive\r\n\r\n", expect: expected.utf8.count)
    #expect(reply == expected)
}

@Test @MainActor func controllerKeepsProxyRoutesInSyncWithTunnel() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    controller.startHTTPProxy()
    func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<500 { if condition() { return }; try await Task.sleep(for: .milliseconds(2)) }
        Issue.record("condition not reached")
    }
    try await waitFor { controller.httpProxy.routes.resolve("a.selected.labroute.test") == RouteResolution(routed: true, tunnel: false, socksPort: nil) }
    try await settled(controller, controller.execute(ControlRequest(.connect)))
    try await waitFor { controller.httpProxy.routes.resolve("a.selected.labroute.test").usable }
    controller.handleSleep()
    try await waitFor { !controller.httpProxy.routes.resolve("a.selected.labroute.test").usable }
    controller.handleWake()
    try await settled(controller, controller.execute(ControlRequest(.disconnect)))
    try await waitFor { !controller.httpProxy.routes.resolve("a.selected.labroute.test").tunnel }
}

@Test func connectorFallsBackAcrossAddressFamilies() throws {
    // "localhost" resolves to ::1 and 127.0.0.1; only IPv4 listens here.
    let echo = try FakeSOCKSServer(socks: false)
    let start = ContinuousClock.now
    let fd = try TCPConnector.connect(host: "localhost", port: echo.port, timeout: .seconds(5))
    close(fd)
    #expect(ContinuousClock.now - start < .seconds(2))
}

@Test func shellHookReplacesOutdatedLines() throws {
    let root = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: root) }
    let files = TerminalFiles.fixture(root: root)
    let old = files.legacyShellLines[1]
    try FileManager.default.createDirectory(at: files.zshrc.deletingLastPathComponent(), withIntermediateDirectories: true)
    try ("export A=1\n\n" + HookLines.marker + "\n" + old + "\n").write(to: files.zshrc, atomically: true, encoding: .utf8)
    #expect(HookLines.state(of: files.zshrc, line: files.shellLine, legacy: files.legacyShellLines, mustPrecedeHosts: false) == .outdated)
    try HookLines.add(files.shellLine, to: files.zshrc, prepend: false, replacing: files.legacyShellLines)
    #expect(try String(contentsOf: files.zshrc, encoding: .utf8) == "export A=1\n\n" + HookLines.marker + "\n" + files.shellLine + "\n")
    #expect(files.shellLine.contains("add-zsh-hook precmd"))
    try HookLines.remove(files.shellLine, from: files.zshrc, legacy: files.legacyShellLines)
    #expect(try String(contentsOf: files.zshrc, encoding: .utf8) == "export A=1\n")
}
