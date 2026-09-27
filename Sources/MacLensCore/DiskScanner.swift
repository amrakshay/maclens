import Foundation
import Darwin

/// Thread-safe scan counters for progress UI.
public final class ScanProgress: @unchecked Sendable {
    public struct Snapshot: Sendable { public var dirs = 0, files = 0, bytes: Int64 = 0, skipped = 0, reused = 0; public var current = ""; public init() {} }
    private var s = Snapshot()
    private let lock = NSLock()
    public init() {}
    public func reset() { lock.lock(); s = Snapshot(); lock.unlock() }
    func add(dirs: Int = 0, files: Int = 0, bytes: Int64 = 0, skipped: Int = 0, reused: Int = 0, current: String? = nil) {
        lock.lock()
        s.dirs += dirs; s.files += files; s.bytes += bytes; s.skipped += skipped; s.reused += reused
        if let current { s.current = current }
        lock.unlock()
    }
    public var snapshot: Snapshot { lock.lock(); defer { lock.unlock() }; return s }
}

/// Directory-only tree in parallel arrays (files are listed on demand), so memory scales with the
/// number of directories rather than files. Parents always have a lower index than their children.
public final class ScanTree: @unchecked Sendable {
    public let rootPath: String
    public var names: [String] = []
    public var parent: [Int32] = []
    public var mtime: [Int64] = []
    public var directAlloc: [Int64] = []
    public var directLogical: [Int64] = []
    public var directFiles: [Int32] = []
    public var flags: [UInt8] = []

    public private(set) var totalAlloc: [Int64] = []
    public private(set) var totalLogical: [Int64] = []
    public private(set) var totalItems: [Int64] = []
    private var childStart: [Int32] = []
    private var childList: [Int32] = []

    public var scanDate = Date()
    public var eventID: UInt64 = 0
    public var volumeUUID: String?
    public var skippedDirs = 0
    public var duration: Double = 0
    public var reusedDirs = 0
    /// Hard-linked file IDs (link count > 1) and the directory whose total counts them, so rescans don't double-count.
    public var linkOwners: [Int32: [UInt64]] = [:]

    public static let flagUnreadable: UInt8 = 1
    public static let flagRemoved: UInt8 = 2

    public init(rootPath: String) { self.rootPath = rootPath }
    public var count: Int { names.count }

    @discardableResult
    func append(name: String, parent p: Int32, mtime m: Int64) -> Int32 {
        names.append(name); parent.append(p); mtime.append(m)
        directAlloc.append(0); directLogical.append(0); directFiles.append(0); flags.append(0)
        return Int32(names.count - 1)
    }

    /// Computes subtree totals and child adjacency. Call once after building/loading.
    public func finalize() {
        let n = count
        totalAlloc = directAlloc
        totalLogical = directLogical
        totalItems = directFiles.map(Int64.init)
        var counts = [Int32](repeating: 0, count: n + 1)
        for i in stride(from: n - 1, through: 1, by: -1) {
            let p = Int(parent[i])
            guard flags[i] & Self.flagRemoved == 0 else { continue }
            totalAlloc[p] += totalAlloc[i]
            totalLogical[p] += totalLogical[i]
            totalItems[p] += totalItems[i] + 1
            counts[p] += 1
        }
        childStart = [Int32](repeating: 0, count: n + 1)
        for i in 0..<n { childStart[i + 1] = childStart[i] + counts[i] }
        childList = [Int32](repeating: 0, count: Int(childStart[n]))
        var fill = childStart
        for i in 1..<max(1, n) where flags[i] & Self.flagRemoved == 0 {
            let p = Int(parent[i])
            childList[Int(fill[p])] = Int32(i)
            fill[p] += 1
        }
    }

    public func children(of i: Int32) -> [Int32] {
        let a = Int(childStart[Int(i)]), b = Int(childStart[Int(i) + 1])
        return childList[a..<b].filter { flags[Int($0)] & Self.flagRemoved == 0 }
    }

    public func path(of i: Int32) -> String {
        var parts: [String] = []
        var cur = i
        while cur > 0 { parts.append(names[Int(cur)]); cur = parent[Int(cur)] }
        var p = rootPath
        for c in parts.reversed() { p = PathUtil.join(p, c) }
        return p
    }

