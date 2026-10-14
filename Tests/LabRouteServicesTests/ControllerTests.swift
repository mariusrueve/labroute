import Foundation
import Testing
import LabRouteCore
@testable import LabRouteServices

@MainActor private func fixture() throws -> (FixtureEnvironment, ApplicationController) {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    return (fixture, ApplicationController(environment: environment, startIPC: false))
}
@MainActor private func settled(_ controller: ApplicationController, _ response: ControlResponse) async throws -> ControlResponse {
    let id = try #require(response.operation?.id)
    for _ in 0..<1000 {
        let state = controller.execute(ControlRequest(command: "operation", id: id))
        if state.operation?.terminal == true { return state }
        try await Task.sleep(for: .milliseconds(2))
    }
    throw RuntimeError.message("Test operation did not settle")
}
@Test @MainActor func controllerSerializesCommandsAndRestores() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let accepted = controller.execute(ControlRequest(.connect))
    #expect(accepted.operation?.phase == .running)
    #expect(controller.execute(ControlRequest(.connect)).errorCode == .busy)
    #expect(try await settled(controller, accepted).operation?.phase == .completed)
    #expect(controller.execute(ControlRequest(.status)).status?.routing == .active)
    controller.handleSleep()
    #expect(controller.execute(ControlRequest(.status)).status?.routing == .degraded)
    controller.handleWake()
    #expect(controller.execute(ControlRequest(.status)).status?.routing == .active)
    fixture.activeServices = []
    controller.revalidate()
    #expect(controller.execute(ControlRequest(.status)).status?.routing == .degraded)
    fixture.activeServices = ["fixture-wifi"]; controller.revalidate()
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
    #expect(!controller.needsRecovery)
}
@Test @MainActor func controllerRetainsRecoveryOnAuthorizationAndExternalEditFailures() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    fixture.proxy.refuseCommit = true
    #expect(try await settled(controller, controller.execute(ControlRequest(.connect))).operation?.phase == .failed)
    #expect(controller.needsRecovery)
    fixture.proxy.refuseCommit = false
    fixture.proxy.current["fixture-wifi"] = try ProxySnapshot(enabled: true, dictionary: ["HTTPEnable": 1])
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).operation?.phase == .failed)
    #expect(controller.needsRecovery)
    #expect(try fixture.proxy.current["fixture-wifi"]?.dictionary()?["HTTPEnable"] as? Int == 1)
    // Restore fixture ownership explicitly, never touch real preferences.
    let journal = try ProxyTransaction(journalURL: fixture.root.appendingPathComponent("journal.json")).record()
    fixture.proxy.current = try #require(journal).original
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
}
@Test @MainActor func controllerCancellationAndProtocolCompatibility() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    var legacy = ControlRequest(.status); legacy.version = 1
    let response = try JSONDecoder().decode(ControlResponse.self, from: controller.dispatch(JSONEncoder().encode(legacy)))
    #expect(response.version == 1 && response.success)
    legacy.version = 99
    #expect(controller.execute(legacy).errorCode == .unsupportedVersion)
    let malformed = try JSONDecoder().decode(ControlResponse.self, from: controller.dispatch(Data("{".utf8)))
    #expect(malformed.errorCode == .invalidRequest)
    let start = controller.execute(ControlRequest(.connect))
    #expect(controller.execute(ControlRequest(.cancel)).success)
    #expect(try await settled(controller, start).operation?.phase == .cancelled)
    #expect(!controller.needsRecovery)
    #expect(controller.execute(ControlRequest(command: "preference.set", id: "launchAtLogin", enabled: true)).success == false)
}
@Test @MainActor func controllerUsesSharedRoutesAndRejectsCorruptConfiguration() throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    controller.setup()
    #expect(controller.error == "Credential onboarding is disabled in fixtures.")
    #expect(!controller.busy)
    controller.domain = "a.example.test"; controller.addRoute()
    #expect(controller.execute(ControlRequest(.routes)).routes?.first?.routes.count == 2)
    controller.setPack("custom", enabled: false)
    #expect(controller.execute(ControlRequest(.routes)).routes?.first?.enabled == false)
    try Data("invalid".utf8).write(to: fixture.root.appendingPathComponent("configuration.json"))
    var environment = fixture.environment(); environment.monitorEnabled = false
    let recovered = ApplicationController(environment: environment, startIPC: false)
    #expect(recovered.execute(ControlRequest(.connect)).errorCode == .setupRequired)
}

