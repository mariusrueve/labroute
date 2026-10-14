import CFNetwork
import Foundation
import JavaScriptCore
import Testing
@testable import LabRouteCore

@Test(arguments: [
    ("Example.COM", "example.com"),
    (" https://Example.COM/a?secret=value#fragment ", "example.com"),
    ("example.com/path", "example.com"),
    ("http://example.com:8080/", "example.com"),
    ("example.com.", "example.com"),
    ("a-b.example.com", "a-b.example.com"),
    ("xn--bcher-kva.de", "xn--bcher-kva.de"),
])
func normalization(pair: (String, String)) throws {
    #expect(try Domain(pair.0).value == pair.1)
}

@Test(arguments: [
    "", "localhost", "127.0.0.1", "[::1]", "2130706433", "*.example.com",
    "ftp://example.com", "https://user:password@example.com", "https://user@example.com",
    "example.com;alert(1)", "example.com\"", "example.com\\evil", "a..example.com",
    "-a.example.com", "a-.example.com", "a_b.example.com", "hello world.com",
    "%65xample.com", "https://example.com:0", "https://example.com:65536",
    "bücher.de", "xn--.de", "xn--invalidpunycode-.com",
    String(repeating: "a", count: 64) + ".com",
])
func invalidDomain(input: String) {
    #expect(throws: (any Error).self) { try Domain(input) }
}

@Test func domainBoundary() throws {
    let domain = try Domain("example.com")
    for host in ["example.com", "a.example.com", "deep.a.EXAMPLE.com."] { #expect(domain.matches(host: host)) }
    for host in ["notexample.com", "example.com.evil.test", "com", "exampleXcom"] { #expect(!domain.matches(host: host)) }
}

@Test func packUnionAndDisabledEntries() throws {
    let parent = try Domain("example.com")
    let child = try Domain("sub.example.com")
    let packs = [
        RoutePack(id: "one", name: "One", routes: [Route(domain: parent), Route(domain: child, enabled: false)]),
        RoutePack(id: "two", name: "Two", enabled: false, routes: [Route(domain: try Domain("other.test"))]),
        RoutePack(id: "three", name: "Three", routes: [Route(domain: parent)]),
    ]
    let routes = RouteSet(packs: packs)
    #expect(routes.domains == [parent])
    #expect(routes.matches(host: "sub.example.com"))
    #expect(!routes.matches(host: "other.test"))
}

@Test @MainActor func pacMatchesSwiftAndNeverReturnsDirectForSelectedHosts() throws {
    let routes = RouteSet(domains: [try Domain("example.com"), try Domain("another.test")])
    let script = try PACGenerator.generate(routes: routes, socksPort: 32123)
    let context = try #require(JSContext())
    context.evaluateScript(script)
    #expect(context.exception == nil)
    let function = try #require(context.objectForKeyedSubscript("FindProxyForURL"))
    for host in ["example.com", "a.example.com", "EXAMPLE.COM.", "notexample.com", "example.com.evil.test", "another.test", "unmatched.test"] {
        let actual = function.call(withArguments: ["https://\(host)/path?query=secret", host])?.toString()
        #expect(actual == (routes.matches(host: host) ? "SOCKS5 127.0.0.1:32123; SOCKS 127.0.0.1:32123" : "DIRECT"))
    }
    #expect(!script.contains("; DIRECT"))
    #expect(!script.contains("dnsResolve"))
    #expect(!script.contains("isInNet"))
}

@Test func pacDeterminismAndEmptyRoutes() throws {
    let a = try Domain("a.test"), b = try Domain("b.test")
    #expect(try PACGenerator.generate(routes: RouteSet(domains: [b, a, a]), socksPort: 1080)
        == PACGenerator.generate(routes: RouteSet(domains: [a, b]), socksPort: 1080))
    #expect(throws: PACError.self) { try PACGenerator.generate(routes: RouteSet(domains: []), socksPort: 0) }
}

@Test func bundledPacksAndCodableValidation() throws {
    let packs = try RoutePack.defaults()
    #expect(packs.count == 3)
    #expect(packs[0].enabled)
    #expect(packs[0].routes.allSatisfy { $0.source == .builtIn })
    let config = AppConfiguration(packs: packs)
    #expect(try JSONDecoder().decode(AppConfiguration.self, from: JSONEncoder().encode(config)) == config)
    #expect(throws: (any Error).self) { try JSONDecoder().decode(Domain.self, from: Data("\"*.example.com\"".utf8)) }
}

@Test func macOSParsesSelectedPACAsSOCKSVersion5() throws {
    let script = try PACGenerator.generate(routes: RouteSet(domains: [Domain("selected.labroute.test")]), socksPort: 32123)
    var error: Unmanaged<CFError>?
    let result = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString,
        URL(string: "http://sub.selected.labroute.test/")! as CFURL, &error)?.takeRetainedValue()
    #expect(error == nil)
    let proxies = try #require(result as? [[String: Any]])
    #expect(proxies.count == 1)
    let proxy = try #require(proxies.first)
    #expect(proxy[kCFProxyTypeKey as String] as? String == kCFProxyTypeSOCKS as String)
    #expect(proxy[kCFProxyHostNameKey as String] as? String == "127.0.0.1")
    #expect(proxy[kCFProxyPortNumberKey as String] as? Int == 32123)
    #expect(proxy[kCFStreamPropertySOCKSVersion as String] as? String == kCFStreamSocketSOCKSVersion5 as String)
}

