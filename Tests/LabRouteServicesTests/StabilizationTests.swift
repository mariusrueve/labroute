import Foundation
import Darwin
import Testing
import LabRouteCore
@testable import LabRouteServices

@Test func configurationRejectsDuplicateIdentifiersAndInvalidConnections() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = ConfigurationStore(url: root.appendingPathComponent("settings.json"))
    let pack = RoutePack(id: "custom", name: "Custom", routes: [Route(domain: try Domain("example.test"))])
    #expect(throws: (any Error).self) { try store.save(AppConfiguration(packs: [pack, pack])) }
    var config = AppConfiguration(packs: [pack])
    config.connection = Connection(institution: "Test", hostname: "-invalid", username: "test")
    #expect(throws: (any Error).self) { try store.save(config) }
}

@Test @MainActor func secondOwnerCannotRestoreFirstOwnersJournal() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    let first = ApplicationController(environment: fixture.environment())
    defer { first.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let second = ApplicationController(environment: fixture.environment())
    defer { second.shutdownControl() }
    #expect(!second.ownsRuntime)
    #expect(second.execute(ControlRequest(.disconnect)).errorCode == .unavailable)
    #expect(!second.busy)
}

@Test @MainActor func activeSetupAndPACLossAreExplicit() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    let controller = ApplicationController(environment: environment, startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let accepted = controller.execute(ControlRequest(.connect))
    for _ in 0..<1000 {
        if controller.execute(ControlRequest(command: "operation", id: accepted.operation?.id)).operation?.terminal == true { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(controller.routingState == .active)
    controller.setup()
    #expect(!controller.busy)
    #expect(controller.error == "Disconnect and resolve recovery before SSH setup.")
    controller.server.stop()
    #expect(controller.routingState == .degraded)
    #expect(controller.execute(ControlRequest(.status)).status?.reason == "pacUnavailable")
    let stopped = controller.execute(ControlRequest(.disconnect))
    for _ in 0..<1000 {
        if controller.execute(ControlRequest(command: "operation", id: stopped.operation?.id)).operation?.terminal == true { break }
        try await Task.sleep(for: .milliseconds(2))
    }
    #expect(!controller.needsRecovery)
}

private final class StabilizationPreferences: ProxyPreferences {
    var current: [String: ProxySnapshot]
    init() throws { current = ["test": try ProxySnapshot(enabled: true, dictionary: [:])] }
    func read() throws -> [String: ProxySnapshot] { current }
    func stage(_ snapshot: ProxySnapshot, for service: String) throws { current[service] = snapshot }
    func commitAndApply() throws {}
}

@Test func restorationKeepsCleanupPhaseAndReadsLegacyRecords() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let transaction = ProxyTransaction(journalURL: root.appendingPathComponent("journal.json"))
    let preferences = try StabilizationPreferences()
    try transaction.install(pacURL: URL(string: "http://127.0.0.1:32000/proxy.pac")!, preferences: preferences)
    try transaction.restore(preferences: preferences, deferCleanup: true)
    #expect(transaction.needsRecovery)
    #expect(try transaction.record()?.phase == .pendingCleanup)
    try transaction.completeCleanup()
    #expect(!transaction.needsRecovery)
    // Old records without a phase remain readable as applied routing.
    try transaction.install(pacURL: URL(string: "http://127.0.0.1:32000/proxy.pac")!, preferences: preferences)
    var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: transaction.journalURL)) as? [String: Any])
    old.removeValue(forKey: "phase"); old["version"] = 1
    try JSONSerialization.data(withJSONObject: old).write(to: transaction.journalURL)
    #expect(try transaction.record()?.phase == .applied)
    #expect(throws: (any Error).self) { try transaction.completeCleanup() }
    try transaction.restore(preferences: preferences)
}

@Test func IPCFrameDeadlineIncludesTrickledBytes() async throws {
    var descriptors: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0)
    let reader = descriptors[0], writer = descriptors[1]
    defer { Darwin.close(reader); Darwin.close(writer) }
    let task = Task.detached {
        for _ in 0..<10 {
            var byte: UInt8 = 32
            _ = Darwin.write(writer, &byte, 1)
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    let start = ContinuousClock.now
    await #expect(throws: (any Error).self) {
        try await Task.detached { try LocalSocket.receive(reader, timeout: .milliseconds(60)) }.value
    }
    #expect(ContinuousClock.now - start < .milliseconds(150))
    task.cancel(); _ = try? await task.value
}

@Test @MainActor func processCompletionDrainsOutputAndStopsIgnoringTERM() async throws {
    let result = try await collect(ProcessSpec("/bin/sh", ["-c", "printf 'complete'; printf 'diagnostic' >&2"]), runner: SystemProcessRunner())
    #expect(result.1 == Data("complete".utf8))
    #expect(result.2 == "diagnostic")
    let child = try SystemProcessRunner().start(ProcessSpec("/bin/sh", ["-c", "trap '' TERM; exec /usr/bin/tail -f /dev/null"]))
    try await Task.sleep(for: .milliseconds(100))
    let start = ContinuousClock.now
    try await child.stop()
    #expect(!child.running)
    #expect(ContinuousClock.now - start < .seconds(5.5))
}

