import Foundation
import Testing
import Security
import LabRouteCore
@testable import LabRouteServices

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func configurationRoundTripAndRecovery() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = ConfigurationStore(url: directory.appendingPathComponent("config.json"))
    #expect(try store.load() == nil)
    var config = AppConfiguration(packs: try RoutePack.defaults())
    try store.save(config)
    #expect(try store.load() == config)
    let permissions = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
    #expect(permissions == 0o600)
    config.version = 999
    #expect(throws: StoreError.self) { try store.save(config) }
    try JSONEncoder().encode(config).write(to: store.url)
    #expect(throws: StoreError.self) { try store.load() }
    try Data("broken".utf8).write(to: store.url)
    #expect(throws: (any Error).self) { try store.load() }
}

private final class FakePreferences: ProxyPreferences {
    var current: [String: ProxySnapshot]
    var staged: [String: ProxySnapshot] = [:]
    var failApply = false
    var commitCount = 0
    var finishCount = 0
    func finish() { finishCount += 1 }
    init() throws {
        current = [
            "wifi": try ProxySnapshot(enabled: true, dictionary: ["ExceptionsList": ["*.local"]]),
            "ethernet": try ProxySnapshot(enabled: false, dictionary: nil),
        ]
    }
    func read() throws -> [String: ProxySnapshot] { current }
    func stage(_ snapshot: ProxySnapshot, for service: String) throws { staged[service] = snapshot }
    func commitAndApply() throws {
        commitCount += 1
        current.merge(staged) { _, new in new }
        staged.removeAll()
        if failApply { throw ProxyError.verificationFailed }
    }
}

private let pacURL = URL(string: "http://127.0.0.1:32100/proxy.pac")!

@Test func noninteractiveProxyAuthorizationNeverRequestsUI() throws {
    let placeholder = AuthorizationRef(bitPattern: 1)!
    var invoked = false
    try authorizeNetworkPreferencesWithoutInteraction(placeholder) { _, rights, flags in
        invoked = true
        #expect(!flags.contains(.interactionAllowed))
        #expect(flags.contains(.extendRights))
        #expect(rights.pointee.count == 1)
        #expect(String(cString: rights.pointee.items!.pointee.name) == "system.services.systemconfiguration.network")
        return errAuthorizationSuccess
    }
    #expect(invoked)
    #expect(throws: ProxyError.self) {
        try authorizeNetworkPreferencesWithoutInteraction(placeholder) { _, _, _ in errAuthorizationInteractionNotAllowed }
    }
}

@Test func effectiveProxyVerificationFailureRetainsJournal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let preferences = try FakePreferences()
    let original = preferences.current
    #expect(throws: ProxyError.self) {
        try transaction.install(pacURL: pacURL, preferences: preferences, verifyEffective: { throw ProxyError.verificationFailed })
    }
    #expect(transaction.needsRecovery)
    #expect(preferences.current != original)
    #expect(throws: ProxyError.self) {
        try transaction.restore(preferences: preferences, verifyEffective: { throw ProxyError.verificationFailed })
    }
    #expect(transaction.needsRecovery)
    #expect(preferences.current == original)
    try transaction.restore(preferences: preferences, verifyEffective: {})
    #expect(!transaction.needsRecovery)
}

@Test func proxyTransactionRestoresExactPreviousValues() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let preferences = try FakePreferences()
    let original = preferences.current
    try transaction.install(pacURL: pacURL, preferences: preferences)
    #expect(transaction.needsRecovery)
    #expect(preferences.current != original)
    #expect(preferences.finishCount == 1)
    #expect(try preferences.current["wifi"]?.dictionary()?["ExceptionsList"] as? [String] == ["*.local"])
    #expect(throws: ProxyError.self) { try transaction.install(pacURL: pacURL, preferences: preferences) }
    try transaction.restore(preferences: preferences)
    #expect(preferences.current == original)
    #expect(preferences.finishCount == 3)
    #expect(!transaction.needsRecovery)
}

