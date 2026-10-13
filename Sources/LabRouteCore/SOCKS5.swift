import Foundation

/// SOCKS5 client framing (RFC 1928), no authentication. Hostnames are sent as
/// ATYP domain so the lab server resolves them, like Chromium's SOCKS5 PAC entry.
public enum SOCKS5 {
    public static let greeting: [UInt8] = [5, 1, 0]

    public enum GreetingReply: Equatable, Sendable { case needMore, accepted, rejected }
    public static func parseGreeting(_ bytes: [UInt8]) -> GreetingReply {
        guard bytes.count >= 2 else { return .needMore }
        return bytes[0] == 5 && bytes[1] == 0 ? .accepted : .rejected
    }

    public static func connectRequest(host: String, port: UInt16) throws -> [UInt8] {
        let name = Array(host.utf8)
        guard !name.isEmpty, name.count <= 255, port > 0,
              name.allSatisfy({ $0 > 32 && $0 < 127 }) else { throw SOCKS5Error.invalidTarget }
        return [5, 1, 0, 3, UInt8(name.count)] + name + [UInt8(port >> 8), UInt8(port & 0xff)]
    }

    public enum Reply: Equatable, Sendable {
        case needMore
        /// Total length of the reply, so callers keep any bytes that follow it.
        case success(length: Int)
        case failure(code: UInt8)
    }
    public static func parseReply(_ bytes: [UInt8]) -> Reply {
        guard bytes.count >= 2 else { return .needMore }
        guard bytes[0] == 5 else { return .failure(code: 1) }
        guard bytes[1] == 0 else { return .failure(code: bytes[1]) }
        guard bytes.count >= 5 else { return .needMore }
        let address: Int
        switch bytes[3] {
        case 1: address = 4
        case 4: address = 16
        case 3: address = 1 + Int(bytes[4])
        default: return .failure(code: 1)
        }
        let length = 4 + address + 2
        return bytes.count >= length ? .success(length: length) : .needMore
    }

    public static func describe(_ code: UInt8) -> String {
        switch code {
        case 2: "connection not allowed by the server"
        case 3: "network unreachable from the lab server"
        case 4: "host unreachable from the lab server"
        case 5: "connection refused by the target host"
        case 6: "TTL expired"
        case 7: "command not supported"
        case 8: "address type not supported"
        default: "the SSH tunnel could not open the connection"
        }
    }
}

public enum SOCKS5Error: Error, LocalizedError, Equatable {
    case invalidTarget, rejected, failed(UInt8)
    public var errorDescription: String? {
        switch self {
        case .invalidTarget: "Invalid target host or port."
        case .rejected: "The SOCKS proxy rejected the handshake."
        case .failed(let code): "Tunnel connection failed: " + SOCKS5.describe(code) + "."
        }
    }
}
