import AppKit
import SwiftUI
import MacLensCore

@MainActor final class DiskStore: ObservableObject {
    enum Target: Hashable { case home, dataVolume, folder(String) }

    @Published var target: Target = .home
    @Published private(set) var tree: ScanTree?
    @Published private(set) var scanning = false
    @Published private(set) var progress = ScanProgress.Snapshot()
    @Published private(set) var current: Int32 = 0
    @Published private(set) var items: [DiskItem] = []
    @Published private(set) var status = ""
    @Published var showLogical = false
    private var scanner: DiskScanner?
    private var timer: Timer?

    var rootPath: String {
        switch target {
        case .home: return PathUtil.home
        case .dataVolume: return "/System/Volumes/Data"
        case .folder(let p): return p
        }
    }

    /// Loads the cached tree for the current target (if any) so results show instantly.
    func loadCachedIfNeeded() {
        guard tree == nil, !scanning else { return }
        let root = rootPath
        DispatchQueue.global(qos: .userInitiated).async {
            let t = ScanCache.load(root: root)
            DispatchQueue.main.async {
                guard let t, self.rootPath == root, self.tree == nil else { return }
                self.tree = t
                self.status = "Cached scan from \(Fmt.relative(t.scanDate)). Rescan to update (only changed folders are re-read)."
                self.open(0)
            }
        }
    }

    /// The tree lives in the on-disk cache; drop it from memory while the window is hidden.
    func releaseTreeIfIdle() {
        guard !scanning, tree != nil else { return }
        tree = nil; items = []; current = 0
    }

    func setTarget(_ t: Target) {
        guard !scanning else { return }
        target = t; tree = nil; items = []; current = 0; status = ""
        loadCachedIfNeeded()
    }

    func scan() {
        guard !scanning else { return }
        let root = rootPath
        let previous = tree?.rootPath == root ? tree : nil
        let s = DiskScanner()
        scanner = s
        scanning = true
        status = "Scanning \(PathUtil.abbreviate(root))…"
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.progress = s.progress.snapshot }
        }
        Thread.detachNewThread {
            let prev = previous ?? ScanCache.load(root: root)
            let t = s.scan(root: root, previous: prev)
            if let t { try? ScanCache.save(t) }
            DispatchQueue.main.async {
                self.timer?.invalidate(); self.timer = nil
                self.scanning = false
                self.scanner = nil
                self.progress = s.progress.snapshot
                guard let t else { self.status = "Scan cancelled."; return }
                self.tree = t
                let kind = t.reusedDirs > 0 ? "Rescan (re-read \(t.count - t.reusedDirs) changed of \(t.count) folders)" : "Full scan"
                var msg = "\(kind) in \(String(format: "%.1f", t.duration)) s."
                if t.skippedDirs > 0 { msg += " \(t.skippedDirs) folders couldn't be read — grant Full Disk Access to include them." }
                self.status = msg
                self.open(0)
            }
        }
    }

    func cancel() { scanner?.cancel() }

    func open(_ dir: Int32) {
        guard let tree else { return }
        current = dir
        DispatchQueue.global(qos: .userInitiated).async {
            let list = DiskListing.items(in: tree, dir: dir)
            DispatchQueue.main.async { if self.tree === tree && self.current == dir { self.items = list } }
        }
    }

    func up() {
        guard let tree, current > 0 else { return }
        open(tree.parent[Int(current)])
    }

    var breadcrumbs: [(String, Int32)] {
        guard let tree else { return [] }
        var out: [(String, Int32)] = []
        var i = current
        while i > 0 { out.append((tree.names[Int(i)], i)); i = tree.parent[Int(i)] }
        out.append((PathUtil.abbreviate(tree.rootPath), 0))
        return out.reversed()
    }

    var currentTotal: Int64 {
        guard let tree else { return 0 }
        return showLogical ? tree.totalLogical[Int(current)] : tree.totalAlloc[Int(current)]
    }

    /// Moves an item to the Trash (guarded in `Deleter`) and updates the tree totals.
    func trash(_ item: DiskItem) -> String? {
        let r = Deleter.delete([item.path], mode: .trash)[0]
        if let e = r.error { return e }
        if let tree {
            if item.isDirectory { tree.markRemoved(item.treeIndex) } else { tree.subtractFile(in: current, alloc: item.alloc, logical: item.logical) }
            objectWillChange.send()
            open(current)
        }
        return nil
    }
}