@Test func proxyRefusesExistingConfigurationAndExternalChanges() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let preferences = try FakePreferences()
    preferences.current["wifi"] = try ProxySnapshot(enabled: true, dictionary: ["HTTPEnable": 1])
    #expect(throws: ProxyError.self) { try transaction.install(pacURL: pacURL, preferences: preferences) }
    #expect(!transaction.needsRecovery)
    #expect(preferences.commitCount == 0)
    #expect(preferences.finishCount == 1)
    preferences.current["wifi"] = try ProxySnapshot(enabled: true, dictionary: [:])
    try transaction.install(pacURL: pacURL, preferences: preferences)
    preferences.current["wifi"] = try ProxySnapshot(enabled: true, dictionary: ["SOCKSEnable": 1])
    let externallyChanged = preferences.current
    #expect(throws: ProxyError.self) { try transaction.restore(preferences: preferences) }
    #expect(preferences.current == externallyChanged)
    #expect(transaction.needsRecovery)
}

@Test func failedApplyRetainsRecoverableJournal() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let preferences = try FakePreferences()
    let original = preferences.current
    preferences.failApply = true
    #expect(throws: ProxyError.self) { try transaction.install(pacURL: pacURL, preferences: preferences) }
    #expect(transaction.needsRecovery)
    preferences.failApply = false
    try transaction.restore(preferences: preferences)
    #expect(preferences.current == original)
}

@Test(arguments: ["http://example.com/proxy.pac", "http://127.0.0.1/proxy.pac", "http://user@127.0.0.1:32100/proxy.pac", "file:///tmp/proxy.pac"])
func proxyRejectsUnsafePACURLs(url: String) throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let preferences = try FakePreferences()
    #expect(throws: ProxyError.self) { try transaction.install(pacURL: URL(string: url)!, preferences: preferences) }
    #expect(preferences.commitCount == 0)
}

@Test @MainActor func pacServerLifecycleAndFixedPath() async throws {
    let server = PACServer()
    defer { server.stop() }
    let script = try PACGenerator.generate(routes: RouteSet(domains: [Domain("example.com")]), socksPort: 1080)
    let port = try await server.start(script: script)
    #expect(port > 0)
    let configuration = URLSessionConfiguration.ephemeral
    configuration.connectionProxyDictionary = [:]
    configuration.timeoutIntervalForRequest = 3
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    let (data, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/proxy.pac")!)
    #expect(String(decoding: data, as: UTF8.self) == script)
    #expect((response as? HTTPURLResponse)?.statusCode == 200)
    let (_, missing) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/not-a-file")!)
    #expect((missing as? HTTPURLResponse)?.statusCode == 404)
    server.stop()
    #expect(server.port == nil)
    let restarted = try await server.start(script: script)
    #expect(restarted > 0)
}

@Test func selectedServicesIgnoreUnrelatedConflictsAndRecordLocation() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let preferences = try FakePreferences()
    preferences.current["ethernet"] = try ProxySnapshot(enabled: true, dictionary: ["ProxyAutoConfigURLString": "https://other.invalid/pac", "ProxyAutoConfigEnable": 1])
    let untouched = preferences.current["ethernet"]
    let originalWiFi = preferences.current["wifi"]
    try transaction.install(pacURL: pacURL, preferences: preferences, serviceIDs: ["wifi"], locationID: "location-a")
    #expect(preferences.current["ethernet"] == untouched)
    let record = try #require(try transaction.record())
    #expect(record.locationID == "location-a")
    #expect(Set(record.applied.keys) == ["wifi"])
    // Recovery reads all recorded service identities, without a current-location filter.
    preferences.current["new-location-service"] = try ProxySnapshot(enabled: true, dictionary: [:])
    try transaction.restore(preferences: preferences)
    #expect(preferences.current["wifi"] == originalWiFi)
    #expect(preferences.current["ethernet"] == untouched)
}

