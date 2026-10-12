import Foundation

/// Exists before proxy authorization: a crash must not strand a managed tunnel.
public struct RuntimeProcessStore: Sendable {
    public let url: URL
    public var needsRecovery: Bool { FileManager.default.fileExists(atPath: url.path) }
    public init(url: URL) { self.url = url }
    public func record(_ identity: OwnedSSHProcess?) throws {
        if let identity { try PrivateFile.write(JSONEncoder().encode(identity), to: url) }
        else if needsRecovery {
            let previous = try JSONDecoder().decode(OwnedSSHProcess.self, from: Data(contentsOf: url))
            guard OwnedSSHProcess.capture(previous.pid) != previous else { throw SSHFailure.cleanup }
            try PrivateFile.remove(url)
        }
    }
    public func cleanup() async throws {
        guard needsRecovery else { return }
        let identity = try JSONDecoder().decode(OwnedSSHProcess.self, from: Data(contentsOf: url))
        try await identity.stopIfStillOwned()
        try PrivateFile.remove(url)
    }
}
