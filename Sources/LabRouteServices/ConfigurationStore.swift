import Foundation
import Darwin
import LabRouteCore

public struct ConfigurationStore: Sendable {
    public let url: URL
    public init(url: URL) { self.url = url }
    public func load() throws -> AppConfiguration? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard data.count <= 262144 else { throw StoreError.invalidConfiguration }
        var configuration = try JSONDecoder().decode(AppConfiguration.self, from: data)
        configuration.packs = RoutePack.merging(saved: configuration.packs, defaults: try RoutePack.defaults())
        try Self.validate(configuration)
        return configuration
    }
    public func save(_ configuration: AppConfiguration) throws {
        try Self.validate(configuration)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try PrivateFile.write(encoder.encode(configuration), to: url)
    }
    static func validate(_ value: AppConfiguration) throws {
        guard value.version == 1 else { throw StoreError.unsupportedVersion }
        let routes = value.packs.flatMap(\.routes)
        guard value.packs.count <= 20, routes.count <= 500,
              Set(value.packs.map(\.id)).count == value.packs.count,
              value.packs.allSatisfy({ !$0.id.isEmpty && $0.id.count <= 64 && $0.name.count <= 128 }),
              value.packs.allSatisfy({ Set($0.routes.map(\.id)).count == $0.routes.count && $0.routes.allSatisfy { !$0.id.isEmpty && $0.id.count <= 64 } }),
              (value.selectedServiceIDs ?? []).count <= 32,
              (value.selectedServiceIDs ?? []).allSatisfy({ !$0.isEmpty && $0.count <= 128 }),
              Set(value.selectedServiceIDs ?? []).count == (value.selectedServiceIDs ?? []).count else { throw StoreError.invalidConfiguration }
        if let connection = value.connection { try connection.validate() }
        let builtIns = try RoutePack.defaults()
        for pack in value.packs {
            for route in pack.routes where route.source == .builtIn {
                guard builtIns.contains(where: { $0.id == pack.id && $0.routes.contains(where: { $0.id == route.id && $0.domain == route.domain }) }) else {
                    throw StoreError.invalidConfiguration
                }
            }
        }
    }
}

public enum StoreError: Error { case unsupportedVersion, invalidConfiguration }

enum PrivateFile {
    static func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
        let parent = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY)
        guard parent >= 0 else { throw LocalSocket.posixError() }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw LocalSocket.posixError() }
    }
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = directory.appendingPathComponent(".labroute-" + UUID().uuidString)
        let descriptor = Darwin.open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                written += count
            }
        }
        // Flush the recovery record before making it visible, then flush the
        // directory entry before any system preference commit can happen.
        guard fsync(descriptor) == 0, rename(temporary.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let parent = Darwin.open(directory.path, O_RDONLY)
        guard parent >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(parent) }
        guard fsync(parent) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