@Test func missingOrEmptyServiceSelectionNeverMutates() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let preferences = try FakePreferences()
    for selection: Set<String> in [[], ["removed-service"]] {
        #expect(throws: ProxyError.self) {
            try transaction.install(pacURL: pacURL, preferences: preferences, serviceIDs: selection)
        }
    }
    #expect(preferences.commitCount == 0)
    #expect(!transaction.needsRecovery)
}

@Test func sshArgumentsIsolateConfigurationAndDoNotContainSecrets() throws {
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/key with spaces")
    let arguments = try SSHOptions.tunnel(connection, knownHosts: URL(fileURLWithPath: "/tmp/known_hosts"), port: 41080)
    #expect(arguments.contains("/dev/null"))
    #expect(arguments.contains("127.0.0.1:41080"))
    #expect(arguments.contains("ExitOnForwardFailure=yes"))
    #expect(arguments.contains("StrictHostKeyChecking=yes"))
    #expect(arguments.contains("PasswordAuthentication=no"))
    #expect(arguments.contains("ForwardAgent=no"))
    #expect(arguments.contains("/tmp/key with spaces"))
    #expect(!arguments.contains("-A"))
    #expect(!SSHOptions.classify("Permission denied (publickey).").retry)
    #expect(!SSHOptions.classify("REMOTE HOST IDENTIFICATION HAS CHANGED").retry)
    #expect(!SSHOptions.classify("bind: Address already in use").retry)
    #expect(!SSHOptions.classify("Bad configuration option: test").retry)
    #expect(!SSHOptions.classify("Load key: invalid format").retry)
    #expect(SSHOptions.classify("Connection reset by peer").retry)
}

private struct EmptySecrets: KeySecretStore {
    func read(_ id: String) throws -> String? { nil }
    func save(_ value: String, id: String) throws {}
    func delete(_ id: String) throws {}
}

@MainActor private final class FakeChild: ChildProcess {
    var pid: Int32 = 12345
    var running = true
    var exitStatus: Int32 = 0
    var output = Data()
    var diagnostic = ""
    var stops = 0
    func stop() async { stops += 1; running = false }
}

@MainActor private final class FakeRunner: ProcessRunner {
    let child = FakeChild()
    var starts = 0
    func start(_ spec: ProcessSpec) throws -> any ChildProcess {
        starts += 1
        return child
    }
}

@Test @MainActor func supervisorRejectsDuplicateAndWaitsForCancellation() async throws {
    let runner = FakeRunner()
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in true })
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/unused-key")
    let port = UInt16.random(in: 40000...48000)
    try await supervisor.start(connection: connection, port: port, helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptySecrets())
    await #expect(throws: (any Error).self) {
        try await supervisor.start(connection: connection, port: port, helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptySecrets())
    }
    for _ in 0..<100 {
        if supervisor.state == .connected { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(supervisor.state == .connected)
    #expect(runner.starts == 1)
    try await supervisor.stop()
    #expect(!runner.child.running)
    #expect(runner.child.stops >= 1)
    #expect(supervisor.state == .disabled)
    #expect(supervisor.port == nil)
}

@Test @MainActor func supervisorAuthenticationFailureDoesNotRetry() async throws {
    let runner = FakeRunner()
    runner.child.running = false
    runner.child.diagnostic = "Permission denied (publickey)."
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in false })
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/unused-key")
    try await supervisor.start(connection: connection, port: UInt16.random(in: 40000...48000), helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptySecrets())
    for _ in 0..<100 {
        if supervisor.state == .error { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(supervisor.state == .error)
    #expect(runner.starts == 1)
    try await supervisor.stop()
}

@Test @MainActor func publicKeyInstallationPreservesContentsAndIsIdempotent() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let ssh = directory.appendingPathComponent(".ssh")
    try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
    let authorized = ssh.appendingPathComponent("authorized_keys")
    let prior = "# Existing fixture entry without a final newline"
    try Data(prior.utf8).write(to: authorized)
    let key = "ssh-ed25519 Zml4dHVyZQ== LabRoute-test"
    let operation = ProcessSpec("/bin/sh", ["-c", SSHOptions.installPublicKey],
        environment: ["HOME": directory.path], input: Data((key + "\n").utf8))
    let first = try await collect(operation, runner: SystemProcessRunner())
    #expect(first.0 == 0)
    let initial = try Data(contentsOf: authorized)
    let second = try await collect(operation, runner: SystemProcessRunner())
    #expect(second.0 == 0)
    #expect(try Data(contentsOf: authorized) == initial)
    #expect(String(decoding: initial, as: UTF8.self) == prior + "\n" + key + "\n")
}