    /// Removes a directory subtree from the totals (after it was deleted).
    public func markRemoved(_ i: Int32) {
        guard i > 0 else { return }
        flags[Int(i)] |= Self.flagRemoved
        let a = totalAlloc[Int(i)], l = totalLogical[Int(i)], items = totalItems[Int(i)] + 1
        var p = parent[Int(i)]
        while p >= 0 {
            totalAlloc[Int(p)] -= a; totalLogical[Int(p)] -= l; totalItems[Int(p)] -= items
            p = p == 0 ? -1 : parent[Int(p)]
        }
    }

    /// Removes a deleted file's bytes from its directory and ancestors.
    public func subtractFile(in dir: Int32, alloc: Int64, logical: Int64) {
        directAlloc[Int(dir)] -= alloc; directLogical[Int(dir)] -= logical; directFiles[Int(dir)] -= 1
        var p = dir
        while p >= 0 {
            totalAlloc[Int(p)] -= alloc; totalLogical[Int(p)] -= logical; totalItems[Int(p)] -= 1
            p = p == 0 ? -1 : parent[Int(p)]
        }
    }
}

/// Parallel, cancellable directory sizer with incremental rescans.
///
/// Size model (APFS):
///  - "On disk" = allocated bytes (ATTR_FILE_ALLOCSIZE); "logical" = file length. Sparse files and compression make them differ.
///  - Hard links: a file with link count > 1 is counted once per (device, file ID).
///  - Symlinks: counted as the link itself, never followed.
///  - Clones: allocated size counts cloned blocks in every clone (APFS can't attribute shared blocks to one file);
///    the Developer Artifacts view uses per-file private size to show what deletion would actually free.
///  - Other volumes (mount points / different st_dev) are not entered.
public final class DiskScanner: @unchecked Sendable {
    public let progress = ScanProgress()
    private var pool: WorkPool<Item>?
    private let poolLock = NSLock()

    struct Item {
        let idx: Int32
        let path: String
        let old: Int32   // index in previous tree, -1 = new
        let force: Bool  // re-read this whole subtree from disk
    }

    public init() {}

    public func cancel() {
        poolLock.lock(); pool?.cancel(); poolLock.unlock()
    }

