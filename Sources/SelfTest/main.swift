import Foundation
import Darwin
import MacLensCore

// Self-test for MacLensCore. Everything that is created or deleted lives in a fresh directory under
// ./.selftest/ (not under /private, which the deletion guard blocks by design). Deletion is additionally
// fenced by MACLENS_DELETE_SANDBOX so the Deleter refuses anything outside that directory.
//
// Usage: maclens-selftest            run all checks
//        maclens-selftest --scan PATH measure a full scan + incremental rescan of PATH (read-only)

var failures = 0
func check(_ ok: Bool, _ msg: String) {
    print(ok ? "  ✓ \(msg)" : "  ✗ \(msg)")
    if !ok { failures += 1 }
}
func section(_ s: String) { print("\n▸ \(s)") }
/// CI runners are VMs without a battery, SMC fans or temperature sensors: hardware checks are skipped there, not failed.
let onCI = ProcessInfo.processInfo.environment["CI"] != nil
func hardwareCheck(_ ok: Bool, _ msg: String) {
    if !ok && onCI { print("  – skipped on CI (no hardware): \(msg)"); return }
    check(ok, msg)
}
func peakRSSMB() -> Double { var ru = rusage(); getrusage(RUSAGE_SELF, &ru); return Double(ru.ru_maxrss) / 1_048_576 }

let args = CommandLine.arguments
if args.contains("--groups") { // read-only: print live application groups, biggest memory first
    let s = ProcessSampler(); _ = s.sample(includeForeign: true); usleep(500_000)
    for g in AppGrouping.group(s.sample(includeForeign: true)).sorted(by: { $0.memory > $1.memory }).prefix(15) {
        print(String(format: "%5d  %6.1f%%  %10lld  ", g.processes.count, g.cpu, g.memory) + g.id)
    }
    exit(0)
}
if let i = args.firstIndex(of: "--scan"), i + 1 < args.count {
    let root = args[i + 1]
    let scanner = DiskScanner()
    guard let t = scanner.scan(root: root, previous: nil) else { print("cancelled"); exit(1) }
    print(String(format: "full scan: %.1fs, %d dirs, %d files, %@ on disk, %d unreadable, peak RSS %.0f MB",
                 t.duration, t.count, scanner.progress.snapshot.files,
                 ByteCountFormatter.string(fromByteCount: t.totalAlloc[0], countStyle: .file), t.skippedDirs, peakRSSMB()))
    try? ScanCache.save(t)
    let loaded = ScanCache.load(root: root)
    guard let t2 = DiskScanner().scan(root: root, previous: loaded) else { exit(1) }
    print(String(format: "rescan: %.2fs, reused %d of %d dirs, %@, peak RSS %.0f MB",
                 t2.duration, t2.reusedDirs, t2.count, ByteCountFormatter.string(fromByteCount: t2.totalAlloc[0], countStyle: .file), peakRSSMB()))
    exit(0)
}

if let i = args.firstIndex(of: "--artifacts"), i + 1 < args.count {
    // Read-only: finds and sizes developer artifacts under PATH, prints a summary. Deletes nothing.
    guard let r = ArtifactScanner().scan(roots: [args[i + 1]], previous: nil) else { exit(1) }
    print(String(format: "artifact scan: %.1fs, %d items, peak RSS %.0f MB", r.duration, r.artifacts.count, peakRSSMB()))
    var byKind: [ArtifactKind: (Int, Int64)] = [:]
    for a in r.artifacts { let v = byKind[a.kind] ?? (0, 0); byKind[a.kind] = (v.0 + 1, v.1 + a.allocSize) }
    for (k, v) in byKind.sorted(by: { $0.value.1 > $1.value.1 }) {
        print("  \(k.displayName): \(v.0) items, \(ByteCountFormatter.string(fromByteCount: v.1, countStyle: .file))")
    }
    for a in r.artifacts.prefix(8) {
        print("  · \(PathUtil.abbreviate(a.path)) — \(ByteCountFormatter.string(fromByteCount: a.allocSize, countStyle: .file)), reclaimable \(ByteCountFormatter.string(fromByteCount: a.reclaimable, countStyle: .file)), last activity \(a.daysSinceActivity.map { "\($0)d" } ?? "?") (\(a.lastActivitySource))")
    }
    exit(0)
}

if let i = args.firstIndex(of: "--screen-watcher") {
    // Read-only: prints whether the screen is being shared/recorded/mirrored, once a second (for #29).
    let n = i + 1 < args.count ? Int(args[i + 1]) ?? 30 : 30
    for t in 0..<n {
        let v = PresenceSignals.screenIsShared()
        print("t=\(t)s watcher=\(v.map { $0 ? "YES" : "no" } ?? "unavailable")"); fflush(stdout)
        Thread.sleep(forTimeInterval: 1)
    }
    exit(0)
}

let fm = FileManager.default
let base = URL(fileURLWithPath: fm.currentDirectoryPath).appendingPathComponent(".selftest/run-\(UUID().uuidString.prefix(8))")
try! fm.createDirectory(at: base, withIntermediateDirectories: true)
let T = base.path
setenv("MACLENS_DELETE_SANDBOX", T, 1)
setenv("MACLENS_CACHE_DIR", PathUtil.join(T, "cache"), 1) // keep test caches out of the app's real cache
print("test dir: \(T)")

func write(_ rel: String, bytes: Int = 0) {
    let url = URL(fileURLWithPath: PathUtil.join(T, rel))
    try! fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try! Data(repeating: 0x61, count: bytes).write(to: url)
}
func mkdir(_ rel: String) { try! fm.createDirectory(atPath: PathUtil.join(T, rel), withIntermediateDirectories: true) }
func setMtime(_ rel: String, daysAgo: Double) {
    let t = Date().addingTimeInterval(-daysAgo * 86400).timeIntervalSince1970
    var tv = [timeval(tv_sec: Int(t), tv_usec: 0), timeval(tv_sec: Int(t), tv_usec: 0)]
    _ = utimes(PathUtil.join(T, rel), &tv)
}

