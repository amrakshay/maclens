import Foundation

public struct PortEntry: Identifiable, Hashable, Sendable {
    public var id: String { "\(proto)|\(family)|\(address)|\(port)|\(pid)" }
    public let proto: String   // TCP / UDP
    public let family: String  // IPv4 / IPv6 / IPv4+6
    public let address: String // "*" = all interfaces
    public let port: Int
    public let pid: Int32
    public let netstatName: String // truncated by netstat; the UI prefers the real executable name
}

/// Listening sockets for every process, without root.
/// `netstat -anv` reads the net.inet.{tcp,udp}.pcblist_n sysctl, which carries the owning PID even for root sockets.
/// (lsof only sees the current user's processes unless run as root.)
public enum PortScanner {
    public static func listening() -> [PortEntry] {
        var out: [PortEntry] = []
        if let t = Shell.run("/usr/sbin/netstat", ["-anv", "-p", "tcp"]) { out += parse(t) }
        if let u = Shell.run("/usr/sbin/netstat", ["-anv", "-p", "udp"]) { out += parse(u) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }.sorted { ($0.port, $0.proto) < ($1.port, $1.proto) }
    }

    /// Parses `netstat -anv` output. Keeps TCP LISTEN sockets and unconnected (bound) UDP sockets.
    public static func parse(_ text: String) -> [PortEntry] {
        var out: [PortEntry] = []
        for line in text.split(separator: "\n") {
            let t = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard t.count > 8, let proto = t.first, proto.hasPrefix("tcp") || proto.hasPrefix("udp") else { continue }
            let isTCP = proto.hasPrefix("tcp")
            if isTCP { guard t[5] == "LISTEN" else { continue } } else { guard t[4] == "*.*" else { continue } }
            guard let (addr, port) = splitAddress(t[3]) else { continue }

            // Process column is "name:pid" where name may contain spaces; it follows the last numeric column.
            guard let j = t.indices.dropFirst(5).first(where: { isNamePid(t[$0]) && t.count - $0 - 1 >= 6 }) else { continue }
            var start = j
            while start - 1 > 4, Int(t[start - 1]) == nil { start -= 1 }
            let joined = t[start...j].joined(separator: " ")
            guard let colon = joined.lastIndex(of: ":"), let pid = Int32(joined[joined.index(after: colon)...]) else { continue }
            let family = proto.hasSuffix("46") ? "IPv4+6" : proto.hasSuffix("6") ? "IPv6" : "IPv4"
            out.append(PortEntry(proto: isTCP ? "TCP" : "UDP", family: family, address: addr, port: port,
                                 pid: pid, netstatName: String(joined[..<colon])))
        }
        return out
    }

    static func isNamePid(_ s: String) -> Bool {
        guard let c = s.lastIndex(of: ":"), c != s.startIndex else { return false }
        let digits = s[s.index(after: c)...]
        return !digits.isEmpty && digits.allSatisfy(\.isNumber)
    }

    /// "127.0.0.1.8080" -> ("127.0.0.1", 8080); "*.53" -> ("*", 53); "::1.631" -> ("::1", 631)
    static func splitAddress(_ s: String) -> (String, Int)? {
        guard let dot = s.lastIndex(of: "."), let port = Int(s[s.index(after: dot)...]) else { return nil }
        return (String(s[..<dot]), port)
    }
}