@MainActor private final class EpisodeChild: ChildProcess {
    var pid: Int32 = 12345
    var running = true
    var exitStatus: Int32 = 0
    var output = Data()
    var diagnostic = "Connection reset by peer"
    var refuseStop = false
    let exited = CompletionSignal()
    func stop() async throws { if refuseStop { throw SSHFailure.cleanup }; running = false; exited.finish() }
    func waitForExit(timeout: Duration?) async throws { try await exited.wait(timeout: timeout) }
    func fail() { running = false; exited.finish() }
}
@MainActor private final class EpisodeRunner: ProcessRunner {
    var children: [EpisodeChild] = []
    func start(_ spec: ProcessSpec) throws -> any ChildProcess {
        let child = EpisodeChild(); children.append(child); return child
    }
}
private struct EmptyEpisodeSecrets: KeySecretStore {
    func read(_ id: String) throws -> String? { nil }
    func save(_ value: String, id: String) throws {}
    func delete(_ id: String) throws {}
}

@Test @MainActor func stableReadinessResetsReconnectEpisode() async throws {
    let runner = EpisodeRunner()
    var instant = ContinuousClock.now
    var delays: [Int] = []
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in true }, sleep: { _ in await Task.yield() },
        retryDelay: { attempt in delays.append(attempt); return 0 }, now: { instant })
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/unused")
    try await supervisor.start(connection: connection, port: UInt16.random(in: 40000...60000), helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptyEpisodeSecrets())
    for episode in 0..<8 {
        for _ in 0..<1000 { if runner.children.count == episode + 1 && supervisor.state == .connected { break }; await Task.yield() }
        #expect(runner.children.count == episode + 1)
        instant += .seconds(61)
        runner.children[episode].fail()
    }
    for _ in 0..<1000 { if runner.children.count == 9 { break }; await Task.yield() }
    #expect(runner.children.count == 9)
    #expect(delays == Array(repeating: 0, count: 8))
    try await supervisor.stop()
}

@Test @MainActor func failedChildStopPreventsReplacement() async throws {
    let runner = EpisodeRunner()
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in true })
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/unused")
    let port = UInt16.random(in: 40000...60000)
    try await supervisor.start(connection: connection, port: port, helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptyEpisodeSecrets())
    for _ in 0..<1000 { if supervisor.state == .connected { break }; await Task.yield() }
    runner.children[0].refuseStop = true
    await #expect(throws: (any Error).self) { try await supervisor.stop() }
    #expect(supervisor.state == .error && runner.children[0].running)
    await #expect(throws: (any Error).self) {
        try await supervisor.start(connection: connection, port: port, helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptyEpisodeSecrets())
    }
    #expect(runner.children.count == 1)
    runner.children[0].refuseStop = false
    try await supervisor.stop()
}

@Test @MainActor func noninteractiveFlagAndCleanupFailureStayStructured() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    environment.restoreProxyWithoutInteraction = { throw ProxyError.authorizationRequired }
    let controller = ApplicationController(environment: environment, startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    var request = ControlRequest(.disconnect); request.nonInteractive = true
    let accepted = controller.execute(request)
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    let failed = controller.execute(ControlRequest(command: "operation", id: accepted.operation?.id))
    #expect(failed.errorCode == .humanInteractionRequired)
    #expect(failed.operation?.reason == "authorizationRequired")
    let legacy = try JSONDecoder().decode(ControlRequest.self, from: Data("{\"version\":1,\"command\":\"status\"}".utf8))
    #expect(legacy.nonInteractive == nil)
}