// MARK: - System signals
section("System signals")
check(SMC.keyDataSize == 80, "SMC key struct is 80 bytes (got \(SMC.keyDataSize))")
let smc = SMC()
hardwareCheck(smc != nil, "SMC opens without root")
print("    fans: \(smc?.fanRPMs() ?? [])")
let hid = HIDTemperatures()
let temps = hid?.read() ?? []
hardwareCheck(!temps.isEmpty, "HID temperature sensors readable without root (\(temps.count) sensors)")
let ts = ThermalSummary.summarize(temps, fans: [])
print("    CPU max \(ts.cpuMaxC.map { String(format: "%.1f°C", $0) } ?? "n/a"), battery \(ts.batteryC.map { String(format: "%.1f°C", $0) } ?? "n/a")")
let bat = PowerReader.battery()
check(bat.hasBattery ? bat.systemLoadW != nil : true, "battery wattage readable (load \(bat.systemLoadW.map { String(format: "%.1f W", $0) } ?? "n/a"), \(bat.percent ?? -1)%)")
let asserts = PowerReader.assertions()
hardwareCheck(!asserts.isEmpty, "power assertions readable (\(asserts.count), \(asserts.filter(\.preventsSleep).count) prevent sleep)")
print("    thermal state: \(ProcessInfo.processInfo.thermalState.rawValue)")

// MARK: - Processes
section("Processes")
let sampler = ProcessSampler()
_ = sampler.sample(includeForeign: true)
var x = 0.0; for i in 0..<3_000_000 { x += Double(i) } // burn a little CPU
usleep(300_000)
let procs = sampler.sample(includeForeign: true)
let me = procs.first { $0.pid == getpid() }
check(me != nil && me!.cpu > 0 && me!.memory > 0 && me!.memoryIsFootprint, "own process: cpu \(me?.cpu ?? -1)%, footprint \(me?.memory ?? -1) B, energy \(me?.energyW ?? -1) W")
let foreign = procs.filter { !$0.isOwn && $0.memory > 0 }
check(foreign.count > 5, "foreign processes get RSS/CPU via ps (\(foreign.count))")
let again = sampler.sample(includeForeign: false).first { $0.pid == getpid() }
check((again?.cpu ?? -1) >= 0 && again?.cpu == me?.cpu, "a sample right after another repeats the last CPU instead of unknown (\(again?.cpu ?? -1)%)")
let ws = procs.first { $0.name == "WindowServer" }
hardwareCheck(ws?.isSystem == true, "WindowServer classified system: \(ws?.systemReasons ?? [])")
check(procs.first { $0.pid == getpid() }?.isSystem == false, "this test binary is not system")
check(ProcList.arguments(pid: getpid())?.first?.hasSuffix("maclens-selftest") == true, "own arguments readable")
check(ProcList.arguments(pid: 1) == nil, "root process arguments not readable (expected without root)")
print("    x=\(x > 0)")

// MARK: - Application groups (#34)
section("Application groups")
check(AppGrouping.bundlePath("/Applications/Google Chrome.app/Contents/Frameworks/Google Chrome Framework.framework/Versions/1/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)") == "/Applications/Google Chrome.app", "outermost .app wins for nested helper bundles")
check(AppGrouping.bundlePath("/usr/bin/python3") == nil && AppGrouping.bundlePath("/opt/x/Foo.application/bin/foo") == nil, "no bundle outside .app folders")
do {
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    func mk(_ pid: Int32, _ ppid: Int32, _ name: String, _ path: String, at dt: Double = 0, user: String = "me", cpu: Double = 1, mem: Int64 = 100, own: Bool = true) -> ProcSample {
        var p = ProcSample(pid: pid, ppid: ppid, uid: 501, user: user, name: name, path: path, startDate: t0.addingTimeInterval(dt), isOwn: own)
        p.cpu = cpu; p.memory = mem; p.memoryIsFootprint = own; p.energyW = cpu / 10
        return p
    }
    let chrome = "/Applications/Google Chrome.app"
    let sample = [
        mk(1, 0, "launchd", "/sbin/launchd", user: "root"),
        mk(100, 1, "Google Chrome", chrome + "/Contents/MacOS/Google Chrome", at: 1, cpu: 10, mem: 1000),
        mk(101, 100, "Google Chrome Helper", chrome + "/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper.app/Contents/MacOS/Google Chrome Helper", at: 2, cpu: 5, mem: 500),
        mk(102, 101, "chrome_crashpad_handler", "/private/var/folders/x/chrome_crashpad_handler", at: 3, cpu: 1, mem: 50),
        mk(200, 1, "Terminal", "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", at: 1),
        mk(201, 200, "login", "/usr/bin/login", at: 2, user: "root", own: false),
        mk(202, 201, "zsh", "/bin/zsh", at: 3),
        mk(203, 202, "claude", "/Users/me/.local/bin/claude", at: 4, cpu: 20, mem: 300),
        mk(204, 203, "node", "/opt/homebrew/bin/node", at: 5, cpu: 3, mem: 80),
        mk(210, 202, "claude", "/Users/me/.local/bin/claude", at: 6, cpu: 2, mem: 200),
        mk(300, 1, "mdworker_shared", "/System/Library/Frameworks/CoreServices.framework/mdworker_shared", at: 1),
        mk(301, 1, "mdworker_shared", "/System/Library/Frameworks/CoreServices.framework/mdworker_shared", at: 1),
        mk(400, 999, "orphan", "/usr/bin/orphan", at: 1),
        mk(500, 204, "reused", "/usr/bin/reused", at: -5), // older than its "parent": PID was reused
        mk(600, 1, "Google Chrome", "", at: 1, cpu: 4, mem: 10), // executable replaced by an update: no path
        mk(601, 600, "Google Chrome Helper", "", at: 2, cpu: 1, mem: 10),
    ]
    let groups = AppGrouping.group(sample)
    func g(_ id: String) -> AppGroup? { groups.first { $0.id == id } }
    let c = g(chrome)
    check(c?.name == "Google Chrome" && Set(c?.processes.map(\.pid) ?? []) == [100, 101, 102, 600, 601] && g("name:Google Chrome") == nil, "Chrome, its helper bundle, an unbundled child and path-less processes of the same name form one group: \(c?.processes.map(\.pid) ?? [])")
    check(c?.cpu == 21 && c?.memory == 1570 && c?.memoryEstimated == false, "group totals are sums: cpu \(c?.cpu ?? -1), memory \(c?.memory ?? -1)")
    let cl = g("name:claude")
    check(Set(cl?.processes.map(\.pid) ?? []) == [203, 204, 210] && cl?.cpu == 25, "CLI processes stop at the shell and group by the top command with their children")
    check(Set(g("/System/Applications/Utilities/Terminal.app")?.processes.map(\.pid) ?? []) == [200, 201], "login joins Terminal; the shell does not")
    check(g("name:zsh")?.processes.count == 1 && g("name:mdworker_shared")?.processes.count == 2, "unbundled daemons group by name")
    check(g("name:orphan") != nil && g("name:reused")?.processes.count == 1, "missing parent and reused PID fall back to the process's own name")
    check(g(chrome)?.user == "me" && g("/System/Applications/Utilities/Terminal.app")?.user == "multiple"
          && g("/System/Applications/Utilities/Terminal.app")?.memoryEstimated == true, "mixed owners show as multiple and mark memory estimated")
    check(groups.reduce(0) { $0 + $1.processes.count } == sample.count, "every process lands in exactly one group")
    let live = AppGrouping.group(procs)
    check(live.reduce(0) { $0 + $1.processes.count } == procs.count && live.count < procs.count,
          "live: \(procs.count) processes → \(live.count) groups")
}