    /// Scans `root`. With a `previous` tree of the same root, only directories reported changed by FSEvents are re-read.
    /// Returns nil if cancelled.
    public func scan(root: String, previous: ScanTree?, threads: Int = 6) -> ScanTree? {
        let started = monotonicSeconds()
        progress.reset()
        var rst = stat()
        guard lstat(root, &rst) == 0 else { return nil }
        let rootDev = rst.st_dev
        let uuid = FSEventsHistory.volumeUUID(for: root)
        let startEvent = FSEventsHistory.currentEventID() // captured first: changes during the scan show up next time

        var prev = previous
        var changes = FSChanges()
        if let p = prev, p.rootPath == root, p.volumeUUID == uuid, p.eventID > 0,
           let c = FSEventsHistory.changes(under: root, since: p.eventID) {
            changes = c
        } else {
            prev = nil
        }

        let tree = ScanTree(rootPath: root)
        tree.eventID = startEvent
        tree.volumeUUID = uuid
        tree.append(name: root, parent: -1, mtime: Int64(rst.st_mtimespec.tv_sec))

        let lock = NSLock()
        var counted = Set<UInt64>()                                      // hard-linked file IDs already attributed
        var pendingLinks: [(dir: Int32, id: UInt64, alloc: Int64, logical: Int64)] = []
        let p = WorkPool<Item>([Item(idx: 0, path: root, old: prev == nil ? -1 : 0, force: false)])
        poolLock.lock(); pool = p; poolLock.unlock()

        p.run(threads: threads) { [progress] item, buf in
            // Unchanged directory: reuse the previous result without touching the disk.
            if let prev, item.old >= 0, !item.force, !changes.dirty.contains(item.path), !changes.subtrees.contains(item.path) {
                let o = Int(item.old)
                var next: [Item] = []
                lock.lock()
                tree.directAlloc[Int(item.idx)] = prev.directAlloc[o]
                tree.directLogical[Int(item.idx)] = prev.directLogical[o]
                tree.directFiles[Int(item.idx)] = prev.directFiles[o]
                tree.flags[Int(item.idx)] = prev.flags[o] & ScanTree.flagUnreadable
                if let ids = prev.linkOwners[item.old] { tree.linkOwners[item.idx] = ids; counted.formUnion(ids) }
                for c in prev.children(of: item.old) {
                    let ci = tree.append(name: prev.names[Int(c)], parent: item.idx, mtime: prev.mtime[Int(c)])
                    next.append(Item(idx: ci, path: PathUtil.join(item.path, prev.names[Int(c)]), old: c, force: false))
                }
                lock.unlock()
                progress.add(dirs: 1, files: Int(prev.directFiles[o]), bytes: prev.directAlloc[o], reused: 1)
                p.push(next)
                return
            }

            let fd = BulkDir.open(item.path)
            guard fd >= 0 else {
                lock.lock(); tree.flags[Int(item.idx)] |= ScanTree.flagUnreadable; lock.unlock()
                progress.add(dirs: 1, skipped: 1)
                return
            }
            var alloc: Int64 = 0, logical: Int64 = 0, files: Int32 = 0
            var subdirs: [(String, Int64)] = []
            var links: [(dir: Int32, id: UInt64, alloc: Int64, logical: Int64)] = []
            BulkDir.forEach(fd: fd, buffer: buf) { e in
                guard e.devID == rootDev else { return }
                if e.isDirectory {
                    if !e.isMountPoint { subdirs.append((e.name, e.mtime)) }
                    return
                }
                files += 1
                if e.linkCount > 1 { // attributed after traversal, once per file ID
                    links.append((item.idx, e.fileID, e.allocSize, e.logicalSize))
                    return
                }
                alloc += e.allocSize
                logical += e.logicalSize
            }
            close(fd)

            var oldChildren: [String: Int32] = [:]
            if let prev, item.old >= 0, !item.force {
                for c in prev.children(of: item.old) { oldChildren[prev.names[Int(c)]] = c }
            }
            let forceChildren = item.force || changes.subtrees.contains(item.path)
            var next: [Item] = []
            next.reserveCapacity(subdirs.count)
            lock.lock()
            tree.directAlloc[Int(item.idx)] = alloc
            tree.directLogical[Int(item.idx)] = logical
            tree.directFiles[Int(item.idx)] = files
            pendingLinks.append(contentsOf: links)
            for (name, m) in subdirs {
                let ci = tree.append(name: name, parent: item.idx, mtime: m)
                next.append(Item(idx: ci, path: PathUtil.join(item.path, name), old: oldChildren[name] ?? -1, force: forceChildren))
            }
            lock.unlock()
            progress.add(dirs: 1, files: Int(files), bytes: alloc, current: item.path)
            p.push(next)
        }

        poolLock.lock(); pool = nil; poolLock.unlock()
        if p.isCancelled { return nil }
        // Attribute each hard-linked file to the first directory that saw it (reused directories keep theirs).
        for l in pendingLinks where counted.insert(l.id).inserted {
            tree.directAlloc[Int(l.dir)] += l.alloc
            tree.directLogical[Int(l.dir)] += l.logical
            tree.linkOwners[l.dir, default: []].append(l.id)
        }
        let snap = progress.snapshot
        tree.skippedDirs = snap.skipped
        tree.reusedDirs = snap.reused
        tree.finalize()
        tree.duration = monotonicSeconds() - started
        return tree
    }
}

/// A row for the storage browser: child directories come from the tree, files are listed on demand.
public struct DiskItem: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let treeIndex: Int32 // -1 for files
    public let alloc: Int64
    public let logical: Int64
    public let items: Int64
    public let modified: Date
    public let unreadable: Bool
    public let hardlinked: Bool
}

public enum DiskListing {
    public static func items(in tree: ScanTree, dir: Int32) -> [DiskItem] {
        var out: [DiskItem] = []
        let base = tree.path(of: dir)
        for c in tree.children(of: dir) {
            let i = Int(c)
            out.append(DiskItem(name: tree.names[i], path: PathUtil.join(base, tree.names[i]), isDirectory: true,
                                treeIndex: c, alloc: tree.totalAlloc[i], logical: tree.totalLogical[i],
                                items: tree.totalItems[i], modified: Date(timeIntervalSince1970: Double(tree.mtime[i])),
                                unreadable: tree.flags[i] & ScanTree.flagUnreadable != 0, hardlinked: false))
        }
        for e in BulkDir.list(base).entries where !e.isDirectory {
            out.append(DiskItem(name: e.name, path: PathUtil.join(base, e.name), isDirectory: false, treeIndex: -1,
                                alloc: e.allocSize, logical: e.logicalSize, items: 0,
                                modified: Date(timeIntervalSince1970: Double(e.mtime)), unreadable: false,
                                hardlinked: e.linkCount > 1))
        }
        return out.sorted { $0.alloc > $1.alloc }
    }
}

