import Foundation

public enum RouteEditError: Error, LocalizedError {
    case unknownPack, unknownRoute, unsupportedCommand
    public var errorDescription: String? {
        switch self {
        case .unknownPack: "Choose Internal Resources or Custom for a new domain."
        case .unknownRoute: "No route matches that domain. Add it first."
        case .unsupportedCommand: "Unsupported route command."
        }
    }
}

/// Shared GUI/CLI route mutations. Domain names on existing entries never change.
public enum RouteEditing {
    public static func apply(_ command: String, domain input: String, packID: String = "custom",
                             to packs: [RoutePack]) throws -> [RoutePack] {
        let domain = try Domain(input)
        var result = packs
        switch command {
        case "add":
            guard ["internal", "custom"].contains(packID), let index = result.firstIndex(where: { $0.id == packID }) else {
                throw RouteEditError.unknownPack
            }
            if let existing = result[index].routes.firstIndex(where: { $0.domain == domain }) {
                result[index].routes[existing].enabled = true
            } else {
                result[index].routes.append(Route(domain: domain))
            }
        case "enable", "disable":
            var found = false
            for p in result.indices {
                for r in result[p].routes.indices where result[p].routes[r].domain == domain {
                    result[p].routes[r].enabled = command == "enable"
                    found = true
                }
            }
            guard found else { throw RouteEditError.unknownRoute }
        default: throw RouteEditError.unsupportedCommand
        }
        return result
    }
}
