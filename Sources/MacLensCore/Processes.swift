import Foundation
import Darwin

/// Identifies a process instance; start time guards against PID reuse.
public struct ProcKey: Hashable, Sendable, Codable {
    public let pid: Int32
    public let start: Int64 // microseconds since epoch
    public init(pid: Int32, start: Int64) { self.pid = pid; self.start = start }
}

public struct ProcBasic: Sendable {
    public let pid: Int32
    public let ppid: Int32
    public let uid: uid_t
    public let comm: String
    public let start: Int64
    public var key: ProcKey { ProcKey(pid: pid, start: start) }
    public var startDate: Date { Date(timeIntervalSince1970: Double(start) / 1e6) }
}

public enum ProcList {
    /// All processes via sysctl(KERN_PROC_ALL). Works for every user's processes without root.
    public static func all() -> [ProcBasic] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0]
        var size = 0
        guard sysctl(&mib, 4, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8
        let stride = MemoryLayout<kinfo_proc>.stride
        var procs = [kinfo_proc](repeating: kinfo_proc(), count: size / stride)
        guard sysctl(&mib, 4, &procs, &size, nil, 0) == 0 else { return [] }
        let n = size / stride
        var out = [ProcBasic]()
        out.reserveCapacity(n)
        for i in 0..<n { out.append(make(&procs[i])) }
        return out
    }

    public static func basic(pid: Int32) -> ProcBasic? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var kp = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &kp, &size, nil, 0) == 0, size > 0, kp.kp_proc.p_pid == pid else { return nil }
        return make(&kp)
    }

    public static func path(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(cString: buf) : nil
    }

    /// Command-line arguments. Only readable for the current user's processes without root.
    public static func arguments(pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size && buf[i] != 0 { i += 1 } // exec path
        while i < size && buf[i] == 0 { i += 1 } // padding
        var args: [String] = []
        while args.count < argc && i < size {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
    }

    private static func make(_ kp: inout kinfo_proc) -> ProcBasic {
        let comm = withUnsafeBytes(of: &kp.kp_proc.p_comm) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        let st = kp.kp_proc.p_starttime
        return ProcBasic(pid: kp.kp_proc.p_pid, ppid: kp.kp_eproc.e_ppid, uid: kp.kp_eproc.e_ucred.cr_uid,
                         comm: comm, start: Int64(st.tv_sec) * 1_000_000 + Int64(st.tv_usec))
    }
}

public struct ProcSample: Identifiable, Sendable, Equatable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var ppid: Int32
    public var uid: uid_t
    public var user: String
    public var name: String
    public var path: String
    public var startDate: Date
    public var key: ProcKey
    public var isOwn: Bool
    /// Percent of one core. -1 = unknown.
    public var cpu: Double = -1
    /// Bytes. Footprint for own processes, RSS for others. -1 = unknown.
    public var memory: Int64 = -1
    public var memoryIsFootprint = false
    /// Watts. Measured (rusage ri_energy_nj) for own processes, CPU-based estimate for others.
    public var energyW: Double = -1
    public var energyEstimated = false
    public var wakeupsPerSec: Double = -1
    /// Rolling averages over the last 5 minutes (or as long as the process has been observed).
    public var avgCPU: Double = -1
    public var avgEnergyW: Double = -1
    public var avgSpan: Double = 0
    public var systemReasons: [String] = []
    public var isSystem: Bool { !systemReasons.isEmpty }
}

extension ProcSample {
    /// For building samples outside the sampler (self-test).
    public init(pid: Int32, ppid: Int32, uid: uid_t, user: String, name: String, path: String, startDate: Date, isOwn: Bool) {
        self.init(pid: pid, ppid: ppid, uid: uid, user: user, name: name, path: path, startDate: startDate,
                  key: ProcKey(pid: pid, start: Int64(startDate.timeIntervalSince1970 * 1e6)), isOwn: isOwn)
    }
}

/// Keeps cumulative CPU/energy counters per process, spaced ~10 s apart, for 5-minute averages.
public final class EnergyHistory {
    struct Point { let t: Double; let cpuSec: Double; let energyJ: Double? }
    private var series: [ProcKey: [Point]] = [:]
    public let window: Double = 300