@MainActor final class ArtifactStore: ObservableObject {
    @Published var roots: [String] { didSet { UserDefaults.standard.set(roots, forKey: "artifactRoots") } }
    @Published private(set) var result: ArtifactScanResult?
    @Published private(set) var scanning = false
    @Published private(set) var progress = ScanProgress.Snapshot()
    @Published private(set) var verdicts: [String: DeletionVerdict] = [:]
    @Published var kinds: Set<ArtifactKind> = Set(ArtifactKind.allCases)
    @Published var olderThanEnabled = false
    @Published var olderThanDays = 30
    @Published var search = ""
    @Published private(set) var status = ""
    private var scanner: ArtifactScanner?
    private var timer: Timer?

    init() {
        roots = UserDefaults.standard.stringArray(forKey: "artifactRoots") ?? [PathUtil.home]
        if var cached = ArtifactScanner.loadCache() {
            cached.artifacts.removeAll { !FileManager.default.fileExists(atPath: $0.path) } // deleted since the scan
            result = cached
            status = "Cached results from \(Fmt.relative(cached.date)). Rescan to refresh."
            computeVerdicts()
        }
    }

    var filtered: [Artifact] {
        guard let r = result else { return [] }
        return r.artifacts.filter { a in
            guard kinds.contains(a.kind) else { return false }
            if olderThanEnabled, let d = a.daysSinceActivity, d < olderThanDays { return false }
            if !search.isEmpty && !a.path.localizedCaseInsensitiveContains(search) && !a.projectName.localizedCaseInsensitiveContains(search) { return false }
            return true
        }
    }

    func scan() {
        guard !scanning else { return }
        let s = ArtifactScanner()
        scanner = s
        scanning = true
        status = "Scanning \(roots.map(PathUtil.abbreviate).joined(separator: ", "))…"
        let roots = self.roots, previous = result
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.progress = s.progress.snapshot }
        }
        Thread.detachNewThread {
            let r = s.scan(roots: roots, previous: previous)
            if let r { ArtifactScanner.saveCache(r) }
            DispatchQueue.main.async {
                self.timer?.invalidate(); self.timer = nil
                self.scanning = false
                self.scanner = nil
                guard let r else { self.status = "Scan cancelled."; return }
                self.result = r
                self.status = "Found \(r.artifacts.count) items in \(String(format: "%.1f", r.duration)) s" +
                    (r.reusedSizes > 0 ? " (\(r.reusedSizes) unchanged sizes reused)." : ".")
                self.computeVerdicts()
            }
        }
    }

    func cancel() { scanner?.cancel() }

    private func computeVerdicts() {
        guard let r = result else { return }
        let paths = r.artifacts.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async {
            var v: [String: DeletionVerdict] = [:]
            for p in paths { v[p] = DeletionGuard.check(p) }
            DispatchQueue.main.async { self.verdicts = v }
        }
    }

    func verdict(_ a: Artifact) -> DeletionVerdict { verdicts[a.path] ?? DeletionGuard.check(a.path) }

    @Published private(set) var deleting = false

    /// Deletes off the main thread (permanent deletes of big trees take a while); the guard runs inside `Deleter`.
    func delete(_ items: [Artifact], mode: DeleteMode, completion: @escaping ([DeleteOutcome]) -> Void) {
        deleting = true
        let paths = items.map(\.path)
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = Deleter.delete(paths, mode: mode)
            DispatchQueue.main.async {
                self.deleting = false
                let removed = Set(outcomes.filter { $0.error == nil }.map(\.path))
                if var r = self.result {
                    r.artifacts.removeAll { removed.contains($0.path) }
                    self.result = r
                    ArtifactScanner.saveCache(r)
                }
                completion(outcomes)
            }
        }
    }
}

enum Fmt {
    static func bytes(_ b: Int64) -> String { b < 0 ? "—" : ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
    static func pct(_ v: Double) -> String { v < 0 ? "—" : String(format: "%.1f", v) }
    static func watts(_ w: Double, estimated: Bool = false) -> String {
        guard w >= 0 else { return "—" }
        let s = w < 0.1 ? String(format: "%.0f mW", w * 1000) : String(format: "%.2f W", w)
        return estimated ? "~" + s : s
    }
    static func relative(_ d: Date?) -> String {
        guard let d else { return "—" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }
    static func date(_ d: Date?) -> String {
        guard let d else { return "—" }
        return d.formatted(date: .abbreviated, time: .shortened)
    }
    static func minutes(_ m: Int?) -> String {
        guard let m else { return "—" }
        return m >= 60 ? "\(m / 60) h \(m % 60) min" : "\(m) min"
    }
}