@MainActor private final class AsyncGate {
    var entered = false
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

@Test @MainActor func transactionKeepsStatusResponsiveAndDefersCancellation() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    let install = environment.installProxy, gate = AsyncGate()
    environment.installProxy = { activation in await gate.wait(); try await install(activation) }
    let controller = ApplicationController(environment: environment, startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let accepted = controller.execute(ControlRequest(.connect))
    for _ in 0..<1000 { if gate.entered { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(gate.entered)
    #expect(controller.execute(ControlRequest(.status)).humanInteraction == "systemAuthorization")
    let cancel = controller.execute(ControlRequest(.cancel))
    #expect(cancel.cancellationDeferred == true)
    #expect(controller.execute(ControlRequest(.status)).operation?.phase == .running)
    gate.release()
    #expect(try await settled(controller, accepted).operation?.phase == .cancelled)
    #expect(controller.needsRecovery)
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
}

@Test @MainActor func operationResultDoesNotDependOnPresentationError() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    let restore = environment.restoreProxy, gate = AsyncGate()
    environment.restoreProxy = { await gate.wait(); return try await restore() }
    let controller = ApplicationController(environment: environment, startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let accepted = controller.execute(ControlRequest(.disconnect))
    for _ in 0..<1000 { if gate.entered { break }; await Task.yield() }
    controller.error = "Unrelated presentation message"
    gate.release()
    #expect(try await settled(controller, accepted).operation?.phase == .completed)
}

@Test @MainActor func recoveryRequiresEffectiveSettingsNotJustSSH() async throws {
    let (fixture, original) = try fixture()
    #expect(try await settled(original, original.execute(ControlRequest(.connect))).success)
    original.server.stop(); original.shutdownControl(); await fixture.tunnel.stop()
    var environment = fixture.environment(); environment.monitorEnabled = false
    environment.effectivePAC = { nil }
    environment.sleep = { _ in await Task.yield() }
    let recovered = ApplicationController(environment: environment, startIPC: false)
    defer { recovered.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let result = try await settled(recovered, recovered.execute(ControlRequest(.recover)))
    #expect(result.operation?.phase == .failed)
    #expect(recovered.needsRecovery)
    #expect(recovered.routingState == .degraded)
    #expect(try await settled(recovered, recovered.execute(ControlRequest(.disconnect))).success)
}

@Test @MainActor func quitWaitsForTerminalResponseAndRejectsMutations() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownTask?.cancel(); controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    var terminated = false
    controller.terminate = { terminated = true }
    let data = controller.dispatch(try JSONEncoder().encode(ControlRequest(.quit)), peerPID: 42)
    let accepted = try JSONDecoder().decode(ControlResponse.self, from: data)
    controller.responseDelivered(data)
    let finished = try await settled(controller, accepted)
    #expect(!terminated)
    #expect(controller.execute(ControlRequest(.connect)).errorCode == .busy)
    #expect(controller.execute(ControlRequest(command: "preference.set", id: "autoConnect", enabled: true)).errorCode == .busy)
    controller.responseDelivered(try JSONEncoder().encode(finished), peerPID: 99)
    await Task.yield()
    #expect(!terminated)
    controller.responseDelivered(try JSONEncoder().encode(finished), peerPID: 42)
    for _ in 0..<1000 { if terminated { break }; await Task.yield() }
    #expect(terminated)
}

private func waitSynchronously(_ semaphore: DispatchSemaphore) { semaphore.wait() }

@Test func proxyWorkerDoesNotBlockMainActorAndSerializesWork() async throws {
    let worker = ProxyWorker(journal: URL(fileURLWithPath: "/tmp/unused-labroute-worker-test"))
    let blocked = DispatchSemaphore(value: 0), entered = DispatchSemaphore(value: 0)
    let first = Task { try await worker.run { entered.signal(); blocked.wait(); return 1 } }
    await Task.detached { waitSynchronously(entered) }.value
    let second = Task { try await worker.run { 2 } }
    let responsive = await MainActor.run { true }
    #expect(responsive)
    blocked.signal()
    #expect(try await first.value == 1)
    #expect(try await second.value == 2)
}

@Test @MainActor func lateRecoveryUpdateCannotOverwriteDisconnect() async throws {
    let fixture = try FixtureEnvironment(id: UUID().uuidString)
    var environment = fixture.environment(); environment.monitorEnabled = false
    let gate = AsyncGate()
    environment.updateProxyProcess = { _ in await gate.wait(); throw ProxyError.invalidJournal }
    let controller = ApplicationController(environment: environment, startIPC: false)
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try await settled(controller, controller.execute(ControlRequest(.connect))).success)
    controller.handleSleep(); controller.handleWake()
    for _ in 0..<1000 { if gate.entered { break }; await Task.yield() }
    #expect(gate.entered)
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
    gate.release()
    for _ in 0..<20 { await Task.yield() }
    #expect(controller.error == nil)
    #expect(controller.routingState == .inactive)
}

@Test @MainActor func failedQuitKeepsRecoveryCommandsAvailable() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    var terminated = false; controller.terminate = { terminated = true }
    var quitFailed = false; controller.quitFailed = { quitFailed = true }
    #expect(try await settled(controller, controller.execute(ControlRequest(.connect))).success)
    let journal = try ProxyTransaction(journalURL: fixture.root.appendingPathComponent("journal.json")).record()
    fixture.proxy.current["fixture-wifi"] = try ProxySnapshot(enabled: true, dictionary: ["HTTPEnable": 1])
    #expect(try await settled(controller, controller.execute(ControlRequest(.quit))).operation?.phase == .failed)
    #expect(!terminated && quitFailed && !controller.shutdownRequested && controller.needsRecovery)
    fixture.proxy.current = try #require(journal).original
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
}

@Test @MainActor func networkRecoveryClearsOnlyItsOwnWarning() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try await settled(controller, controller.execute(ControlRequest(.connect))).success)
    fixture.activeServices = []
    controller.revalidate()
    #expect(controller.error != nil)
    fixture.activeServices = ["fixture-wifi"]
    controller.revalidate()
    #expect(controller.routingState == .active)
    #expect(controller.error == nil)
    fixture.activeServices = []
    controller.revalidate()
    controller.error = "An unrelated configuration operation failed"
    fixture.activeServices = ["fixture-wifi"]
    controller.revalidate()
    #expect(controller.error == "An unrelated configuration operation failed")
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
}
@Test @MainActor func routesCanBeEditedWhileConnected() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try await settled(controller, controller.execute(ControlRequest(.connect))).operation?.phase == .completed)
    let pacURL = try #require(URL(string: controller.pacURL))
    #expect(controller.execute(ControlRequest(command: "route.add", domain: "intranet.example.test", pack: "internal")).success)
    let (body, _) = try await URLSession(configuration: .ephemeral).data(from: pacURL)
    #expect(String(decoding: body, as: UTF8.self).contains("\"intranet.example.test\""))
    let journal = try #require(try ProxyTransaction(journalURL: fixture.root.appendingPathComponent("journal.json")).record())
    #expect(journal.runtime?.domains.contains(try Domain("intranet.example.test")) == true)
    #expect(try ConfigurationStore(url: fixture.root.appendingPathComponent("configuration.json")).load()?.packs
        .first { $0.id == "internal" }?.routes.contains { $0.domain.value == "intranet.example.test" } == true)
    // Removing every route while connected would leave an empty PAC and recovery record.
    controller.setPack("publications", enabled: false); controller.setPack("custom", enabled: false)
    #expect(controller.error == nil)
    #expect(!controller.execute(ControlRequest(command: "pack.set", id: "internal", enabled: false)).success)
    #expect(!RouteSet(packs: controller.packs).domains.isEmpty)
    #expect(controller.routingState == .active)
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
}
@Test @MainActor func routeEditsExplainFailuresAndRemoveUserDomains() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    let invalid = controller.execute(ControlRequest(command: "route.add", domain: "not a domain"))
    #expect(invalid.errorCode == .invalidRequest && invalid.message == DomainError.invalid.localizedDescription)
    controller.domain = "not a domain"; controller.addRoute()
    #expect(controller.error == DomainError.invalid.localizedDescription)
    #expect(controller.execute(ControlRequest(command: "route.remove", domain: "nature.com")).message == RouteEditError.builtIn.localizedDescription)
    // While connected, the last enabled domain cannot be removed.
    #expect(try await settled(controller, controller.execute(ControlRequest(.connect))).success)
    controller.setPack("publications", enabled: false)
    let last = controller.execute(ControlRequest(command: "route.remove", domain: "selected.labroute.test"))
    #expect(last.errorCode == .invalidRequest && last.message.hasPrefix("Keep at least one domain"))
    #expect(try await settled(controller, controller.execute(ControlRequest(.disconnect))).success)
    controller.removeRoute("selected.labroute.test")
    #expect(controller.error == nil && !RouteSet(packs: controller.packs).matches(host: "selected.labroute.test"))
    #expect(try ConfigurationStore(url: fixture.root.appendingPathComponent("configuration.json")).load()?.packs
        .flatMap(\.routes).contains { $0.domain.value == "selected.labroute.test" } == false)
}
@Test @MainActor func labSetupImportAddsOnlyWhatIsMissing() throws {
    let (fixtureA, a) = try fixture(), (fixtureB, b) = try fixture()
    defer {
        a.shutdownControl(); b.shutdownControl()
        try? FileManager.default.removeItem(at: fixtureA.root); try? FileManager.default.removeItem(at: fixtureB.root)
    }
    #expect(a.execute(ControlRequest(command: "route.add", domain: "wiki.lab.example", pack: "internal")).success)
    #expect(a.saveSSH(SSHIntegration(hosts: [SSHHostEntry(aliases: ["gerrit"], hostname: "gerrit.lab.example", user: "someone",
        identityFile: "~/.ssh/id_gerrit", extraOptions: ["LocalForward 8080 localhost:80"])])))
    let data = try a.labSetupData()
    let text = String(decoding: data, as: UTF8.self)
    for personal in ["fixture-key", "\"fixture\"", "someone", "id_gerrit", "LocalForward"] { #expect(!text.contains(personal)) }

    let connection = b.configuredConnection
    #expect(b.importLabSetup(data) && b.importLabSetup(data))
    #expect(b.error == nil)
    #expect(b.packs.first { $0.id == "internal" }?.routes.map(\.domain.value) == ["wiki.lab.example"])
    #expect(b.sshIntegration.hosts.map(\.hostname) == ["gerrit.lab.example"])
    #expect(b.sshIntegration.hosts.first?.user == "fixture" && b.sshIntegration.hosts.first?.extraOptions == [])
    #expect(b.configuredConnection == connection)

    let store = ConfigurationStore(url: fixtureB.root.appendingPathComponent("configuration.json"))
    let saved = try store.load()
    #expect(!b.importLabSetup(Data("{\"labroute\": 2}".utf8)))
    #expect(b.error == LabSetupError.invalid.localizedDescription)
    #expect(try store.load() == saved)
}
@Test @MainActor func quitWhileConnectedRestoresBeforeTerminating() async throws {
    let (fixture, controller) = try fixture()
    defer { controller.shutdownControl(); try? FileManager.default.removeItem(at: fixture.root) }
    var terminated = false; controller.terminate = { terminated = true }
    #expect(try await settled(controller, controller.execute(ControlRequest(.connect))).success)
    let original = try #require(try ProxyTransaction(journalURL: fixture.root.appendingPathComponent("journal.json")).record()).original
    controller.quit()
    for _ in 0..<1000 { if terminated { break }; try await Task.sleep(for: .milliseconds(2)) }
    #expect(terminated && controller.isShuttingDown)
    #expect(fixture.proxy.current == original)
    #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("journal.json").path))
}
