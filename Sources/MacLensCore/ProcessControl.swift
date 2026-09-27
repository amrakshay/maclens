import Foundation
import Darwin

public enum KillSignal: Sendable {
    case terminate, forceKill
    public var signo: Int32 { self == .terminate ? SIGTERM : SIGKILL }
    public var label: String { self == .terminate ? "Terminate (SIGTERM)" : "Force Kill (SIGKILL)" }
}

public enum KillPolicy: Equatable, Sendable {
    case allowed
    /// Allowed only after an explicit, strongly-worded confirmation.
    case warn(String)
    case refused(String)
}

public enum ProcessControl {
    /// Never signalled, even if somehow owned by the current user.
    public static let refusedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "logind", "opendirectoryd",
        "securityd", "configd", "coreservicesd", "UserEventAgent", "mds", "syslogd", "notifyd",
    ]

    public static func policy(pid: Int32, name: String, uid: uid_t, systemReasons: [String]) -> KillPolicy {
        if pid <= 1 { return .refused("\(name) (PID \(pid)) is the root of the process tree; killing it would crash macOS.") }
        if pid == getpid() { return .refused("This is MacLens itself. Quit it from the menu bar instead.") }
        if refusedNames.contains(name) { return .refused("\(name) is critical to macOS; killing it would log you out or hang the system.") }
        if uid != getuid() {
            return .refused("Owned by \(UserNames.shared.name(uid)). macOS only lets root signal other users' processes, and MacLens does not run as root.")
        }
        if !systemReasons.isEmpty {
            return .warn("\(name) is a macOS component (\(systemReasons.joined(separator: ", "))). Killing it can break parts of the UI until launchd restarts it.")
        }
        return .allowed
    }

    /// Sends a signal after re-verifying identity (PID reuse) and policy. Returns an error message or nil on success.
    public static func send(_ sig: KillSignal, to key: ProcKey, name: String, systemReasons: [String], confirmedWarning: Bool) -> String? {
        guard let now = ProcList.basic(pid: key.pid), now.start == key.start else {
            return "The process has already exited (or its PID was reused)."
        }
        switch policy(pid: key.pid, name: name, uid: now.uid, systemReasons: systemReasons) {
        case .refused(let why): return why
        case .warn(let why) where !confirmedWarning: return "Confirmation required: \(why)"
        default: break
        }
        if kill(key.pid, sig.signo) != 0 { return String(cString: strerror(errno)) }
        return nil
    }
}

/// On-demand precise energy sample via /usr/bin/top, which holds Apple's task-ports entitlement and can
/// report POWER for every process. Costs ~1 s of CPU, so it only runs when the user asks.
public enum TopSampler {
    /// PID -> top's POWER score (Activity Monitor–style energy impact, unitless).
    public static func samplePower(limit: Int = 60) -> [Int32: Double] {
        guard let text = Shell.run("/usr/bin/top", ["-l", "2", "-s", "1", "-n", "\(limit)", "-o", "power", "-stats", "pid,power"]) else { return [:] }
        var headerCount = 0
        var out: [Int32: Double] = [:]
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            if f.first == "PID" { headerCount += 1; continue }
            guard headerCount == 2, f.count >= 2, let pid = Int32(f[0]), let p = Double(f[1]) else { continue }
            out[pid] = p
        }
        return out
    }
}
