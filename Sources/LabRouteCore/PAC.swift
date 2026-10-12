import Foundation

public enum PACGenerator {
    public static func generate(routes: RouteSet, socksPort: UInt16) throws -> String {
        guard socksPort > 0 else { throw PACError.invalidPort }
        let data = try JSONEncoder().encode(routes.domains.map(\.value))
        let domains = String(decoding: data, as: UTF8.self)
        return """
        // Safari/CFNetwork ignores the SOCKS5 entry and reads SOCKS as SOCKS version 5.
        // Chrome/Brave use the SOCKS5 entry (remote DNS); SOCKS there would mean SOCKS4.
        // PAC availability is not a fail-closed guarantee.
        function FindProxyForURL(url, host) {
          host = host.toLowerCase().replace(/\\.$/, "");
          var domains = \(domains);
          for (var i = 0; i < domains.length; i++) {
            var domain = domains[i];
            if (host === domain || host.slice(-(domain.length + 1)) === "." + domain) {
              return "SOCKS5 127.0.0.1:\(socksPort); SOCKS 127.0.0.1:\(socksPort)";
            }
          }
          return "DIRECT";
        }
        """
    }
}
public enum PACError: Error { case invalidPort }
