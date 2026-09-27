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
let ws = procs.first { $0.name == "WindowServer" }
hardwareCheck(ws?.isSystem == true, "WindowServer classified system: \(ws?.systemReasons ?? [])")
check(procs.first { $0.pid == getpid() }?.isSystem == false, "this test binary is not system")
check(ProcList.arguments(pid: getpid())?.first?.hasSuffix("maclens-selftest") == true, "own arguments readable")
check(ProcList.arguments(pid: 1) == nil, "root process arguments not readable (expected without root)")
print("    x=\(x > 0)")

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