@Test @MainActor func networkSnapshotRefreshDoesNotCancelConnection() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    environment.sleep = { _ in await Task.yield() }
    var owner: ApplicationController?
    var reads = 0
    let services = environment.services
    environment.validateProxy = { url in
        reads += 1
        if reads == 1 { owner?.validationEpoch += 1 }
        return try RoutingValidation.inspect(preferences: fixture.proxy, services: services(), primary: fixture.activeServices,
            effectivePAC: url, journal: ProxyTransaction(journalURL: fixture.root.appendingPathComponent("journal.json")), pacURL: url)
    }
    let controller = ApplicationController(environment: environment, startIPC: false); owner = controller
    defer { owner = nil; controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let accepted = controller.execute(ControlRequest(.connect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    #expect(controller.execute(ControlRequest(command: "operation", id: accepted.operation?.id)).operation?.phase == .completed)
    #expect(reads >= 2)
    let stopped = controller.execute(ControlRequest(.disconnect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    let result = controller.execute(ControlRequest(command: "operation", id: stopped.operation?.id))
    #expect(result.success)
}

@Test @MainActor func cleanupFailureRetainsRestoredJournalAndCanRetry() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    let cleanup = environment.completeProxyCleanup
    var fail = true
    environment.completeProxyCleanup = { if fail { throw SSHFailure.cleanup }; try await cleanup() }
    let controller = ApplicationController(environment: environment, startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    _ = controller.execute(ControlRequest(.connect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    let failed = controller.execute(ControlRequest(.disconnect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    #expect(controller.execute(ControlRequest(command: "operation", id: failed.operation?.id)).operation?.phase == .failed)
    #expect(controller.needsRecovery && controller.routingState == .degraded)
    #expect(try controller.transaction.record()?.phase == .pendingCleanup)
    fail = false
    _ = controller.execute(ControlRequest(.disconnect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    #expect(!controller.needsRecovery)
}

@Test @MainActor func explicitEmptyServiceSelectionSurvivesRefresh() throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    let controller = ApplicationController(environment: fixture.environment(), startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let result = controller.execute(ControlRequest(command: "services.set", serviceIDs: []))
    #expect(result.success)
    controller.refreshServices()
    #expect(controller.selectedServices.isEmpty)
}

@Test @MainActor func PACStartupCancellationIsBounded() async throws {
    let server = PACServer()
    let task = Task { try await server.start(script: "function FindProxyForURL(){return 'DIRECT';}") }
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    #expect(!server.isReady)
}

@Test @MainActor func crashBeforeProxyJournalStillRequiresRuntimeCleanup() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    let runtime = RuntimeProcessStore(url: fixture.root.appendingPathComponent("ssh-runtime.json"))
    // A stale identity must never kill this unrelated test process.
    try runtime.record(OwnedSSHProcess(pid: getpid(), startedSeconds: 0, startedMicroseconds: 0))
    var environment = fixture.environment(); environment.monitorEnabled = false
    environment.runtimeNeedsRecovery = { runtime.needsRecovery }
    environment.cleanupRuntime = { try await runtime.cleanup() }
    let controller = ApplicationController(environment: environment, startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    #expect(controller.needsRecovery)
    #expect(!controller.transaction.needsRecovery)
    #expect(controller.execute(ControlRequest(.recover)).errorCode == .recoveryRequired)
    let accepted = controller.execute(ControlRequest(.disconnect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    let result = controller.execute(ControlRequest(command: "operation", id: accepted.operation?.id))
    #expect(result.operation?.phase == .completed)
    #expect(!runtime.needsRecovery && !controller.needsRecovery)
    #expect(kill(getpid(), 0) == 0)
}

@Test @MainActor func processIdentityIsRecordedBeforeReadiness() async throws {
    let runner = EpisodeRunner()
    var events: [String] = []
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in
        #expect(events.first == "record"); events.append("ready"); return true
    }, recordProcess: { _ in events.append("record") })
    let connection = Connection(institution: "Fixture", hostname: "ssh.example.test", username: "fixture", keyReference: "/tmp/unused")
    try await supervisor.start(connection: connection, port: UInt16.random(in: 40000...60000), helper: URL(fileURLWithPath: "/usr/bin/true"), secrets: EmptyEpisodeSecrets())
    for _ in 0..<1000 { if supervisor.state == .connected { break }; await Task.yield() }
    #expect(events.prefix(2) == ["record", "ready"])
    try await supervisor.stop()
}

@Test @MainActor func unjournaledChildCleanupFailureBlocksConfigurationUntilDisconnect() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    let runner = EpisodeRunner()
    let supervisor = SSHSupervisor(runner: runner, readiness: { _, _ in
        runner.children.last?.refuseStop = true
        return true
    })
    var environment = fixture.environment(); environment.monitorEnabled = false
    environment.tunnel = supervisor
    environment.helper = URL(fileURLWithPath: "/usr/bin/true")
    environment.sleep = { _ in await Task.yield() }
    environment.installProxy = { _ in throw ProxyError.authorizationRequired }
    let controller = ApplicationController(environment: environment, startIPC: false)
    controller.socksPort = String(UInt16.random(in: 40000...60000))
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    _ = controller.execute(ControlRequest(.connect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    #expect(!controller.busy)
    try #require(runner.children.count == 1)
    #expect(supervisor.cleanupRequired)
    #expect(!controller.transaction.needsRecovery)
    #expect(controller.needsRecovery)
    #expect(controller.routingState == .degraded)
    #expect(controller.execute(ControlRequest(.status)).status?.reason == "processCleanupFailed")
    #expect(!controller.execute(ControlRequest(command: "route.add", domain: "new.example.test", pack: "custom")).success)
    runner.children.forEach { $0.refuseStop = false }
    let stopped = controller.execute(ControlRequest(.disconnect))
    for _ in 0..<1000 { if !controller.busy { break }; await Task.yield() }
    #expect(controller.execute(ControlRequest(command: "operation", id: stopped.operation?.id)).operation?.phase == .completed)
    #expect(!controller.needsRecovery)
}
