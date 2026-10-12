import Foundation
import Darwin
import LabRouteCore

/// Sole owner of one tunnel. Replacements start only after the old child exits.
/// Readiness checks the child's listener, rather than trusting an arbitrary port.
@MainActor public final class SSHSupervisor {
    public private(set) var state: TunnelState = .disabled
    public private(set) var port: UInt16?
    public var ownedProcess: OwnedSSHProcess? { child.flatMap { OwnedSSHProcess.capture($0.pid) } }
    public var cleanupRequired: Bool { child != nil && state == .error }
    public var changed: ((TunnelState, String?) -> Void)?
    private let runner: any ProcessRunner
    private let readiness: @MainActor (Int32, UInt16) async throws -> Bool
    private var task: Task<Void, Never>?
    private var child: (any ChildProcess)?
    private var session: CredentialSession?
    private var stopping = false
    private var starting = false
    private var suspended = false
    private var lifecycle = 0
    private var wakeEpoch = 0
    private var wakeWaiter: CheckedContinuation<Void, Never>?
    private var exitWait: Task<Void, any Error>?
    private let sleep: (Duration) async throws -> Void
    private let retryDelay: (Int) -> Double
    private let now: () -> ContinuousClock.Instant
    private let recordProcess: (OwnedSSHProcess?) throws -> Void
    private let requiresProcessIdentity: Bool

