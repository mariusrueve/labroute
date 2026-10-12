import Foundation
import Network

/// An intentionally small, loopback-only HTTP endpoint. It never logs requests.
@MainActor
public final class PACServer {
    public private(set) var port: UInt16?
    public var isReady: Bool { port != nil && listener != nil }
    public var changed: ((Bool) -> Void)?
    private var listener: NWListener?
    private var pendingStart: CheckedContinuation<UInt16, any Error>?
    private var startTimeout: Task<Void, Never>?
    private var clients: [UUID: NWConnection] = [:]
    private var timeouts: [UUID: Task<Void, Never>] = [:]
    private var script = ""

    public init() {}

    public func start(script: String, port: UInt16 = 0) async throws -> UInt16 {
        guard listener == nil else { throw ServerError.alreadyRunning }
        self.script = script
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                guard let self, self.listener === listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else { return }
                    self.port = port
                    self.changed?(true)
                    self.pendingStart?.resume(returning: port)
                    self.pendingStart = nil
                    self.startTimeout?.cancel(); self.startTimeout = nil
                case .failed(let error):
                    self.pendingStart?.resume(throwing: error)
                    self.pendingStart = nil
                    self.stop()
                default: break
                }
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                pendingStart = continuation
                if Task.isCancelled { stop(); return }
                startTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(5)) } catch { return }
                    guard let self, self.listener === listener, self.pendingStart != nil else { return }
                    self.pendingStart?.resume(throwing: ServerError.startTimedOut); self.pendingStart = nil
                    self.stop()
                }
                listener.start(queue: .main)
            }
        } onCancel: { [weak self] in
            Task { @MainActor in if self?.listener === listener { self?.stop() } }
        }
    }

    public func update(script: String) { self.script = script }

    public func stop() {
        pendingStart?.resume(throwing: CancellationError())
        pendingStart = nil
        startTimeout?.cancel(); startTimeout = nil
        listener?.stateUpdateHandler = nil
        listener?.newConnectionHandler = nil
        listener?.cancel()
        listener = nil
        port = nil
        changed?(false)
        for connection in clients.values { connection.cancel() }
        for timeout in timeouts.values { timeout.cancel() }
        clients.removeAll()
        timeouts.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard listener != nil, clients.count < 32 else { connection.cancel(); return }
        let id = UUID()
        clients[id] = connection
        connection.start(queue: .main)
        timeouts[id] = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            self?.close(id)
        }
        receive(connection, id: id, buffer: Data())
    }

    private func receive(_ connection: NWConnection, id: UUID, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192 - buffer.count) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.clients[id] != nil else { return }
                let accumulated = buffer + (data ?? Data())
                if let end = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                    let header = String(decoding: accumulated[..<end.upperBound], as: UTF8.self)
                    let parts = header.components(separatedBy: "\r\n")[0].split(separator: " ")
                    let valid = parts.count == 3 && parts[0] == "GET" && parts[1] == "/proxy.pac"
                    let body = Data((valid ? self.script : "Not found").utf8)
                    let status = valid ? "200 OK" : "404 Not Found"
                    let response = Data("HTTP/1.1 \(status)\r\nContent-Type: application/x-ns-proxy-autoconfig; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".utf8) + body
                    connection.send(content: response, completion: .contentProcessed { [weak self] _ in
                        Task { @MainActor in self?.close(id) }
                    })
                } else if complete || error != nil || accumulated.count >= 8192 {
                    self.close(id)
                } else {
                    self.receive(connection, id: id, buffer: accumulated)
                }
            }
        }
    }

    private func close(_ id: UUID) {
        clients.removeValue(forKey: id)?.cancel()
        timeouts.removeValue(forKey: id)?.cancel()
    }
}

public enum ServerError: Error { case alreadyRunning, startTimedOut }
