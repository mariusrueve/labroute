import Foundation
import Darwin

public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    public var environment: [String: String]
    public var input: Data?
    public init(_ executable: String, _ arguments: [String], environment: [String: String] = [:], input: Data? = nil) {
        self.executable = executable; self.arguments = arguments; self.environment = environment; self.input = input
    }
}

@MainActor public protocol ChildProcess: AnyObject {
    var pid: Int32 { get }
    var running: Bool { get }
    var exitStatus: Int32 { get }
    var output: Data { get }
    var diagnostic: String { get }
    func stop() async throws
    func waitForExit(timeout: Duration?) async throws
    func waitForCompletion(timeout: Duration) async throws
}
// Defaults are for injected test children. System children use event notifications.
public extension ChildProcess {
    func waitForExit(timeout: Duration? = nil) async throws {
        let deadline = timeout.map { ContinuousClock.now + $0 }
        while running {
            try Task.checkCancellation()
            if let deadline, ContinuousClock.now >= deadline { throw RuntimeError.message("Process completion timed out.") }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
    func waitForCompletion(timeout: Duration) async throws { try await waitForExit(timeout: timeout) }
}

final class CompletionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func finish() {
        lock.lock(); done = true; let pending = Array(waiters.values); waiters.removeAll(); lock.unlock()
        for waiter in pending { waiter.resume() }
    }
    private func resolve(_ id: UUID, error: any Error) {
        lock.lock(); let waiter = waiters.removeValue(forKey: id); lock.unlock()
        waiter?.resume(throwing: error)
    }
    private func register(_ id: UUID, _ waiter: CheckedContinuation<Void, any Error>) {
        lock.lock()
        if done { lock.unlock(); waiter.resume(); return }
        waiters[id] = waiter; lock.unlock()
    }
    func wait(timeout: Duration?, cancellable: Bool = true) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                register(id, waiter)
                if cancellable && Task.isCancelled { resolve(id, error: CancellationError()) }
                if let timeout {
                    let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + max(0, seconds)) { [weak self] in
                        self?.resolve(id, error: RuntimeError.message("Process completion timed out."))
                    }
                }
            }
        } onCancel: {
            if cancellable { self.resolve(id, error: CancellationError()) }
        }
    }
}

private final class ProcessCompletion: @unchecked Sendable {
    let exited = CompletionSignal(), drained = CompletionSignal()
    private let lock = NSLock()
    private var exitSeen = false
    private var eofStreams = Set<Int>()
    func exit() { lock.lock(); exitSeen = true; let ready = eofStreams.count == 2; lock.unlock(); exited.finish(); if ready { drained.finish() } }
    func eof(_ stream: Int) { lock.lock(); eofStreams.insert(stream); let ready = exitSeen && eofStreams.count == 2; lock.unlock(); if ready { drained.finish() } }
}

@MainActor public protocol ProcessRunner {
    func start(_ spec: ProcessSpec) throws -> any ChildProcess
}

private final class BoundedBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = Data()
    func append(_ data: Data) { lock.lock(); defer { lock.unlock() }; bytes.append(data.prefix(max(0, 65536 - bytes.count))) }
    var data: Data { lock.lock(); defer { lock.unlock() }; return bytes }
}

@MainActor public final class SystemProcessRunner: ProcessRunner {
    public init() {}
    public func start(_ spec: ProcessSpec) throws -> any ChildProcess { try SystemChild(spec) }
}

@MainActor private final class SystemChild: ChildProcess {
    private let process = Process()
    private let stdout = Pipe(), stderr = Pipe(), stdin = Pipe()
    private let out = BoundedBuffer(), err = BoundedBuffer()
    private let completion = ProcessCompletion()
    var pid: Int32 { process.processIdentifier }
    var running: Bool { process.isRunning }
    var exitStatus: Int32 { running ? -1 : process.terminationStatus }
    var output: Data { out.data }
    var diagnostic: String { String(decoding: err.data, as: UTF8.self) }
    init(_ spec: ProcessSpec) throws {
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        // Do not inherit SSH configuration or secret-bearing agent environment.
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": NSHomeDirectory(), "LANG": "C"]
            .merging(spec.environment) { _, value in value }
        process.standardOutput = stdout; process.standardError = stderr; process.standardInput = stdin
        process.terminationHandler = { [completion] _ in completion.exit() }
        stdout.fileHandleForReading.readabilityHandler = { [out, completion] handle in
            let data = handle.availableData; out.append(data)
            if data.isEmpty { handle.readabilityHandler = nil; completion.eof(0) }
        }
        stderr.fileHandleForReading.readabilityHandler = { [err, completion] handle in
            let data = handle.availableData; err.append(data)
            if data.isEmpty { handle.readabilityHandler = nil; completion.eof(1) }
        }
        do { try process.run() } catch {
            stdout.fileHandleForReading.readabilityHandler = nil
            stderr.fileHandleForReading.readabilityHandler = nil
            throw error
        }
        let writer = stdin.fileHandleForWriting
        Task.detached {
            if let input = spec.input { try? writer.write(contentsOf: input) }
            try? writer.close()
        }
    }
    func waitForExit(timeout: Duration? = nil) async throws { try await completion.exited.wait(timeout: timeout) }
    func waitForCompletion(timeout: Duration) async throws { try await completion.drained.wait(timeout: timeout) }
    func stop() async throws {
        if running {
            process.terminate()
            do { try await completion.exited.wait(timeout: .seconds(1), cancellable: false) }
            catch {
                // A child reference is retained if it cannot be confirmed dead.
                if running { Darwin.kill(pid, SIGKILL) }
                try await completion.exited.wait(timeout: .seconds(4), cancellable: false)
            }
        }
        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        try? stdout.fileHandleForReading.close(); try? stderr.fileHandleForReading.close()
        try? stdin.fileHandleForWriting.close()
    }
}

@MainActor public func collect(_ spec: ProcessSpec, runner: any ProcessRunner, timeout: Duration = .seconds(45), started: ((Int32) -> Void)? = nil) async throws -> (Int32, Data, String) {
    let child = try runner.start(spec)
    started?(child.pid)
    do {
        try await child.waitForCompletion(timeout: timeout)
        return (child.exitStatus, child.output, child.diagnostic)
    } catch { try await child.stop(); throw error }
}

public enum RuntimeError: Error, LocalizedError, Sendable {
    case message(String)
    public var errorDescription: String? { if case .message(let text) = self { text } else { nil } }
}
