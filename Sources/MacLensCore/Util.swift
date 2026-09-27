import Foundation
import Darwin

/// Monotonic seconds (does not advance during sleep).
@inline(__always) public func monotonicSeconds() -> Double {
    Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9
}

/// Multiplier converting mach absolute-time ticks (used by rusage on Apple Silicon) to nanoseconds.
public let machTicksToNs: Double = {
    var tb = mach_timebase_info_data_t()
    mach_timebase_info(&tb)
    return Double(tb.numer) / Double(tb.denom)
}()

public final class UserNames: @unchecked Sendable {
    public static let shared = UserNames()
    private var cache: [uid_t: String] = [:]
    private let lock = NSLock()

    public func name(_ uid: uid_t) -> String {
        lock.lock(); defer { lock.unlock() }
        if let n = cache[uid] { return n }
        let n = getpwuid(uid).map { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        cache[uid] = n
        return n
    }
}

public enum Shell {
    /// Runs an executable synchronously and returns its stdout.
    public static func run(_ path: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum PathUtil {
    public static let home: String = NSHomeDirectory()

    @inline(__always) public static func join(_ dir: String, _ name: String) -> String {
        dir == "/" ? "/" + name : dir + "/" + name
    }

    public static func abbreviate(_ path: String) -> String {
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    public static func lastComponent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        let s = path[path.index(after: i)...]
        return s.isEmpty ? path : String(s)
    }

    public static func parent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return path }
        return i == path.startIndex ? "/" : String(path[..<i])
    }

    public static func mtime(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return Date(timeIntervalSince1970: Double(st.st_mtimespec.tv_sec))
    }

    public static func isDirectory(_ path: String) -> Bool {
        var st = stat()
        return lstat(path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }
}

/// Stable short hash for cache file names.
public func fnv1a(_ s: String) -> String {
    var h: UInt64 = 0xcbf29ce484222325
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(h, radix: 16)
}

public enum AppPaths {
    /// MACLENS_CACHE_DIR overrides the location (the self-test uses its own directory).
    public static let cacheDir: URL = {
        if let o = ProcessInfo.processInfo.environment["MACLENS_CACHE_DIR"] {
            let dir = URL(fileURLWithPath: o, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir
        }
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("dev.maclens", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
}
