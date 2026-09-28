import Foundation

/// Processes that belong to one application, with totals (#34).
public struct AppGroup: Identifiable, Sendable, Equatable {
    /// Stable across ticks: the bundle path for apps, "name:<process name>" otherwise.
    public let id: String
    public let name: String
    /// Outermost `.app` bundle, nil for processes that live outside one.
    public let bundlePath: String?
    public var processes: [ProcSample]

    /// Sums over processes with a known value (-1 = none known).
    public var cpu: Double { Self.sum(processes.map(\.cpu)) }
    public var memory: Int64 { let m = processes.map(\.memory).filter { $0 >= 0 }; return m.isEmpty ? -1 : m.reduce(0, +) }
    public var energyW: Double { Self.sum(processes.map(\.energyW)) }
    public var avgEnergyW: Double { Self.sum(processes.map(\.avgEnergyW)) }
    /// Other users' processes contribute resident size, not footprint, so the total is approximate.
    public var memoryEstimated: Bool { processes.contains { $0.memory >= 0 && !$0.memoryIsFootprint } }
    public var energyEstimated: Bool { processes.contains { $0.energyEstimated } }
    public var allOwn: Bool { processes.allSatisfy(\.isOwn) }
    public var isSystem: Bool { processes.allSatisfy(\.isSystem) }
    /// The single owner's name, or "multiple".
    public var user: String { let u = Set(processes.map(\.user)); return u.count == 1 ? u.first! : "multiple" }

    static func sum(_ v: [Double]) -> Double { let k = v.filter { $0 >= 0 }; return k.isEmpty ? -1 : k.reduce(0, +) }
}

public enum AppGrouping {
    /// Walking up the tree stops at these: what runs in a terminal belongs to the command, not to Terminal.app.
    public static let shells: Set<String> = ["zsh", "bash", "sh", "dash", "fish", "tcsh", "csh", "ksh", "nu", "login", "sshd", "sshd-session"]

    /// Outermost `.app` bundle in `path`: `/Applications/Google Chrome.app/Contents/Frameworks/…/Google Chrome Helper.app/…`
    /// → `/Applications/Google Chrome.app`.
    public static func bundlePath(_ path: String) -> String? {
        if let r = path.range(of: ".app/") { return String(path[..<r.lowerBound]) + ".app" }
        return path.hasSuffix(".app") ? path : nil
    }

    /// Assigns each process to an app:
    ///  1. the outermost `.app` bundle of its executable;
    ///  2. otherwise the bundle of its nearest ancestor, unless a shell or launchd comes first;
    ///  3. otherwise the name of its topmost ancestor below that shell or launchd (so a CLI and its children stay together),
    ///     folded into the app of the same name if there is exactly one.
    /// Groups are returned in no particular order; processes keep their input order.
    public static func group(_ procs: [ProcSample]) -> [AppGroup] {
        var byPid = [Int32: ProcSample](minimumCapacity: procs.count)
        for p in procs { byPid[p.pid] = p }
        var memo = [Int32: (id: String, name: String, bundle: String?)]()

        func owner(_ p: ProcSample) -> (id: String, name: String, bundle: String?) {
            if let m = memo[p.pid] { return m }
            var result: (id: String, name: String, bundle: String?)
            if let b = bundlePath(p.path) {
                result = (b, displayName(b), b)
            } else {
                // Climb while the parent is an ordinary process; `top` is the highest one reached.
                var top = p, depth = 0
                result = ("name:" + p.name, p.name, nil)
                while depth < 64, top.ppid > 1, top.ppid != top.pid, let parent = byPid[top.ppid], !shells.contains(parent.name),
                      parent.startDate <= top.startDate { // a parent can't be younger than its child; guards against PID reuse
                    if bundlePath(parent.path) != nil { result = owner(parent); break }
                    top = parent; depth += 1
                    result = ("name:" + top.name, top.name, nil)
                }
            }
            memo[p.pid] = result
            return result
        }

        var groups = [String: AppGroup]()
        var order = [String]()
        for p in procs {
            let o = owner(p)
            if groups[o.id] == nil {
                groups[o.id] = AppGroup(id: o.id, name: o.name, bundlePath: o.bundle, processes: [])
                order.append(o.id)
            }
            groups[o.id]!.processes.append(p)
        }
        // A running app whose files were replaced on disk (Chrome updating itself) loses its executable path, so its
        // main process only has a name. Fold such a group into the app of the same name.
        var byName = [String: String]()
        for id in order { if let g = groups[id], g.bundlePath != nil { byName[g.name] = byName[g.name] == nil ? id : "" } }
        for id in order where id.hasPrefix("name:") {
            if let g = groups[id], let target = byName[g.name], !target.isEmpty {
                groups[target]!.processes += g.processes
                groups[id] = nil
            }
        }
        return order.compactMap { groups[$0] }
    }

    static func displayName(_ bundle: String) -> String {
        let last = PathUtil.lastComponent(bundle)
        return last.hasSuffix(".app") ? String(last.dropLast(4)) : last
    }
}