    public func record(_ key: ProcKey, t: Double, cpuSec: Double, energyJ: Double?) {
        var s = series[key] ?? []
        let p = Point(t: t, cpuSec: cpuSec, energyJ: energyJ)
        if s.count >= 2 && t - s[s.count - 2].t < 10 { s[s.count - 1] = p } else { s.append(p) }
        while s.count > 2, t - s[0].t > window + 15 { s.removeFirst() }
        series[key] = s
    }

    /// (cpu cores, watts or nil, seconds covered)
    public func average(_ key: ProcKey, over seconds: Double, now: Double) -> (cpu: Double, watts: Double?, span: Double)? {
        guard let s = series[key], let last = s.last,
              let first = s.first(where: { now - $0.t <= seconds + 5 }), last.t - first.t >= 2 else { return nil }
        let dt = last.t - first.t
        let cpu = max(0, (last.cpuSec - first.cpuSec) / dt)
        var w: Double?
        if let a = first.energyJ, let b = last.energyJ { w = max(0, (b - a) / dt) }
        return (cpu, w, dt)
    }

    public func prune(alive: Set<ProcKey>) {
        series = series.filter { alive.contains($0.key) }
    }
}

/// Samples per-process CPU, memory and energy without root.
///  - Own processes: proc_pid_rusage (CPU time, phys_footprint, measured CPU energy, wakeups).
///  - Other users' processes: libproc is denied (EPERM), so /bin/ps (setuid) supplies CPU time and RSS.
/// Not thread-safe; call from one serial queue.
public final class ProcessSampler {
    public let classifier = SystemClassifier()
    public let history = EnergyHistory()
    public private(set) var wattsPerCore: Double = 1.0
    public private(set) var lastForeignRefresh: Double = 0

    private struct OwnPrev { let t: Double; let cpuNs: Double; let energyNj: Double; let wakeups: Double; let rates: (Double, Double, Double) }
    private struct Foreign { let t: Double; let cpuSec: Double; let rss: Int64; let cpuPct: Double }
    private var prevOwn: [ProcKey: OwnPrev] = [:]
    private var foreign: [ProcKey: Foreign] = [:]
    private var pathCache: [ProcKey: String] = [:]
    private let myUid = getuid()

    public init() {}