/// Binary on-disk cache of a ScanTree, keyed by root path.
public enum ScanCache {
    static let magic: UInt32 = 0x4D4C5343 // "MLSC"
    static let version: UInt32 = 2

    public static func url(for root: String) -> URL {
        AppPaths.cacheDir.appendingPathComponent("scan-\(fnv1a(root)).bin")
    }

    public static func save(_ t: ScanTree) throws {
        var d = Data()
        d.reserveCapacity(t.count * 48 + 256)
        func put<T: FixedWidthInteger>(_ v: T) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func putStr(_ s: String) { let u = Array(s.utf8); put(UInt32(u.count)); d.append(contentsOf: u) }
        put(magic); put(version)
        putStr(t.rootPath); putStr(t.volumeUUID ?? "")
        put(t.eventID); put(Int64(t.scanDate.timeIntervalSince1970)); put(Int64(t.skippedDirs))
        put(UInt32(t.count))
        for i in 0..<t.count {
            put(t.parent[i]); put(t.mtime[i]); put(t.directAlloc[i]); put(t.directLogical[i]); put(t.directFiles[i])
            put(t.flags[i] & ScanTree.flagUnreadable)
            let u = Array(t.names[i].utf8)
            put(UInt16(min(u.count, Int(UInt16.max)))); d.append(contentsOf: u.prefix(Int(UInt16.max)))
        }
        put(UInt32(t.linkOwners.count))
        for (dir, ids) in t.linkOwners { put(dir); put(UInt32(ids.count)); for id in ids { put(id) } }
        try d.write(to: url(for: t.rootPath), options: .atomic)
    }

    public static func load(root: String) -> ScanTree? {
        guard let d = try? Data(contentsOf: url(for: root), options: .alwaysMapped) else { return nil }
        return d.withUnsafeBytes { raw -> ScanTree? in
            var o = 0
            func get<T: FixedWidthInteger>(_: T.Type) -> T? {
                guard o + MemoryLayout<T>.size <= raw.count else { return nil }
                let v = T(littleEndian: raw.loadUnaligned(fromByteOffset: o, as: T.self)); o += MemoryLayout<T>.size; return v
            }
            func getBytes(_ n: Int) -> String? {
                guard o + n <= raw.count else { return nil }
                let s = String(decoding: raw[o..<(o + n)], as: UTF8.self); o += n; return s
            }
            guard get(UInt32.self) == magic, get(UInt32.self) == version,
                  let rl = get(UInt32.self), let rootPath = getBytes(Int(rl)), rootPath == root,
                  let ul = get(UInt32.self), let uuid = getBytes(Int(ul)),
                  let ev = get(UInt64.self), let date = get(Int64.self), let skipped = get(Int64.self),
                  let n = get(UInt32.self) else { return nil }
            let t = ScanTree(rootPath: rootPath)
            t.volumeUUID = uuid.isEmpty ? nil : uuid
            t.eventID = ev
            t.scanDate = Date(timeIntervalSince1970: Double(date))
            t.skippedDirs = Int(skipped)
            for _ in 0..<n {
                guard let p = get(Int32.self), let m = get(Int64.self), let a = get(Int64.self), let l = get(Int64.self),
                      let f = get(Int32.self), let fl = get(UInt8.self), let nl = get(UInt16.self), let name = getBytes(Int(nl)) else { return nil }
                let i = Int(t.append(name: name, parent: p, mtime: m))
                t.directAlloc[i] = a; t.directLogical[i] = l; t.directFiles[i] = f; t.flags[i] = fl
            }
            guard let nOwners = get(UInt32.self) else { return nil }
            for _ in 0..<nOwners {
                guard let dir = get(Int32.self), let c = get(UInt32.self) else { return nil }
                var ids: [UInt64] = []
                ids.reserveCapacity(Int(c))
                for _ in 0..<c { guard let id = get(UInt64.self) else { return nil }; ids.append(id) }
                t.linkOwners[dir] = ids
            }
            t.finalize()
            return t
        }
    }
}