@Test @MainActor func generatedKeyPassphraseUsesPrivateInput() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let key = directory.appendingPathComponent("fixture-key")
    let phrase = "disposable-test-passphrase"
    let result = try await collect(ProcessSpec("/usr/bin/ssh-keygen",
        ["-q", "-t", "ed25519", "-a", "1", "-C", "LabRoute-test", "-f", key.path],
        input: Data((phrase + "\n" + phrase + "\n").utf8)), runner: SystemProcessRunner())
    #expect(result.0 == 0)
    #expect(FileManager.default.fileExists(atPath: key.path + ".pub"))
    // An encrypted OpenSSH key has a cipher name, not the plaintext "none" format.
    let file = try String(contentsOf: key, encoding: .utf8)
    let base64 = file.split(separator: "\n").filter { !$0.hasPrefix("-----") }.joined()
    let decoded = try #require(Data(base64Encoded: base64))
    #expect(decoded.range(of: Data("aes256-ctr".utf8)) != nil)
    #expect(decoded.range(of: Data(phrase.utf8)) == nil)
}

@Test @MainActor func askpassAuthenticatesParentAndCancelsWithoutOutput() async throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let paths = [ProcessInfo.processInfo.environment["LABROUTE_TEST_ASKPASS"],
                 root.appendingPathComponent(".build/debug/LabRouteAskPass").path,
                 root.appendingPathComponent(".build/out/Products/Debug/LabRouteAskPass").path].compactMap { $0 }
    let helper = paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    let executable = try #require(helper)
    let session = try CredentialSession(helper: executable, passphrase: "disposable-fixture-value", interactive: false) { _ in nil }
    defer { session.stop() }
    // A real helper with no allowed parent must not receive a secret.
    var result = try await collect(ProcessSpec(executable.path, ["Enter passphrase:"], environment: session.environment), runner: SystemProcessRunner())
    #expect(result.0 != 0)
    #expect(result.1.isEmpty)
    // This test owns the helper directly; runtime uses the owned SSH PID instead.
    session.allowedPID = ProcessInfo.processInfo.processIdentifier
    result = try await collect(ProcessSpec(executable.path, ["Enter passphrase:"], environment: session.environment), runner: SystemProcessRunner())
    #expect(result.0 == 0)
    #expect(result.1 == Data("disposable-fixture-value\n".utf8))
    result = try await collect(ProcessSpec(executable.path, ["Account password:"], environment: session.environment), runner: SystemProcessRunner())
    #expect(result.0 != 0)
    #expect(result.1.isEmpty)
}

@MainActor private final class ReplacingRunner: ProcessRunner {
    var children: [FakeChild] = []
    var overlap = false
    func start(_ spec: ProcessSpec) throws -> any ChildProcess {
        if children.contains(where: { $0.running }) { overlap = true }
        let child = FakeChild()
        children.append(child)
        return child
    }
}

