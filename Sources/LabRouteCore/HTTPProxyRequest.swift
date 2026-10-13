import Foundation

/// The request head a client sends to an HTTP proxy: either `CONNECT host:port`
/// (HTTPS, git, curl) or a plain-HTTP request with an absolute URI.
public struct HTTPProxyRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case connect, forward }
    public static let maximumHeadSize = 8192

    public let kind: Kind
    public let host: String
    public let port: UInt16
    /// For `.forward`: the head rewritten to origin-form for the target server.
    public let upstreamHead: [UInt8]
    /// Bytes of the client buffer consumed by the head; anything after belongs to the stream.
    public let headLength: Int

    /// Returns nil until the full head arrived.
    public static func parse(_ bytes: [UInt8]) throws -> HTTPProxyRequest? {
        guard let end = headEnd(bytes) else {
            if bytes.count >= maximumHeadSize { throw HTTPProxyError.badRequest }
            return nil
        }
        guard end <= maximumHeadSize, let head = String(bytes: bytes[..<(end - 4)], encoding: .utf8) else { throw HTTPProxyError.badRequest }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 3, ["HTTP/1.0", "HTTP/1.1"].contains(parts[2]), !parts[0].isEmpty,
              parts[0].utf8.allSatisfy({ (65...90).contains($0) }) else { throw HTTPProxyError.badRequest }
        let method = String(parts[0]), target = String(parts[1]), version = String(parts[2])

        if method == "CONNECT" {
            let (host, port) = try authority(target, defaultPort: nil)
            return HTTPProxyRequest(kind: .connect, host: host, port: port, upstreamHead: [], headLength: end)
        }
        guard target.lowercased().hasPrefix("http://") else { throw HTTPProxyError.badRequest }
        let rest = target.dropFirst(7)
        let split = rest.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? rest.endIndex
        let (host, port) = try authority(String(rest[..<split]), defaultPort: 80)
        var path = String(rest[split...])
        if path.isEmpty { path = "/" } else if path.hasPrefix("?") { path = "/" + path }

        var output = ["\(method) \(path) \(version)"]
        var hasHost = false
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else { throw HTTPProxyError.badRequest }
            let name = line[..<colon].lowercased()
            if ["proxy-connection", "proxy-authorization", "connection", "keep-alive"].contains(name) { continue }
            if name == "host" { hasHost = true }
            output.append(line)
        }
        if !hasHost { output.insert("Host: " + (port == 80 ? host : "\(host):\(port)"), at: 1) }
        output.append("Connection: close")
        let rewritten = Array((output.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        return HTTPProxyRequest(kind: .forward, host: host, port: port, upstreamHead: rewritten, headLength: end)
    }

    static func headEnd(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 3..<bytes.count where bytes[index] == 10 && bytes[index - 1] == 13 && bytes[index - 2] == 10 && bytes[index - 3] == 13 {
            return index + 1
        }
        return nil
    }

    static func authority(_ text: String, defaultPort: UInt16?) throws -> (String, UInt16) {
        var host: Substring, portText: Substring?
        if text.hasPrefix("[") {
            guard let close = text.firstIndex(of: "]") else { throw HTTPProxyError.badRequest }
            host = text[text.index(after: text.startIndex)..<close]
            let after = text[text.index(after: close)...]
            if !after.isEmpty { guard after.hasPrefix(":") else { throw HTTPProxyError.badRequest }; portText = after.dropFirst() }
        } else if let colon = text.lastIndex(of: ":") {
            host = text[..<colon]; portText = text[text.index(after: colon)...]
        } else { host = Substring(text) }
        let port: UInt16
        if let portText {
            guard let value = UInt16(portText), value > 0 else { throw HTTPProxyError.badRequest }
            port = value
        } else {
            guard let defaultPort else { throw HTTPProxyError.badRequest }
            port = defaultPort
        }
        guard !host.isEmpty, host.utf8.count <= 255,
              host.utf8.allSatisfy({ $0 > 32 && $0 < 127 && ![47, 64, 91, 93].contains($0) }) else { throw HTTPProxyError.badRequest }
        return (host.lowercased(), port)
    }
}

public enum HTTPProxyError: Error, Equatable { case badRequest }