// MARK: - Kill
section("Kill")
check(ProcessControl.policy(pid: 1, name: "launchd", uid: 0, systemReasons: ["root"]) != .allowed, "launchd refused")
if let ws { check({ if case .refused = ProcessControl.policy(pid: ws.pid, name: ws.name, uid: ws.uid, systemReasons: ws.systemReasons) { return true }; return false }(), "WindowServer refused") }
check({ if case .refused = ProcessControl.policy(pid: getpid(), name: "x", uid: getuid(), systemReasons: []) { return true }; return false }(), "self refused")
let child = Process(); child.executableURL = URL(fileURLWithPath: "/bin/sleep"); child.arguments = ["100"]; try! child.run()
usleep(100_000)
if let b = ProcList.basic(pid: child.processIdentifier) {
    check(ProcessControl.policy(pid: b.pid, name: "sleep", uid: b.uid, systemReasons: []) == .allowed, "own child allowed")
    check(ProcessControl.send(.terminate, to: ProcKey(pid: b.pid, start: b.start + 1), name: "sleep", systemReasons: [], confirmedWarning: false) != nil, "stale key (PID reuse) rejected")
    let err = ProcessControl.send(.terminate, to: b.key, name: "sleep", systemReasons: [], confirmedWarning: false)
    child.waitUntilExit()
    check(err == nil && child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGTERM, "SIGTERM delivered to child")
}

// MARK: - Battery alerts
section("Battery alerts")
do {
    var st = BatteryAlertState()
    func step(_ pct: Int, charging: Bool) -> BatteryAlertState.Alert? { st.update(percent: pct, charging: charging, onAC: charging, low: 20, high: 80) }
    _ = step(30, charging: false)                                      // first observation never fires
    let seq = [25, 21, 20, 19, 18, 17].map { step($0, charging: false) }
    check(seq == [nil, nil, .low(20), nil, nil, nil], "low alert fires once at 20% while draining: \(seq)")
    check(step(21, charging: true) == nil && step(23, charging: true) == nil, "no alert while charging back up")
    let up = [60, 79, 80, 81, 85].map { step($0, charging: true) }
    check(up == [nil, nil, .high(80), nil, nil], "high alert fires once at 80% while charging: \(up)")
    check([84, 79, 77].map { step($0, charging: false) } == [nil, nil, nil], "unplugging above 80% doesn't alert")
    check(step(80, charging: true) == .high(80), "re-armed after dropping below 78%: fires again on the next climb")
    check(step(19, charging: false) == .low(19), "low re-armed after charging above 22%")
    var fresh = BatteryAlertState()
    _ = fresh.update(percent: 15, charging: false, onAC: false, low: 20, high: 80)
    check(fresh.update(percent: 14, charging: false, onAC: false, low: 20, high: 80) == nil, "already below 20% at launch: no alert until it re-arms")
}

// MARK: - Sleep prevention (caffeinate)
section("Sleep prevention")
if let (proc, key) = try? Caffeinate.start() {
    usleep(500_000)
    let held = PowerReader.assertions().contains { $0.pid == key.pid && $0.preventsSleep }
    hardwareCheck(key.start != 0 && held, "caffeinate -d started (PID \(key.pid)) and holds a sleep-preventing assertion")
    check(Caffeinate.stop(key) == nil, "caffeinate stopped with SIGTERM")
    proc.waitUntilExit()
    usleep(300_000)
    check(!PowerReader.assertions().contains { $0.pid == key.pid }, "assertion released, Mac can sleep normally")
} else {
    check(false, "caffeinate could not be started")
}