    public init(runner: any ProcessRunner = SystemProcessRunner(),
                readiness: (@MainActor (Int32, UInt16) async throws -> Bool)? = nil,
                sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
                retryDelay: @escaping (Int) -> Double = { SSHOptions.retryDelay(attempt: $0) },
                now: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now },
                recordProcess: @escaping (OwnedSSHProcess?) throws -> Void = { _ in }, requiresProcessIdentity: Bool = false) {
        self.runner = runner
        self.sleep = sleep; self.retryDelay = retryDelay; self.now = now
        self.recordProcess = recordProcess
        self.requiresProcessIdentity = requiresProcessIdentity
        self.readiness = readiness ?? { pid, port in
            let result = try await collect(ProcessSpec("/usr/sbin/lsof",
                ["-nP", "-a", "-p", String(pid), "-iTCP:" + String(port), "-sTCP:LISTEN", "-Fn"]),
                runner: SystemProcessRunner(), timeout: .seconds(3))
            return result.0 == 0 && String(decoding: result.1, as: UTF8.self)
                .split(separator: "\n").contains(Substring("n127.0.0.1:" + String(port)))
        }
    }

    public func start(connection: Connection, port: UInt16, helper: URL,
                      secrets: any KeySecretStore = KeychainSecrets()) async throws {
        guard task == nil, child == nil, !stopping, !starting else { throw RuntimeError.message("A tunnel operation is already in progress.") }
        starting = true
        let generation = lifecycle
        defer { starting = false }
        try Self.requireAvailable(port)
        let passphrase = try await Task.detached { try secrets.read(connection.id.uuidString) }.value
        try Task.checkCancellation()
        guard generation == lifecycle else { throw CancellationError() }
        let credentials = try CredentialSession(helper: helper, passphrase: passphrase, interactive: false) { _ in nil }
        let arguments = try SSHOptions.tunnel(connection, knownHosts: SSHOnboarding.knownHosts(connection), port: port)
        session = credentials
        self.port = port
        set(.connecting)
        task = Task { [self] in
            defer { credentials.stop(); session = nil; task = nil }
            var failures = 0
            while !Task.isCancelled {
                do {
                    while suspended { await withCheckedContinuation { wakeWaiter = $0 }; try Task.checkCancellation() }
                    try Task.checkCancellation()
                    try Self.requireAvailable(port)
                    let epoch = wakeEpoch
                    let process: any ChildProcess
                    do { process = try runner.start(ProcessSpec("/usr/bin/ssh", arguments, environment: credentials.environment)) }
                    catch { throw SSHFailure.configuration }
                    child = process; credentials.allowedPID = process.pid
                    let identity = OwnedSSHProcess.capture(process.pid)
                    if requiresProcessIdentity && identity == nil { throw SSHFailure.cleanup }
                    try recordProcess(identity)
                    let deadline = now() + .seconds(25)
                    var readyAt: ContinuousClock.Instant?
                    while process.running && !Task.isCancelled && !suspended && epoch == wakeEpoch && readyAt == nil {
                        if try await readiness(process.pid, port), process.running {
                            readyAt = now(); set(.connected)
                        } else if now() >= deadline { throw RuntimeError.message("SSH did not establish its local forwarding listener in time.") }
                        else { try await sleep(.milliseconds(500)) }
                    }
                    if readyAt != nil && !suspended && epoch == wakeEpoch && process.running {
                        let waiter = Task { @MainActor in try await process.waitForExit(timeout: nil) }
                        exitWait = waiter
                        do { try await waiter.value }
                        catch { if !suspended && epoch == wakeEpoch { throw error } }
                        exitWait = nil
                    }
                    try Task.checkCancellation()
                    if suspended || epoch != wakeEpoch {
                        try await stopChild(); credentials.allowedPID = nil
                        continue
                    }
                    if let readyAt, now() - readyAt >= .seconds(60) { failures = 0 }
                    // Diagnostic pipes must finish before classifying a terminal error.
                    try await process.waitForCompletion(timeout: .seconds(4))
                    let failure = SSHOptions.classify(process.diagnostic)
                    try await stopChild(); credentials.allowedPID = nil
                    guard failure.retry else { set(.error, failure.message); return }
                    throw RuntimeError.message(failure.message)
                } catch {
                    exitWait?.cancel(); exitWait = nil
                    do { try await stopChild() }
                    catch { set(.error, "The owned SSH process could not be stopped. Recovery is required before retrying."); return }
                    credentials.allowedPID = nil
                    if Task.isCancelled { break }
                    if error is SSHFailure { set(.error, error.localizedDescription); return }
                    failures += 1
                    guard failures <= 6 else {
                        set(.error, "SSH reconnect attempts exhausted. Check your network and reconnect manually.")
                        return
                    }
                    set(.reconnecting, error.localizedDescription)
                    do { try await sleep(.seconds(retryDelay(failures - 1))) }
                    catch { break }
                }
            }
            do { try await stopChild() }
            catch { set(.error, "The owned SSH process could not be stopped. Recovery is required.") }

        }
    }

    public func suspend() {
        suspended = true
        wakeEpoch += 1
        exitWait?.cancel()
        if task != nil || starting { set(.reconnecting, "Mac asleep · routing rules retained") }
    }

    public func resume() {
        suspended = false
        wakeWaiter?.resume(); wakeWaiter = nil
        if task != nil { set(.reconnecting, "Resuming SSH on the existing endpoint") }
    }

    public func stop() async throws {
        stopping = true
        lifecycle += 1
        set(.disconnecting)
        let pending = task
        pending?.cancel(); exitWait?.cancel()
        wakeWaiter?.resume(); wakeWaiter = nil
        await pending?.value
        do { try await stopChild() } catch { stopping = false; set(.error, "The owned SSH process has not exited."); throw error }
        port = nil
        stopping = false
        set(.disabled)
    }

    private func stopChild() async throws {
        guard let process = child else { return }
        try await process.stop()
        guard !process.running else { throw SSHFailure.cleanup }
        try recordProcess(nil)
        child = nil
    }

    private func set(_ state: TunnelState, _ message: String? = nil) {
        self.state = state; changed?(state, message)
    }

    public static func requireAvailable(_ port: UInt16) throws {
        guard port > 1023 else { throw RuntimeError.message("Choose an unprivileged SOCKS port above 1023.") }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LocalSocket.posixError() }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { throw SSHFailure.occupiedPort }
    }
}

public enum SSHFailure: Error, LocalizedError {
    case occupiedPort, configuration, cleanup
    public var errorDescription: String? {
        switch self {
        case .occupiedPort: "The managed SOCKS port is occupied. Resolve the conflicting listener, then reconnect."
        case .configuration: "SSH could not be launched. Check the application and connection configuration."
        case .cleanup: "The owned SSH process has not exited. Recovery is required."
        }
    }
}