@Test func routeEditsPreserveBuiltInsAndParentCoverage() throws {
    let initial = try RoutePack.defaults()
    var packs = try RouteEditing.apply("add", domain: "https://sub.example.test/path", to: initial)
    packs = try RouteEditing.apply("add", domain: "example.test", packID: "internal", to: packs)
    packs = try RouteEditing.apply("disable", domain: "sub.example.test", to: packs)
    #expect(RouteSet(packs: packs).matches(host: "sub.example.test"))
    #expect(packs.first { $0.id == "publications" } == initial.first { $0.id == "publications" })
    packs = try RouteEditing.apply("add", domain: "sub.example.test", to: packs)
    #expect(packs.first { $0.id == "custom" }?.routes.count == 1)
    #expect(throws: RouteEditError.self) {
        try RouteEditing.apply("add", domain: "example.test", packID: "publications", to: packs)
    }
    #expect(throws: RouteEditError.self) {
        try RouteEditing.apply("disable", domain: "missing.example.test", to: packs)
    }
}

@Test func removeDeletesOnlyUserDomains() throws {
    let defaults = try RoutePack.defaults()
    var packs = try RouteEditing.apply("add", domain: "typo.example.test", to: defaults)
    packs = try RouteEditing.apply("add", domain: "typo.example.test", packID: "internal", to: packs)
    packs = try RouteEditing.apply("remove", domain: "https://typo.example.test/path", to: packs)
    #expect(packs == defaults)
    #expect(throws: RouteEditError.builtIn) { try RouteEditing.apply("remove", domain: "nature.com", to: packs) }
    #expect(throws: RouteEditError.unknownRoute) { try RouteEditing.apply("remove", domain: "missing.example.test", to: packs) }
}