// MARK: - Ports
section("Ports")
let sample = """
tcp4       0      0  *.24601                *.*                    LISTEN                 0            0  131072  131072           Python:24872  00100 00000106 0000000002e45ef8 00000000 00000800      1      0 000000
tcp46      0      0  *.7000                 *.*                    LISTEN                 0            0  131072  131072    Google Chrome He:21037  00100 00000106 0000000002e45ef8 00000000 00000800      1      0 000000
tcp4       0      0  192.168.0.116.51969    104.16.103.112.443     ESTABLISHED       518492         3506  494728  131860    Claude Helper:86312  00102 00000008 0000000002e51e8a 20000080 04000900      3      0 000004
udp4       0      0  *.5353                 *.*                                   0            0  786896    9216     mDNSResponder:390   00100 00000000 0000000002e3f001 00000000 00000800      1      0 000000
udp4       0      0  192.168.0.116.63770    172.217.160.67.443                         9522         3676 1048576   29040 Google Chrome He:21037  00102 00000000 0000000002e51f4d 20000000 04200900      2      0 000002
"""
let parsed = PortScanner.parse(sample)
check(parsed.count == 3, "parse keeps LISTEN + bound UDP only (\(parsed.count))")
check(parsed.contains { $0.port == 7000 && $0.pid == 21037 && $0.netstatName == "Google Chrome He" && $0.family == "IPv4+6" }, "process names with spaces parsed")
check(parsed.contains { $0.proto == "UDP" && $0.port == 5353 && $0.pid == 390 }, "UDP bound socket parsed")
let sock = socket(AF_INET, SOCK_STREAM, 0)
var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = 0
_ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
listen(sock, 1)
var bound = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
_ = withUnsafeMutablePointer(to: &bound) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(sock, $0, &len) } }
let myPort = Int(UInt16(bigEndian: bound.sin_port))
let live = PortScanner.listening()
check(live.contains { $0.port == myPort && $0.pid == getpid() }, "live scan finds our listener on \(myPort) (\(live.count) listening sockets)")
hardwareCheck(live.contains { ProcList.basic(pid: $0.pid)?.uid == 0 }, "root-owned listening sockets visible without root")
close(sock)

// MARK: - Disk scan
section("Disk scan")
write("tree/a/file1", bytes: 10_000)
write("tree/a/b/file2", bytes: 20_000)
write("tree/c/file3", bytes: 5_000)
_ = link(PathUtil.join(T, "tree/a/file1"), PathUtil.join(T, "tree/c/hardlink-to-file1"))
_ = symlink("/usr/share/dict/words", PathUtil.join(T, "tree/c/symlink-to-words"))
let treeRoot = PathUtil.join(T, "tree")
usleep(1_500_000) // let fseventsd assign IDs to the setup writes before the baseline scan
let scanner = DiskScanner()
guard let t1 = scanner.scan(root: treeRoot, previous: nil) else { fatalError("scan cancelled") }
let logicalExpected: Int64 = 10_000 + 20_000 + 5_000 + Int64("/usr/share/dict/words".utf8.count)
check(t1.totalLogical[0] == logicalExpected, "hard link counted once, symlink not followed (logical \(t1.totalLogical[0]) == \(logicalExpected))")
check(t1.count == 4, "4 directories (\(t1.count))")
check(t1.totalItems[0] == 8, "item count 8 (\(t1.totalItems[0]))")
let listing = DiskListing.items(in: t1, dir: 0)
check(listing.map(\.name) == ["a", "c"], "listing sorted by size: \(listing.map(\.name))")
try! ScanCache.save(t1)
let loaded = ScanCache.load(root: treeRoot)
check(loaded?.count == t1.count && loaded?.totalAlloc[0] == t1.totalAlloc[0], "cache round-trip")
write("tree/c/file4", bytes: 7_000)
usleep(1_500_000) // let fseventsd record the change
guard let t2 = DiskScanner().scan(root: treeRoot, previous: loaded) else { fatalError() }
check(t2.totalLogical[0] == logicalExpected + 7_000, "incremental rescan picks up new file (\(t2.totalLogical[0]))")
check(t2.reusedDirs >= 2, "incremental rescan reused unchanged dirs (\(t2.reusedDirs) of \(t2.count))")
// Re-read the folder holding the *other* link path; the hard-linked file must still count once.
write("tree/a/file5", bytes: 1_000)
try! ScanCache.save(t2)
usleep(1_500_000)
guard let t3 = DiskScanner().scan(root: treeRoot, previous: ScanCache.load(root: treeRoot)) else { fatalError() }
check(t3.totalLogical[0] == logicalExpected + 8_000, "hard link still counted once after rescans of either side (\(t3.totalLogical[0]))")

// MARK: - Developer artifacts
section("Developer artifacts")
write("proj-node/package.json"); write("proj-node/node_modules/lodash/index.js", bytes: 50_000); write("proj-node/src/app.js", bytes: 100)
write("proj-node/.git/HEAD"); write("proj-node/.git/logs/HEAD")
write("stray/node_modules/x.js", bytes: 1_000)                 // no package.json → not flagged
write("mvn/pom.xml"); write("mvn/target/classes/A.class", bytes: 3_000)
write("notmvn/target/data.bin", bytes: 3_000)                   // no pom.xml → not flagged
write("grd/build.gradle.kts"); write("grd/build/libs/app.jar", bytes: 4_000)
write("notgrd/build/out.txt", bytes: 100)                       // no gradle marker → not flagged
write("py/myenv/pyvenv.cfg"); write("py/myenv/lib/site.py", bytes: 2_000)
write("py/env/readme.txt")                                      // "env" without pyvenv.cfg → not flagged
write("conda/envs/ml/conda-meta/history"); write("conda/envs/ml/lib/x.so", bytes: 6_000)
write("conda/conda-meta/history"); mkdir("conda/pkgs"); mkdir("conda/condabin")   // base install → only envs/ml flagged
write("rs/Cargo.toml"); write("rs/target/debug/app", bytes: 8_000)
write("proj-node/node_modules/lodash/package.json")             // nested package.json inside node_modules is ignored
_ = link(PathUtil.join(T, "mvn/target/classes/A.class"), PathUtil.join(T, "mvn-shared-link"))
for rel in ["proj-node", "proj-node/src/app.js", "proj-node/package.json", "proj-node/src", "proj-node/node_modules", "proj-node/node_modules/lodash",
            "proj-node/node_modules/lodash/index.js", "proj-node/node_modules/lodash/package.json", "proj-node/.git", "proj-node/.git/HEAD"] { setMtime(rel, daysAgo: 90) }
setMtime("proj-node/.git/logs/HEAD", daysAgo: 12.5)

