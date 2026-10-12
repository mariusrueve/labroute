import Foundation

public struct Domain: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public let value: String
    public var description: String { value }

    public init(_ input: String) throws {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let urlText = text.contains("://") ? text : "https://" + text
        guard !text.isEmpty, !text.contains("\\"),
              let components = URLComponents(string: urlText),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.user == nil, components.password == nil,
              let encodedHost = components.encodedHost,
              !encodedHost.contains("%"), encodedHost.utf8.allSatisfy({ $0 < 128 }),
              let decodedHost = components.host else { throw DomainError.invalid }
        // Foundation's URL parser validates/round-trips IDNA A-labels. Unicode input
        // is deliberately deferred; paths/queries never enter the route model.
        let authority = urlText.dropFirst(urlText.range(of: "://")!.upperBound.utf16Offset(in: urlText))
            .prefix(while: { $0 != "/" && $0 != "?" && $0 != "#" })
        guard authority.utf8.allSatisfy({ $0 < 128 }),
              !authority.contains("%"), !authority.contains("@"),
              components.port.map({ (1...65535).contains($0) }) ?? true else { throw DomainError.invalid }
        var host = encodedHost.lowercased()
        if host.hasSuffix(".") { host.removeLast() }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard host.utf8.count <= 253, labels.count >= 2,
              labels.allSatisfy({ label in
                  !label.isEmpty && label.utf8.count <= 63 && label.first != "-" && label.last != "-"
                  && label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
              }),
              labels.last!.utf8.contains(where: { (97...122).contains($0) }) else { throw DomainError.invalid }
        if labels.contains(where: { $0.hasPrefix("xn--") }) {
            var roundTrip = URLComponents()
            roundTrip.host = decodedHost
            guard decodedHost != encodedHost,
                  roundTrip.encodedHost?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
            else { throw DomainError.invalid }
        }
        value = host
    }

    public func matches(host: String) -> Bool {
        let normalized = host.lowercased().hasSuffix(".") ? String(host.lowercased().dropLast()) : host.lowercased()
        return normalized == value || normalized.hasSuffix("." + value)
    }

    public static func < (lhs: Domain, rhs: Domain) -> Bool { lhs.value < rhs.value }
    public init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode(String.self)) }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum DomainError: Error, LocalizedError {
    case invalid
    public var errorDescription: String? {
        "Enter a domain such as example.com or an HTTP(S) URL. IP addresses, credentials, wildcards, single-label names and Unicode hostnames are unsupported."
    }
}
