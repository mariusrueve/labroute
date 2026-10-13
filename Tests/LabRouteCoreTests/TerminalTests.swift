import Foundation
import Testing
@testable import LabRouteCore

@Test func socksConnectRequestUsesRemoteDNS() throws {
    let request = try SOCKS5.connectRequest(host: "gerrit.example.org", port: 29418)
    #expect(Array(request.prefix(5)) == [5, 1, 0, 3, 18])
    #expect(Array(request.dropFirst(5).prefix(18)) == Array("gerrit.example.org".utf8))
    #expect(Array(request.suffix(2)) == [0x72, 0xea])
}

@Test(arguments: ["", String(repeating: "a", count: 256), "bad host", "tab\there"])
func socksRejectsInvalidTargets(host: String) {
    #expect(throws: SOCKS5Error.invalidTarget) { try SOCKS5.connectRequest(host: host, port: 22) }
}

@Test func socksRejectsPortZero() {
    #expect(throws: SOCKS5Error.invalidTarget) { try SOCKS5.connectRequest(host: "example.org", port: 0) }
}

@Test func socksGreetingParsing() {
    #expect(SOCKS5.parseGreeting([5]) == .needMore)
    #expect(SOCKS5.parseGreeting([5, 0]) == .accepted)
    #expect(SOCKS5.parseGreeting([5, 0xff]) == .rejected)
}

@Test func socksReplyParsing() {
    let ipv4: [UInt8] = [5, 0, 0, 1, 127, 0, 0, 1, 0, 80]
    #expect(SOCKS5.parseReply(Array(ipv4.prefix(7))) == .needMore)
    #expect(SOCKS5.parseReply(ipv4) == .success(length: 10))
    #expect(SOCKS5.parseReply(ipv4 + [42]) == .success(length: 10))
    let ipv6: [UInt8] = [5, 0, 0, 4] + [UInt8](repeating: 0, count: 16) + [0, 22]
    #expect(SOCKS5.parseReply(ipv6) == .success(length: 22))
    let domain: [UInt8] = [5, 0, 0, 3, 3] + Array("abc".utf8) + [0, 22]
    #expect(SOCKS5.parseReply(Array(domain.prefix(8))) == .needMore)
    #expect(SOCKS5.parseReply(domain) == .success(length: 10))
    #expect(SOCKS5.parseReply([5, 5]) == .failure(code: 5))
    #expect(SOCKS5.parseReply([4, 0]) == .failure(code: 1))
    #expect(SOCKS5.parseReply([5, 0, 0, 9, 0]) == .failure(code: 1))
}

@Test func routeResolutionUsability() {
    #expect(RouteResolution(routed: true, tunnel: true, socksPort: 1080).usable)
    #expect(!RouteResolution(routed: false, tunnel: true, socksPort: 1080).usable)
    #expect(!RouteResolution(routed: true, tunnel: false, socksPort: nil).usable)
}

private let gatewayConnection = Connection(institution: "Lab", hostname: "jump.lab.example.org", port: 2222, username: "alice", keyReference: "/k")

@Test func sshConfigLayersHostsTunnelAndFallbackInOrder() throws {
    let integration = SSHIntegration(gateway: SSHGateway(aliases: ["lab_tunnel"], identityFile: "~/.ssh/id_lab"), hosts: [
        SSHHostEntry(aliases: ["gerrit"], hostname: "gerrit.lab.example.org", user: "alice", identityFile: "~/.ssh/id_gerrit"),
        SSHHostEntry(aliases: ["box"], hostname: "box.lab.example.org", port: 2222, identitiesOnly: true, extraOptions: ["LocalForward 8080 localhost:80"]),
    ])
    let text = try SSHConfigGenerator.render(connection: gatewayConnection, integration: integration,
        customDomains: [try Domain("lab.example.org")], labroutePath: "/Applications/LabRoute.app/Contents/MacOS/labroute")
    let expected = """
    \(SSHConfigGenerator.header)

    # Jump host for when the LabRoute tunnel is not connected
    Host labroute-gateway lab_tunnel
      HostName jump.lab.example.org
      Port 2222
      User alice
      IdentityFile "~/.ssh/id_lab"
      ServerAliveInterval 30
      ServerAliveCountMax 3

    Host gerrit gerrit.lab.example.org
      HostName gerrit.lab.example.org
      User alice
      IdentityFile "~/.ssh/id_gerrit"

    Host box box.lab.example.org
      HostName box.lab.example.org
      Port 2222
      IdentitiesOnly yes
      LocalForward 8080 localhost:80

    # Through the LabRoute tunnel while it is connected
    Match host "lab.example.org,*.lab.example.org,!jump.lab.example.org" exec "'/Applications/LabRoute.app/Contents/MacOS/labroute' proxy --check %h"
      ProxyCommand '/Applications/LabRoute.app/Contents/MacOS/labroute' proxy %h %p

    # Otherwise through the jump host
    Match host "lab.example.org,*.lab.example.org,!jump.lab.example.org"
      ProxyJump labroute-gateway

    """
    #expect(text == expected)
}

@Test func sshConfigWithoutCustomDomainsHasNoRoutingLayers() throws {
    let text = try SSHConfigGenerator.render(connection: gatewayConnection, integration: SSHIntegration(), customDomains: [], labroutePath: "/x/labroute")
    #expect(!text.contains("Match"))
    #expect(text.contains("Host labroute-gateway\n"))
}

@Test(arguments: ["ProxyCommand nc %h %p", "proxyjump other", "Host evil", "Match all", "Include /tmp/x", "HostName other", "NoValue", "Bad-Key x", "Local\nForward x"])
func sshExtraOptionsRejectRoutingKeysAndMalformedLines(line: String) {
    #expect(throws: SSHConfigError.self) { try SSHHostEntry(aliases: ["a"], hostname: "a.example.org", extraOptions: [line]).validate() }
}