    public func sample(includeForeign: Bool) -> [ProcSample] {
        let now = monotonicSeconds()
        let procs = ProcList.all()
        if includeForeign { refreshForeign(now: now, procs: procs) }

        var out = [ProcSample]()
        out.reserveCapacity(procs.count)
        var alive = Set<ProcKey>()
        var ownCores = 0.0, ownWatts = 0.0

        for b in procs {
            let key = b.key
            alive.insert(key)
            let path: String
            if let p = pathCache[key] { path = p } else { path = ProcList.path(pid: b.pid) ?? ""; pathCache[key] = path }
            let name = b.pid == 0 ? "kernel_task" : (path.isEmpty ? b.comm : PathUtil.lastComponent(path))
            let user = UserNames.shared.name(b.uid)
            var s = ProcSample(pid: b.pid, ppid: b.ppid, uid: b.uid, user: user, name: name, path: path,
                               startDate: b.startDate, key: key, isOwn: b.uid == myUid)

            if b.uid == myUid, let ri = Self.rusage(b.pid) {
                let cpuNs = Double(ri.ri_user_time &+ ri.ri_system_time) * machTicksToNs
                let energy = Double(ri.ri_energy_nj) // kernel-measured CPU energy (billed_energy stays ~0 for most processes)
                let wk = Double(ri.ri_interrupt_wkups &+ ri.ri_pkg_idle_wkups)
                s.memory = Int64(ri.ri_phys_footprint)
                s.memoryIsFootprint = true
                if let p = prevOwn[key], now - p.t <= 0.2 {
                    // Two ticks milliseconds apart (e.g. a tab switch right after a scheduled tick): too short to
                    // measure, so repeat the last rates and keep the older baseline instead of showing "—".
                    (s.cpu, s.energyW, s.wakeupsPerSec) = p.rates
                } else {
                    if let p = prevOwn[key] {
                        let dt = now - p.t
                        s.cpu = max(0, (cpuNs - p.cpuNs) / 1e9 / dt * 100)
                        s.energyW = max(0, (energy - p.energyNj) / 1e9 / dt)
                        s.wakeupsPerSec = max(0, (wk - p.wakeups) / dt)
                        ownCores += s.cpu / 100
                        ownWatts += s.energyW
                    }
                    prevOwn[key] = OwnPrev(t: now, cpuNs: cpuNs, energyNj: energy, wakeups: wk, rates: (s.cpu, s.energyW, s.wakeupsPerSec))
                }
                history.record(key, t: now, cpuSec: cpuNs / 1e9, energyJ: energy / 1e9)
            } else if let f = foreign[key] {
                s.memory = f.rss
                s.cpu = f.cpuPct
                s.energyW = f.cpuPct / 100 * wattsPerCore
                s.energyEstimated = true
            }
            s.systemReasons = classifier.classify(uid: b.uid, user: user, path: path, ppid: b.ppid)
            out.append(s)
        }

        // Calibrate the foreign-process estimate from own processes: watts per busy core.
        if ownCores > 0.15 {
            let k = min(4, max(0.3, ownWatts / ownCores))
            wattsPerCore = 0.8 * wattsPerCore + 0.2 * k
        }

        func r(_ v: Double, _ step: Double) -> Double { v < 0 ? v : (v / step).rounded() * step }
        for i in out.indices {
            if let a = history.average(out[i].key, over: history.window, now: now) {
                out[i].avgCPU = a.cpu * 100
                out[i].avgEnergyW = a.watts ?? a.cpu * wattsPerCore
                out[i].avgSpan = a.span.rounded()
            }
            // Round to display precision: rows whose visible values didn't change compare equal (cheaper UI diffing).
            out[i].cpu = r(out[i].cpu, 0.1); out[i].avgCPU = r(out[i].avgCPU, 0.1)
            out[i].energyW = r(out[i].energyW, 0.001); out[i].avgEnergyW = r(out[i].avgEnergyW, 0.001)
            out[i].wakeupsPerSec = r(out[i].wakeupsPerSec, 1)
            if out[i].memory > 0 { out[i].memory = out[i].memory / 100_000 * 100_000 }
        }

        prevOwn = prevOwn.filter { alive.contains($0.key) }
        foreign = foreign.filter { alive.contains($0.key) }
        if pathCache.count > alive.count * 2 { pathCache = pathCache.filter { alive.contains($0.key) } }
        history.prune(alive: alive)
        return out
    }

    private func refreshForeign(now: Double, procs: [ProcBasic]) {
        guard let text = Shell.run("/bin/ps", ["-axo", "pid=,rss=,time=,%cpu="]) else { return }
        lastForeignRefresh = now
        var byPid: [Int32: ProcBasic] = [:]
        for p in procs where p.uid != myUid { byPid[p.pid] = p }
        for line in text.split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 4, let pid = Int32(f[0]), let b = byPid[pid],
                  let rssKB = Int64(f[1]), let pct = Double(f[3]) else { continue }
            let cpuSec = Self.parseCPUTime(f[2])
            let key = b.key
            var pctNow = pct
            if let prev = foreign[key], now - prev.t > 0.5 {
                pctNow = max(0, (cpuSec - prev.cpuSec) / (now - prev.t) * 100)
            }
            foreign[key] = Foreign(t: now, cpuSec: cpuSec, rss: rssKB * 1024, cpuPct: pctNow)
            history.record(key, t: now, cpuSec: cpuSec, energyJ: nil)
        }
    }

    /// Parses ps TIME: "[dd-][hh:]mm:ss.ss"
    static func parseCPUTime<S: StringProtocol>(_ s: S) -> Double {
        var days = 0.0
        var rest = Substring(s)
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = rest[rest.index(after: dash)...]
        }
        var total = 0.0
        var mult = 1.0
        for part in rest.split(separator: ":").reversed() {
            total += (Double(part) ?? 0) * mult
            mult *= 60
        }
        return total + days * 86400
    }

    static func rusage(_ pid: Int32) -> rusage_info_v6? {
        var ri = rusage_info_v6()
        let r = withUnsafeMutablePointer(to: &ri) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
        }
        return r == 0 ? ri : nil
    }
}