@Test @MainActor func sleepWakeRestartsSameEndpointWithoutOverlappingChildren() async throws {
    let runner = ReplacingRunner()
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in true })
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/unused")
    let port = UInt16.random(in: 40000...48000)
    try await supervisor.start(connection: connection, port: port, helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptySecrets())
    for _ in 0..<100 {
        if supervisor.state == .connected { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    supervisor.suspend()
    // Even a very fast wake must replace the old connection once.
    supervisor.resume()
    supervisor.resume()
    for _ in 0..<150 {
        if runner.children.count == 2 && supervisor.state == .connected { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(runner.children.count == 2)
    #expect(!runner.overlap)
    #expect(supervisor.port == port)
    supervisor.suspend()
    try await supervisor.stop()
    supervisor.resume()
    #expect(supervisor.state == .disabled)
    #expect(runner.children.allSatisfy { !$0.running })
}

@Test func recoveryRequiresExactOwnedSettingsAndRecordedConnection() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let transaction = ProxyTransaction(journalURL: directory.appendingPathComponent("journal.json"))
    let prefs = try FakePreferences()
    let runtime = RoutingRecovery(connectionID: UUID(), socksPort: 41080, pacPort: 32100, domains: [try Domain("example.test")])
    try transaction.install(pacURL: pacURL, preferences: prefs, serviceIDs: ["wifi"], locationID: "fixture", runtime: runtime)
    #expect(try transaction.recovery(preferences: prefs, connectionID: runtime.connectionID) == runtime)
    #expect(throws: ProxyError.self) { try transaction.recovery(preferences: prefs, connectionID: UUID()) }
    prefs.current["wifi"] = try ProxySnapshot(enabled: true, dictionary: ["HTTPEnable": 1])
    #expect(throws: ProxyError.self) { try transaction.recovery(preferences: prefs, connectionID: runtime.connectionID) }
    #expect(transaction.needsRecovery)
}

@Test func recoveryNeverClaimsAnUnrelatedProcess() async throws {
    // Our test process has the same user but is not the managed SSH executable.
    #expect(OwnedSSHProcess.capture(getpid()) == nil)
    let identity = OwnedSSHProcess(pid: getpid(), startedSeconds: 0, startedMicroseconds: 0)
    try await identity.stopIfStillOwned()
    #expect(kill(getpid(), 0) == 0)
}

@Test @MainActor func supervisorExhaustsRetriesWithInjectedTime() async throws {
    let runner = FakeRunner()
    runner.child.running = false
    runner.child.diagnostic = "Connection reset by peer"
    var delays: [Double] = []
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in false },
        sleep: { _ in await Task.yield(); try Task.checkCancellation() },
        retryDelay: { attempt in
            let delay = SSHOptions.retryDelay(attempt: attempt, jitter: 1)
            delays.append(delay); return delay
        })
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/fixture")
    try await supervisor.start(connection: connection, port: UInt16.random(in: 40000...48000), helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptySecrets())
    for _ in 0..<1000 { if supervisor.state == .error { break }; await Task.yield() }
    #expect(supervisor.state == .error)
    #expect(runner.starts == 7)
    #expect(delays.count == 6)
    #expect(delays == delays.sorted())
    try await supervisor.stop()
}

@Test func networkAuthorizationInteractionFlags() throws {
    let reference = OpaquePointer(bitPattern: 1)!
    var flags: [AuthorizationFlags] = []
    let copy: (AuthorizationRef, UnsafePointer<AuthorizationRights>, AuthorizationFlags) -> OSStatus = { _, _, value in flags.append(value); return errAuthorizationSuccess }
    try authorizeNetworkPreferences(reference, interaction: true, copyRights: copy)
    try authorizeNetworkPreferencesWithoutInteraction(reference, copyRights: copy)
    #expect(flags[0].contains(.interactionAllowed))
    #expect(!flags[1].contains(.interactionAllowed))
    #expect(throws: ProxyError.self) { try authorizeNetworkPreferencesWithoutInteraction(reference, copyRights: { _, _, _ in errAuthorizationDenied }) }
}
