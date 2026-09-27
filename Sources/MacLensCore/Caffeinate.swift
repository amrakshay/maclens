import Foundation

/// Keeps the Mac awake by running Apple's `/usr/bin/caffeinate -d` (display and system stay awake).
/// The process is independent of MacLens: it keeps running if MacLens quits, and is detected again on relaunch.
public enum Caffeinate {
    public static let path = "/usr/bin/caffeinate"

    /// Starts `caffeinate -d` and returns its identity. The returned Process must be retained until it exits so it gets reaped.
    public static func start() throws -> (process: Process, key: ProcKey) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-d"]
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        let pid = p.processIdentifier
        // Start time identifies this instance even if the PID is later reused.
        var start: Int64 = 0
        for _ in 0..<20 {
            if let b = ProcList.basic(pid: pid) { start = b.start; break }
            usleep(10_000)
        }
        return (p, ProcKey(pid: pid, start: start))
    }

    /// Stops one caffeinate instance with SIGTERM. Returns an error message or nil.
    public static func stop(_ key: ProcKey) -> String? {
        ProcessControl.send(.terminate, to: key, name: "caffeinate", systemReasons: [], confirmedWarning: true)
    }
}
