import Foundation
import Darwin

public enum DockerError: Error, CustomStringConvertible, Sendable {
    case notRunning(String)
    case io(String)
    case http(Int, String)
    case decode(String)

    public var description: String {
        switch self {
        case .notRunning(let s): return "Docker is not running (\(s))."
        case .io(let s): return "Couldn't talk to Docker: \(s)"
        case .http(let code, let msg): return msg.isEmpty ? "Docker returned HTTP \(code)." : msg
        case .decode(let s): return "Unexpected answer from Docker: \(s)"
        }
    }
}

/// A Docker Engine API socket. Docker Desktop, OrbStack, Colima and Rancher Desktop all expose the same API.
public struct DockerEndpoint: Sendable, Hashable {
    public let socketPath: String
    /// Which runtime the socket belongs to, as far as its location tells ("Docker Desktop", "Colima", …).
    public let runtime: String
    public init(socketPath: String, runtime: String) { self.socketPath = socketPath; self.runtime = runtime }
}

public struct DockerResponse: Sendable {
    public let status: Int
    public let body: Data
    /// Docker's error replies are `{"message": "..."}`.
    public var message: String {
        (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["message"] as? String
            ?? String(decoding: body.prefix(300), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Minimal HTTP/1.1 over a unix socket: no dependency, no root, and no `docker` binary on PATH needed
/// (a Finder-launched app usually doesn't have /usr/local/bin or /opt/homebrew/bin on its PATH).
public enum DockerAPI {
    /// Sockets in the order they are tried. `DOCKER_HOST` (unix:// only) and the current docker context come first.
    public static func candidates(home: String = PathUtil.home, env: [String: String] = ProcessInfo.processInfo.environment) -> [DockerEndpoint] {
        var out: [DockerEndpoint] = []
        func add(_ path: String, _ fallback: String) {
            if !out.contains(where: { $0.socketPath == path }) { out.append(DockerEndpoint(socketPath: path, runtime: runtimeName(path, fallback))) }
        }
        func runtimeName(_ path: String, _ fallback: String) -> String {
            if path.contains("/.docker/run/") { return "Docker Desktop" }
            if path.contains("/.orbstack/") { return "OrbStack" }
            if path.contains("/.colima/") { return "Colima" }
            if path.contains("/.rd/") { return "Rancher Desktop" }
            return fallback
        }
        if let h = env["DOCKER_HOST"], h.hasPrefix("unix://") { add(String(h.dropFirst("unix://".count)), "DOCKER_HOST") }
        if let ctx = currentContextSocket(home: home) { add(ctx, "Docker context") }
        add(PathUtil.join(home, ".docker/run/docker.sock"), "Docker Desktop")
        add(PathUtil.join(home, ".orbstack/run/docker.sock"), "OrbStack")
        add(PathUtil.join(home, ".colima/default/docker.sock"), "Colima")
        add(PathUtil.join(home, ".colima/docker.sock"), "Colima")
        add(PathUtil.join(home, ".rd/docker.sock"), "Rancher Desktop")
        add("/var/run/docker.sock", "Docker")
        return out
    }

    /// The socket of the docker CLI's current context (~/.docker/config.json → contexts/meta/*/meta.json), if it is a unix socket.
    static func currentContextSocket(home: String) -> String? {
        let docker = PathUtil.join(home, ".docker")
        guard let d = FileManager.default.contents(atPath: PathUtil.join(docker, "config.json")),
              let cfg = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
              let name = cfg["currentContext"] as? String, name != "default" else { return nil }
        let metaDir = PathUtil.join(docker, "contexts/meta")
        for dir in (try? FileManager.default.contentsOfDirectory(atPath: metaDir)) ?? [] {
            guard let m = FileManager.default.contents(atPath: PathUtil.join(metaDir, dir + "/meta.json")),
                  let meta = try? JSONSerialization.jsonObject(with: m) as? [String: Any], meta["Name"] as? String == name,
                  let eps = meta["Endpoints"] as? [String: Any], let dk = eps["docker"] as? [String: Any],
                  let host = dk["Host"] as? String, host.hasPrefix("unix://") else { continue }
            return String(host.dropFirst("unix://".count))
        }
        return nil
    }

    /// The first socket that answers a ping. Never starts Docker: a stopped runtime has no listening socket.
    public static func discover(home: String = PathUtil.home) -> DockerEndpoint? {
        for c in candidates(home: home) where FileManager.default.fileExists(atPath: c.socketPath) {
            if let r = try? request(c, "GET", "/_ping", timeout: 3), r.status == 200 { return c }
        }
        return nil
    }

    public static func request(_ ep: DockerEndpoint, _ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 60) throws -> DockerResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw DockerError.io(String(cString: strerror(errno))) }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(ep.socketPath.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw DockerError.io("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        addr.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { throw DockerError.notRunning(String(cString: strerror(errno))) }

        let type = body == nil ? "" : "Content-Type: application/json\r\n"
        let head = "\(method) \(path) HTTP/1.1\r\nHost: docker\r\nUser-Agent: MacLens\r\nConnection: close\r\n\(type)Content-Length: \(body?.count ?? 0)\r\n\r\n"
        var out = Array(head.utf8) + (body.map(Array.init) ?? [])
        while !out.isEmpty {
            let n = out.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            guard n > 0 else { throw DockerError.io(String(cString: strerror(errno))) }
            out.removeFirst(n)
        }
        var raw = Data()
        var buf = [UInt8](repeating: 0, count: 65536)
        while true {
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if n == 0 { break }
            guard n > 0 else { throw DockerError.io(errno == EAGAIN ? "timed out after \(Int(timeout)) s" : String(cString: strerror(errno))) }
            raw.append(contentsOf: buf[0..<n])
            if raw.count > 512 << 20 { throw DockerError.io("response too large") }
        }
        return try parse(raw)
    }

    /// Parses a complete HTTP/1.1 response, including chunked transfer encoding (Docker uses it for most JSON replies).
    public static func parse(_ raw: Data) throws -> DockerResponse {
        let sep = Data("\r\n\r\n".utf8)
        guard let end = raw.range(of: sep) else { throw DockerError.decode("incomplete HTTP response") }
        let header = String(decoding: raw[raw.startIndex..<end.lowerBound], as: UTF8.self)
        let lines = header.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2, let status = Int(parts[1]) else { throw DockerError.decode("bad status line") }
        var body = Data(raw[end.upperBound...])
        let chunked = lines.dropFirst().contains { $0.lowercased().hasPrefix("transfer-encoding:") && $0.lowercased().contains("chunked") }
        if chunked { body = try dechunk(body) }
        return DockerResponse(status: status, body: body)
    }

    static func dechunk(_ d: Data) throws -> Data {
        var out = Data()
        var i = d.startIndex
        let crlf = Data("\r\n".utf8)
        while i < d.endIndex {
            guard let lineEnd = d.range(of: crlf, in: i..<d.endIndex) else { throw DockerError.decode("bad chunk header") }
            let sizeText = String(decoding: d[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { throw DockerError.decode("bad chunk size") }
            if size == 0 { break }
            let start = lineEnd.upperBound
            guard d.distance(from: start, to: d.endIndex) >= size else { throw DockerError.decode("truncated chunk") }
            let stop = d.index(start, offsetBy: size)
            out.append(d[start..<stop])
            i = min(d.endIndex, d.index(stop, offsetBy: 2))
        }
        return out
    }

    /// GET returning the body, throwing Docker's own message on a non-2xx status.
    public static func get(_ ep: DockerEndpoint, _ path: String, timeout: TimeInterval = 60) throws -> Data {
        let r = try request(ep, "GET", path, timeout: timeout)
        guard (200..<300).contains(r.status) else { throw DockerError.http(r.status, r.message) }
        return r.body
    }

    /// Percent-encodes one path segment (image references contain '/' and ':').
    public static func segment(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}