usleep(1_500_000) // let setup writes settle in FSEvents before the baseline scan
let ascan = ArtifactScanner()
guard let ar = ascan.scan(roots: [T], home: T, previous: nil) else { fatalError() }
func find(_ rel: String) -> Artifact? { ar.artifacts.first { $0.path == PathUtil.join(T, rel) } }
let expected: [(String, ArtifactKind)] = [("proj-node/node_modules", .nodeModules), ("mvn/target", .mavenTarget), ("grd/build", .gradleBuild),
                                          ("py/myenv", .pythonVenv), ("conda/envs/ml", .condaEnv), ("rs/target", .rustTarget)]
for (rel, kind) in expected { check(find(rel)?.kind == kind, "\(rel) detected as \(kind.displayName)") }
for rel in ["stray/node_modules", "notmvn/target", "notgrd/build", "py/env", "conda", "tree"] { check(find(rel) == nil, "\(rel) not flagged") }
check(ar.artifacts.count == expected.count, "exactly \(expected.count) artifacts (\(ar.artifacts.map { PathUtil.abbreviate($0.path) }))")
if let nm = find("proj-node/node_modules") {
    check(nm.logicalSize == 50_000 + Int64("".utf8.count), "node_modules logical size \(nm.logicalSize)")
    check(nm.projectName == "proj-node", "owning project proj-node")
    check(nm.lastActivitySource == "git activity" && nm.daysSinceActivity == 12, "last activity = git (12 days): \(nm.lastActivitySource) \(nm.daysSinceActivity ?? -1)")
}
if let mv = find("mvn/target") { check(mv.reclaimable == 0 && mv.allocSize > 0, "hard-linked file excluded from reclaimable (\(mv.reclaimable)) but counted in size") }
ArtifactScanner.saveCache(ar)
guard let ar2 = ArtifactScanner().scan(roots: [T], home: T, previous: ArtifactScanner.loadCache()) else { fatalError() }
check(ar2.reusedSizes >= 5, "artifact rescan reused unchanged sizes (\(ar2.reusedSizes))")