@Test func labSetupSharesOnlyLabData() throws {
    var configuration = AppConfiguration(packs: try RouteEditing.apply("add", domain: "wiki.lab.example", packID: "internal", to: RoutePack.defaults()))
    configuration.connection = Connection(institution: "Lab", hostname: "ssh.lab.example", port: 2222, username: "jdoe", keyReference: "/keys/id_labroute")
    configuration.ssh = SSHIntegration(gateway: SSHGateway(aliases: ["lab"], identityFile: "~/.ssh/id_lab"),
        hosts: [SSHHostEntry(aliases: ["gerrit"], hostname: "gerrit.lab.example", port: 29418, user: "jdoe",
                             identityFile: "~/.ssh/id_gerrit", extraOptions: ["LocalForward 8080 localhost:80"])])
    let data = try JSONEncoder().encode(try #require(LabSetup(configuration)))
    let text = String(decoding: data, as: UTF8.self)
    for personal in ["jdoe", "id_labroute", "id_lab\"", "id_gerrit", "LocalForward"] { #expect(!text.contains(personal)) }
    let decoded = try JSONDecoder().decode(LabSetup.self, from: data)
    try decoded.validate()
    #expect(decoded.hostname == "ssh.lab.example" && decoded.port == 2222 && decoded.gatewayAliases == ["lab"])
    #expect(decoded.internalDomains.map(\.value) == ["wiki.lab.example"] && decoded.customDomains.isEmpty)
    #expect(decoded.sshHosts == [LabSetup.Host(hostname: "gerrit.lab.example", aliases: ["gerrit"], port: 29418)])
    let bad = text.replacingOccurrences(of: "wiki.lab.example", with: "not a domain")
    #expect(throws: (any Error).self) { try JSONDecoder().decode(LabSetup.self, from: Data(bad.utf8)) }
    var newer = decoded; newer.labroute = 2
    #expect(throws: LabSetupError.invalid) { try newer.validate() }
}

@Test func experimentalPACDirectiveParserMatrix() throws {
    // Documents how CFNetwork (Safari) parses each candidate directive.
    for directive in ["SOCKS 127.0.0.1:32123", "SOCKS5 127.0.0.1:32123", "SOCKS5 127.0.0.1:32123; SOCKS 127.0.0.1:32123"] {
        let script = "function FindProxyForURL(url, host) { return \"\(directive)\"; }"
        var error: Unmanaged<CFError>?
        let result = CFNetworkCopyProxiesForAutoConfigurationScript(script as CFString,
            URL(string: "http://selected.labroute.test/")! as CFURL, &error)?.takeRetainedValue()
        #expect(error == nil)
        let proxies = try #require(result as? [[String: Any]])
        let summary = proxies.map { proxy in
            ["type": proxy[kCFProxyTypeKey as String] as? String ?? "unknown",
             "version": proxy[kCFStreamPropertySOCKSVersion as String] as? String ?? "none"]
        }
        print("PAC_MATRIX " + String(decoding: try JSONSerialization.data(withJSONObject: ["directive": directive, "proxies": summary], options: [.sortedKeys]), as: UTF8.self))
        #expect(proxies.allSatisfy { $0[kCFProxyTypeKey as String] as? String != kCFProxyTypeNone as String })
        if directive != "SOCKS5 127.0.0.1:32123" {
            #expect(proxies.count == 1)
            #expect(proxies.first?[kCFStreamPropertySOCKSVersion as String] as? String == kCFStreamSocketSOCKSVersion5 as String)
        }
    }
}

@Test func savedPacksPickUpNewBuiltInsAndKeepUserChoices() throws {
    let defaults = try RoutePack.defaults()
    var saved = defaults
    saved[0].routes = [Route(id: "nature", domain: try Domain("nature.com"), enabled: false, source: .builtIn),
                       Route(id: "retired", domain: try Domain("retired.example"), source: .builtIn)]
    saved[2].routes = [Route(domain: try Domain("custom.example"))]
    saved.removeAll { $0.id == "internal" }
    let merged = RoutePack.merging(saved: saved, defaults: defaults)
    let publications = try #require(merged.first { $0.id == "publications" })
    #expect(publications.routes.count == defaults[0].routes.count)
    #expect(publications.routes.first { $0.id == "nature" }?.enabled == false)
    #expect(!publications.routes.contains { $0.id == "retired" })
    #expect(merged.first { $0.id == "custom" }?.routes.map(\.domain.value) == ["custom.example"])
    #expect(merged.contains { $0.id == "internal" })
    #expect(RoutePack.merging(saved: merged, defaults: defaults) == merged)
}

@Test func realisticConnectionsValidate() throws {
    // Regression: optimized builds once rejected valid connections like this one.
    try Connection(institution: "Lab", hostname: "ssh.uni-example.de", port: 7373, username: "jdoe",
                   keyReference: "/Users/jdoe/Library/Application Support/LabRoute/SSH/8F3A/id_ed25519").validate()
    try Connection(institution: "Lab", hostname: "10.0.0.5", username: "j.doe-2@lab").validate()
    for bad in [Connection(institution: " ", hostname: "h.example", username: "u"),
                Connection(institution: "Lab", hostname: "-oProxy", username: "u"),
                Connection(institution: "Lab", hostname: "h.example", username: "u ser"),
                Connection(institution: "Lab", hostname: "h.example", username: "u", keyReference: "relative/key"),
                Connection(institution: "Lab", hostname: "h.example", username: "u", keyReference: "/a\nb")] {
        #expect(throws: ConnectionError.self) { try bad.validate() }
    }
}