@Test(arguments: [
    SSHHostEntry(aliases: ["two words"], hostname: "a.example.org"),
    SSHHostEntry(aliases: ["*"], hostname: "a.example.org"),
    SSHHostEntry(aliases: ["a,b"], hostname: "a.example.org"),
    SSHHostEntry(aliases: ["-oProxyCommand"], hostname: "a.example.org"),
    SSHHostEntry(aliases: ["a"], hostname: "a.example.org\nProxyCommand x"),
    SSHHostEntry(aliases: ["a"], hostname: "a.example.org", identityFile: "relative/key"),
    SSHHostEntry(aliases: ["a"], hostname: "a.example.org", identityFile: "/tmp/\"key"),
    SSHHostEntry(aliases: ["a"], hostname: "a.example.org", identityFile: "/tmp/%d"),
    SSHHostEntry(aliases: ["a"], hostname: "a.example.org", user: "bad user"),
])
func sshHostValidationRejectsInjection(host: SSHHostEntry) {
    #expect(throws: SSHConfigError.self) { try host.validate() }
}

@Test func sshConfigRejectsDuplicateAliasesAndUnquotablePaths() throws {
    let duplicate = SSHIntegration(gateway: SSHGateway(aliases: ["box"]), hosts: [SSHHostEntry(aliases: ["box"], hostname: "box.example.org")])
    #expect(throws: SSHConfigError.self) { try SSHConfigGenerator.render(connection: gatewayConnection, integration: duplicate, customDomains: [], labroutePath: "/x") }
    #expect(throws: SSHConfigError.self) { try SSHConfigGenerator.render(connection: gatewayConnection, integration: SSHIntegration(), customDomains: [], labroutePath: "/it's/labroute") }
}

@Test func customDomainsExcludeBuiltInAndDisabledRoutes() throws {
    var configuration = AppConfiguration(packs: [
        RoutePack(id: "publishers", name: "P", routes: [Route(domain: try Domain("nature.com"), source: .builtIn)]),
        RoutePack(id: "custom", name: "C", routes: [Route(domain: try Domain("lab.example.org")), Route(domain: try Domain("off.example.org"), enabled: false)]),
    ])
    #expect(configuration.customDomains.map(\.value) == ["lab.example.org"])
    configuration.packs[1].enabled = false
    #expect(configuration.customDomains.isEmpty)
}

@Test func httpProxyParsesConnect() throws {
    let bytes = Array("CONNECT Gerrit.Example.org:443 HTTP/1.1\r\nHost: gerrit.example.org:443\r\n\r\nTLS".utf8)
    let request = try #require(try HTTPProxyRequest.parse(bytes))
    #expect(request.kind == .connect && request.host == "gerrit.example.org" && request.port == 443)
    #expect(Array(bytes.dropFirst(request.headLength)) == Array("TLS".utf8))
    let v6 = try #require(try HTTPProxyRequest.parse(Array("CONNECT [2001:db8::1]:22 HTTP/1.1\r\n\r\n".utf8)))
    #expect(v6.host == "2001:db8::1" && v6.port == 22)
}

@Test func httpProxyRewritesAbsoluteURIToOriginForm() throws {
    let bytes = Array("GET http://intranet.example.org/tools/hooks?x=1 HTTP/1.1\r\nHost: intranet.example.org\r\nProxy-Connection: keep-alive\r\nProxy-Authorization: Basic x\r\nAccept: */*\r\n\r\n".utf8)
    let request = try #require(try HTTPProxyRequest.parse(bytes))
    #expect(request.kind == .forward && request.host == "intranet.example.org" && request.port == 80)
    #expect(String(decoding: request.upstreamHead, as: UTF8.self) ==
        "GET /tools/hooks?x=1 HTTP/1.1\r\nHost: intranet.example.org\r\nAccept: */*\r\nConnection: close\r\n\r\n")
    let bare = try #require(try HTTPProxyRequest.parse(Array("HEAD http://box.example.org:8080 HTTP/1.0\r\n\r\n".utf8)))
    #expect(String(decoding: bare.upstreamHead, as: UTF8.self) == "HEAD / HTTP/1.0\r\nHost: box.example.org:8080\r\nConnection: close\r\n\r\n")
}

@Test func httpProxyWaitsForCompleteHead() throws {
    #expect(try HTTPProxyRequest.parse(Array("CONNECT a.example.org:443 HTTP/1.1\r\n".utf8)) == nil)
}

@Test(arguments: [
    "GET /relative HTTP/1.1\r\n\r\n", "GET https://a.example.org/ HTTP/1.1\r\n\r\n", "CONNECT a.example.org HTTP/1.1\r\n\r\n",
    "CONNECT a.example.org:0 HTTP/1.1\r\n\r\n", "CONNECT user@a.example.org:443 HTTP/1.1\r\n\r\n", "CONNECT a.example.org:443 HTTP/2\r\n\r\n",
    "GET http://a.example.org/ HTTP/1.1\r\nBroken header\r\n\r\n", "get http://a.example.org/ HTTP/1.1\r\n\r\n",
])
func httpProxyRejectsUnsupportedRequests(text: String) {
    #expect(throws: HTTPProxyError.badRequest) { try HTTPProxyRequest.parse(Array(text.utf8)) }
}

@Test func httpProxyRejectsOversizedHeads() {
    let bytes = Array(("GET http://a.example.org/ HTTP/1.1\r\nX: " + String(repeating: "a", count: 9000)).utf8)
    #expect(throws: HTTPProxyError.badRequest) { try HTTPProxyRequest.parse(bytes) }
}