// MARK: - Updates
section("Updates")
do {
    let v = { (s: String) in SemVer(s)! }
    check(v("1.0.0") < v("1.0.1") && v("1.0.9") < v("1.1.0") && v("1.9.9") < v("2.0.0") && v("v1.2.3") == v("1.2.3"),
          "semver ordering (patch < minor < major, v-prefix ignored)")
    check(v("1.1.0-beta.1") < v("1.1.0") && !(v("1.1.0") < v("1.1.0")) && SemVer("abc") == nil, "prerelease sorts before release; junk rejected")

    let good = ###"{"tag_name":"v1.2.0","draft":false,"prerelease":false,"published_at":"2026-09-27T18:06:17Z","html_url":"https://github.com/amrakshay/maclens/releases/tag/v1.2.0","body":"## [1.2.0](x)\n### Features\n* thing","assets":[{"name":"MacLens-1.2.0.zip","browser_download_url":"https://github.com/amrakshay/maclens/releases/download/v1.2.0/MacLens-1.2.0.zip"},{"name":"MacLens-1.2.0.zip.sha256","browser_download_url":"https://github.com/amrakshay/maclens/releases/download/v1.2.0/MacLens-1.2.0.zip.sha256"}]}"###
    let r = try? Updater.parseRelease(Data(good.utf8))
    check(r?.version == v("1.2.0") && r?.zipURL.lastPathComponent == "MacLens-1.2.0.zip" && r?.notes.contains("Features") == true && r?.publishedAt != nil,
          "release JSON parsed (version, assets, notes, date)")
    let evil = good.replacingOccurrences(of: "https://github.com/amrakshay/maclens/releases/download/v1.2.0/MacLens-1.2.0.zip\"", with: "https://evil.example/MacLens-1.2.0.zip\"")
    check((try? Updater.parseRelease(Data(evil.utf8))) == nil, "assets not hosted on this repo's releases are rejected")
    let draft = good.replacingOccurrences(of: #""draft":false"#, with: #""draft":true"#)
    check((try? Updater.parseRelease(Data(draft.utf8))) == nil, "draft releases are ignored")

    check(Updater.installKind(bundlePath: "/Users/x/proj/.build/debug/MacLens") != .direct, "unbundled dev build is not auto-updated")
    if case .unsupported = Updater.installKind(bundlePath: PathUtil.join(T, "dist/MacLens.app")) { check(true, "dist/ build is not auto-updated") } else { check(false, "dist/ build is not auto-updated") }
    mkdir("apps/Caskroom/maclens")
    let fakeBrew = PathUtil.join(T, "apps/brew"); write("apps/brew"); chmod(fakeBrew, 0o755)
    check(Updater.installKind(bundlePath: PathUtil.join(T, "apps/MacLens.app"), caskrooms: [PathUtil.join(T, "apps/Caskroom/maclens")], brews: [fakeBrew]) == .homebrew(brew: fakeBrew),
          "Homebrew install detected from the Caskroom entry")
    check(Updater.installKind(bundlePath: PathUtil.join(T, "apps/MacLens.app"), caskrooms: [PathUtil.join(T, "nope")], brews: []) == .direct,
          "direct download in a writable folder is updated in place")

    check(Updater.parseChecksumFile("A1B2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90  MacLens-1.2.0.zip") == "a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f60718293a4b5c6d7e8f90"
          && Updater.parseChecksumFile("nonsense") == nil, "checksum file parsed; garbage rejected")

    // Build tiny ad-hoc-signed MacLens-like bundles to exercise verification and the full direct install.
    func makeBundle(_ rel: String, version: String, id: String = Updater.bundleID) -> URL {
        let app = URL(fileURLWithPath: PathUtil.join(T, rel))
        try! fm.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try! fm.copyItem(atPath: "/usr/bin/true", toPath: app.appendingPathComponent("Contents/MacOS/MacLens").path)
        let plist: [String: Any] = ["CFBundleIdentifier": id, "CFBundleShortVersionString": version, "CFBundleExecutable": "MacLens",
                                    "CFBundlePackageType": "APPL", "CFBundleName": "MacLens"]
        (plist as NSDictionary).write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true)
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        p.arguments = ["--force", "--sign", "-", app.path]; p.standardError = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
        return app
    }
    let newer = makeBundle("upd/new/MacLens.app", version: "9.0.0")
    check((try? Updater.verifyBundle(newer, newerThan: v("1.0.0"))) == v("9.0.0"), "valid newer bundle passes verification")
    check((try? Updater.verifyBundle(newer, newerThan: v("9.0.0"))) == nil, "same version is refused")
    let wrongID = makeBundle("upd/wrong/MacLens.app", version: "9.0.0", id: "com.example.other")
    check((try? Updater.verifyBundle(wrongID, newerThan: v("1.0.0"))) == nil, "different bundle identifier is refused")
    let tampered = makeBundle("upd/tampered/MacLens.app", version: "9.0.0")
    try! "hacked".write(to: tampered.appendingPathComponent("Contents/MacOS/MacLens"), atomically: true, encoding: .utf8)
    check((try? Updater.verifyBundle(tampered, newerThan: v("1.0.0"))) == nil, "bundle modified after signing is refused")

    // Quarantine (#11): cleared only after verification passes, recursively; tampered bundles keep it.
    func quarantine(_ url: URL) {
        let v = "0081;6ab96c1e;Safari;"
        _ = v.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) }
    }
    let q = makeBundle("upd/q/MacLens.app", version: "9.0.0")
    quarantine(q); quarantine(q.appendingPathComponent("Contents/MacOS/MacLens"))
    check(Updater.isQuarantined(q), "test bundle carries the quarantine flag")
    check((try? Updater.verifyAndClearQuarantine(q, newerThan: v("1.0.0"))) == v("9.0.0") && !Updater.isQuarantined(q)
          && !Updater.isQuarantined(q.appendingPathComponent("Contents/MacOS/MacLens")), "verified bundle: quarantine cleared recursively")
    quarantine(tampered)
    check((try? Updater.verifyAndClearQuarantine(tampered, newerThan: v("1.0.0"))) == nil && Updater.isQuarantined(tampered),
          "tampered bundle: verification fails and the quarantine flag is left in place")
    quarantine(newer) // simulate a release zip whose app arrives quarantined

    // End-to-end direct install from local files: zip + checksum → verify → swap the "installed" app.
    let installed = makeBundle("upd/Applications/MacLens.app", version: "1.0.0")
    let zipURL = URL(fileURLWithPath: PathUtil.join(T, "upd/MacLens-9.0.0.zip"))
    let z = Process(); z.executableURL = URL(fileURLWithPath: "/usr/bin/ditto"); z.arguments = ["-c", "-k", "--keepParent", newer.path, zipURL.path]
    try! z.run(); z.waitUntilExit()
    let shaURL = URL(fileURLWithPath: zipURL.path + ".sha256")
    try! "\(try! Updater.sha256Hex(of: zipURL))  MacLens-9.0.0.zip\n".write(to: shaURL, atomically: true, encoding: .utf8)
    let rel = ReleaseInfo(version: v("9.0.0"), tag: "v9.0.0", notes: "", publishedAt: nil,
                          pageURL: URL(string: "https://github.com/amrakshay/maclens")!, zipURL: zipURL, sha256URL: shaURL)
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var installErr: Error?
    Task { do { try await Updater.installDirect(rel, replacing: installed, currentVersion: v("1.0.0")) { _ in } } catch { installErr = error }; done.signal() }
    done.wait()
    let nowVersion = NSDictionary(contentsOf: installed.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    check(installErr == nil && nowVersion == "9.0.0", "direct install swapped the app to 9.0.0 (\(installErr?.localizedDescription ?? "ok"))")
    check(!Updater.isQuarantined(installed), "direct install: the new app has no quarantine flag (opens without the Gatekeeper prompt)")

    // Homebrew path with a fake `brew` that "upgrades" by copying a quarantined newer bundle into place.
    let brewApp = makeBundle("upd/brew/Applications/MacLens.app", version: "1.0.0")
    let src = makeBundle("upd/brew/src/MacLens.app", version: "9.1.0")
    quarantine(src)
    let fakeBrewUp = PathUtil.join(T, "upd/brew/brew")
    // Fake brew: `update` records that the tap was refreshed; `upgrade` only "sees" the new version after an update
    // and with auto-update disabled — mirroring #17, where a stale tap made upgrade a silent no-op.
    let brewLog = PathUtil.join(T, "upd/brew/calls.log")
    try! """
    #!/bin/sh
    echo "$* NO_AUTO_UPDATE=$HOMEBREW_NO_AUTO_UPDATE" >> '\(brewLog)'
    case "$1" in
      update) touch '\(brewLog).updated' ;;
      upgrade) [ -f '\(brewLog).updated' ] || exit 0
               /bin/rm -rf '\(brewApp.path)' && /usr/bin/ditto '\(src.path)' '\(brewApp.path)' ;;
    esac

    """.write(toFile: fakeBrewUp, atomically: true, encoding: .utf8)
    chmod(fakeBrewUp, 0o755)
    nonisolated(unsafe) var brewErr: Error?
    Task { do { try await Updater.installHomebrew(brew: fakeBrewUp, appPath: brewApp.path, currentVersion: v("1.0.0")) { _ in } } catch { brewErr = error }; done.signal() }
    done.wait()
    let brewV = NSDictionary(contentsOf: brewApp.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    check(brewErr == nil && brewV == "9.1.0" && !Updater.isQuarantined(brewApp),
          "Homebrew path: upgraded app verified and quarantine cleared (\(brewErr?.localizedDescription ?? "ok"))")
    let calls = (try? String(contentsOfFile: brewLog, encoding: .utf8)) ?? ""
    check(calls.hasPrefix("update") && calls.contains("upgrade --cask maclens NO_AUTO_UPDATE=1"),
          "Homebrew path: taps refreshed with `brew update` before upgrading (#17): \(calls.split(separator: "\n").map(String.init))")
    let fakeBrewNoop = PathUtil.join(T, "upd/brew/brew-noop")
    try! "#!/bin/sh\nexit 0\n".write(toFile: fakeBrewNoop, atomically: true, encoding: .utf8); chmod(fakeBrewNoop, 0o755)
    nonisolated(unsafe) var noopErr: Error?
    Task { do { try await Updater.installHomebrew(brew: fakeBrewNoop, appPath: brewApp.path, currentVersion: v("9.1.0")) { _ in } } catch { noopErr = error }; done.signal() }
    done.wait()
    check(noopErr != nil, "Homebrew path: brew that installs nothing newer is reported as a failure")

    let badSha = URL(fileURLWithPath: PathUtil.join(T, "upd/bad.sha256"))
    try! "\(String(repeating: "0", count: 64))  MacLens-9.0.0.zip\n".write(to: badSha, atomically: true, encoding: .utf8)
    let installed2 = makeBundle("upd/Applications2/MacLens.app", version: "1.0.0")
    let relBad = ReleaseInfo(version: v("9.0.0"), tag: "v9.0.0", notes: "", publishedAt: nil,
                             pageURL: URL(string: "https://github.com/amrakshay/maclens")!, zipURL: zipURL, sha256URL: badSha)
    nonisolated(unsafe) var badErr: Error?
    Task { do { try await Updater.installDirect(relBad, replacing: installed2, currentVersion: v("1.0.0")) { _ in } } catch { badErr = error }; done.signal() }
    done.wait()
    let still = NSDictionary(contentsOf: installed2.appendingPathComponent("Contents/Info.plist"))?["CFBundleShortVersionString"] as? String
    check(badErr != nil && still == "1.0.0", "checksum mismatch aborts and leaves the installed app untouched")

    // Live: the real latest release parses (skipped when offline / rate-limited).
    nonisolated(unsafe) var live: ReleaseInfo?
    nonisolated(unsafe) var liveErr: Error?
    Task { do { live = try await Updater.fetchLatest(currentVersion: "0.0.0") } catch { liveErr = error }; done.signal() }
    done.wait()
    if let live {
        check(live.version >= v("1.0.0") && live.zipURL.absoluteString.hasPrefix("https://github.com/amrakshay/maclens/releases/download/"),
              "live latest release: \(live.tag)")
    } else {
        print("  – skipped live release check: \(liveErr?.localizedDescription ?? "unknown")")
    }
}

// MARK: - Additional services (VoiceMode)
section("Additional services")
do {
    // Fake home with only a whisper install and a CLI on a custom PATH; nothing is started or stopped.
    let home = PathUtil.join(T, "vmhome")
    mkdir("vmhome/.voicemode/services/whisper"); mkdir("vmhome/bin"); mkdir("vmhome/Library/LaunchAgents")
    let cli = PathUtil.join(home, "bin/voicemode")
    fm.createFile(atPath: cli, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
    check(VoiceMode.locate(home: home, path: "/nonexistent") == nil, "voicemode not found when absent")
    check(VoiceMode.locate(home: home, path: "/nonexistent:" + PathUtil.join(home, "bin")) == cli, "voicemode found on PATH")
    let whisper = VoiceMode.components.first { $0.id == "whisper" }!, kokoro = VoiceMode.components.first { $0.id == "kokoro" }!
    check(VoiceMode.isInstalled(whisper, home: home) && !VoiceMode.isInstalled(kokoro, home: home), "install detected per component")
    check(!VoiceMode.startsAtLogin(whisper, home: home), "no LaunchAgent → doesn't start at login")
    fm.createFile(atPath: VoiceMode.plistPath(whisper, home: home), contents: Data())
    check(VoiceMode.startsAtLogin(whisper, home: home), "LaunchAgent plist → starts at login")

    let l = PortScanner.parse("""
    tcp4       0      0  *.2022                 *.*                    LISTEN                 0            0  131072  131072     whisper-server:489   00100 00000106 0000000002e45ef8 00000000 00000800      1      0 000000
    tcp4       0      0  *.8880                 *.*                    LISTEN                 0            0  131072  131072               node:700   00100 00000106 0000000002e45ef8 00000000 00000800      1      0 000000
    """)
    let args: (Int32) -> [String]? = { $0 == 489 ? [home + "/.voicemode/services/whisper/build/bin/whisper-server", "--port", "2022"] : ["node", "server.js"] }
    let name: (Int32) -> String = { $0 == 700 ? "node" : "?" }
    check(VoiceMode.state(of: whisper, installed: true, listeners: l, arguments: args, name: name) == .running(pid: 489), "whisper listener → running")
    check(VoiceMode.state(of: kokoro, installed: true, listeners: l, arguments: args, name: name) == .portInUse(pid: 700, name: "node"), "foreign process on 8880 → port in use")
    check(VoiceMode.state(of: kokoro, installed: true, listeners: [], arguments: args, name: name) == .stopped, "no listener → stopped")
    check(VoiceMode.state(of: kokoro, installed: false, listeners: [], arguments: args, name: name) == .notInstalled, "not installed")
    check(VoiceMode.looksFailed("❌ Failed to start kokoro: boom") && !VoiceMode.looksFailed("⚠️ Kokoro process started but not listening on port 8880 yet"),
          "CLI failure detected from its output (it exits 0)")
    // The runner itself, against a stub CLI that echoes its arguments.
    fm.createFile(atPath: cli, contents: Data("#!/bin/sh\necho \"✅ $2 $3\"\n".utf8), attributes: [.posixPermissions: 0o755])
    let r = VoiceMode.run(.start, whisper, executable: cli)
    check(r.ok && r.output == "✅ start whisper", "runs `service start whisper` (\(r.output))")
}

// MARK: - Water reminders
section("Water reminders")
do {
    let ist = TimeZone(identifier: "Asia/Kolkata")!
    var cal = Calendar(identifier: .gregorian); cal.timeZone = ist
    // 2026-09-28 is a Monday.
    func at(_ day: Int, _ h: Int, _ m: Int) -> Date { cal.date(from: DateComponents(year: 2026, month: 9, day: day, hour: h, minute: m))! }
    let sched = WorkSchedule()
    check(!sched.contains(at(28, 9, 59)) && sched.contains(at(28, 10, 0)) && sched.contains(at(28, 18, 59)) && !sched.contains(at(28, 19, 0)),
          "IST shift is 10:00–19:00 (end exclusive)")
    check(!sched.contains(at(26, 12, 0)) && !sched.contains(at(27, 12, 0)) && sched.contains(at(25, 12, 0)), "Mon–Fri by default: Sat and Sun off, Fri on")
    var utc = WorkSchedule(); utc.timeZone = TimeZone(identifier: "UTC")!
    check(!utc.contains(at(28, 10, 0)) && utc.contains(at(28, 15, 30)), "shift follows its own time zone (10:00 IST = 04:30 UTC)")
    check(sched.shiftEnd(containing: at(28, 15, 0)) == at(28, 19, 0) && sched.shiftEnd(containing: at(28, 20, 0)) == nil, "end of shift")

    var e = WaterReminderEngine()
    check(e.tick(now: at(28, 10, 0), sharing: false, away: false, alertVisible: false) == .wait(.notDue), "first tick only starts the interval")
    check(e.tick(now: at(28, 10, 29), sharing: false, away: false, alertVisible: false) == .wait(.notDue), "not due before 30 min")
    check(e.tick(now: at(28, 10, 30), sharing: true, away: false, alertVisible: false) == .wait(.sharing), "due while sharing → deferred")
    check(e.tick(now: at(28, 11, 0), sharing: true, away: false, alertVisible: false) == .wait(.sharing) && e.owed, "still one owed after another interval (no pile-up)")
    check(e.tick(now: at(28, 11, 5), sharing: false, away: false, alertVisible: false) == .show, "shown once sharing ends")
    check(e.tick(now: at(28, 11, 6), sharing: false, away: false, alertVisible: false) == .wait(.notDue) && e.nextDue == at(28, 11, 35), "then one interval later, not immediately again")
    check(e.tick(now: at(28, 11, 35), sharing: false, away: true, alertVisible: false) == .wait(.away), "away → skipped")
    check(e.tick(now: at(28, 11, 36), sharing: false, away: false, alertVisible: false) == .wait(.notDue), "skipped while away is not owed")
    check(e.tick(now: at(28, 12, 5), sharing: false, away: false, alertVisible: true) == .wait(.alertVisible), "no second alert while one is on screen")
    e.pausedUntil = at(28, 13, 0)
    check(e.tick(now: at(28, 12, 40), sharing: false, away: false, alertVisible: false) == .wait(.paused) && e.owed, "due while paused → owed")
    check(e.tick(now: at(28, 13, 0), sharing: false, away: false, alertVisible: false) == .show && e.pausedUntil == nil, "shown once the pause ends")
    e.pausedUntil = at(28, 16, 0)
    _ = e.tick(now: at(28, 13, 40), sharing: false, away: false, alertVisible: false)
    e.pausedUntil = nil // Resume now
    check(e.tick(now: at(28, 13, 41), sharing: false, away: false, alertVisible: false) == .show, "Resume now shows the owed reminder")
    e.snooze(10 * 60, now: at(28, 13, 41))
    check(e.nextDue == at(28, 13, 51), "snooze sets the next reminder")
    check(e.tick(now: at(28, 18, 50), sharing: true, away: false, alertVisible: false) == .wait(.sharing), "owed near end of shift")
    check(e.tick(now: at(28, 19, 0), sharing: false, away: false, alertVisible: false) == .wait(.offHours) && !e.owed, "owed reminder dropped at end of shift")
    check(e.tick(now: at(29, 10, 0), sharing: false, away: false, alertVisible: false) == .wait(.notDue), "next day starts fresh")
    check(PresenceSignals.idleSeconds() != nil, "HID idle time readable without permission (\(PresenceSignals.idleSeconds().map { String(format: "%.0f s", $0) } ?? "n/a"))")
    hardwareCheck(PresenceSignals.screenIsShared() != nil, "screen-watcher check available on this macOS")
}

// MARK: - Deletion guard
section("Deletion guard")
let blocked = ["/System/Library", "/usr/bin/true", "/usr/local", "/bin/ls", "/sbin/mount", "/Library/Preferences", "/private/var/log",
               "/tmp", "/etc/hosts", "/", PathUtil.home, "/Users", "/Applications/Safari.app", "/System/Volumes/Data/Library",
               T + "/../x", "relative/path"]
for p in blocked {
    let v = DeletionGuard.check(p)
    check(!v.isAllowed, "blocked \(p): \(v.reason ?? "ALLOWED")")
}
check(DeletionGuard.check(PathUtil.join(T, "tree/a/file1")) == .allowed, "own file in test dir allowed")
if fm.fileExists(atPath: "/usr/local/bin") {
    let v = DeletionGuard.check("/usr/local/bin")
    check(v.reason?.contains("/usr") != true, "/usr/local/* is not blocked as a system path (\(v.reason ?? "allowed"))")
}
let outside = Deleter.delete([PathUtil.home + "/maclens-nonexistent-\(UUID().uuidString)"], mode: .permanent)
check(outside[0].error?.contains("SANDBOX") == true, "Deleter refuses paths outside the sandbox")
let sys = Deleter.delete(["/System/Library/CoreServices"], mode: .trash)
check(sys[0].error != nil, "Deleter refuses system paths: \(sys[0].error ?? "")")
let r1 = Deleter.delete([PathUtil.join(T, "notgrd")], mode: .permanent)
check(r1[0].error == nil && !fm.fileExists(atPath: PathUtil.join(T, "notgrd")), "permanent delete inside test dir")
write("maclens-selftest-trash-me.txt", bytes: 10)
let r2 = Deleter.delete([PathUtil.join(T, "maclens-selftest-trash-me.txt")], mode: .trash)
check(r2[0].error == nil && !fm.fileExists(atPath: PathUtil.join(T, "maclens-selftest-trash-me.txt")), "move to Trash inside test dir")

// MARK: - Cleanup
let cleanup = Deleter.delete([T], mode: .permanent)
print("\ncleanup: \(cleanup[0].error ?? "removed \(T)")")
print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
