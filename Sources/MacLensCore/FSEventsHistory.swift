import Foundation
import CoreServices

/// Directories changed since an FSEvents event ID, replayed from the volume's persistent event history.
public struct FSChanges: Sendable {
    /// Directories whose direct contents changed.
    public var dirty = Set<String>()
    /// Directories whose whole subtree must be rescanned (coalesced events).
    public var subtrees = Set<String>()

    /// Every ancestor of a dirty path, for "did anything under X change?" checks.
    public func touchedAncestors() -> Set<String> {
        var s = Set<String>()
        for p in dirty.union(subtrees) {
            var cur = p
            while s.insert(cur).inserted, cur != "/" { cur = PathUtil.parent(cur) }
        }
        return s
    }

    public func anythingChanged(under path: String, touched: Set<String>) -> Bool {
        if touched.contains(path) { return true }
        // A coalesced subtree event on an ancestor also covers `path`.
        var cur = path
        while cur != "/" { cur = PathUtil.parent(cur); if subtrees.contains(cur) { return true } }
        return false
    }
}

public enum FSEventsHistory {
    public static func currentEventID() -> UInt64 { FSEventsGetCurrentEventId() }

    /// FSEvents history is per-volume; an event ID is only meaningful together with this UUID.
    public static func volumeUUID(for path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, let u = FSEventsCopyUUIDForDevice(st.st_dev) else { return nil }
        return CFUUIDCreateString(nil, u) as String
    }

    private final class Collector {
        let root: String
        var changes = FSChanges()
        var invalid = false
        var events = 0
        let done = DispatchSemaphore(value: 0)
        init(root: String) { self.root = root }
    }

    /// Returns nil when the history can't be trusted (dropped events, wrapped IDs, root moved, too many changes, timeout);
    /// callers then do a full scan.
    public static func changes(under root: String, since eventID: UInt64, timeout: Double = 20) -> FSChanges? {
        let collector = Collector(root: root)
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(collector).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            let c = Unmanaged<Collector>.fromOpaque(info!).takeUnretainedValue()
            let arr = unsafeBitCast(paths, to: NSArray.self)
            for i in 0..<count {
                let f = Int(flags[i])
                if f & kFSEventStreamEventFlagHistoryDone != 0 { c.done.signal(); continue }
                if f & (kFSEventStreamEventFlagUserDropped | kFSEventStreamEventFlagKernelDropped |
                        kFSEventStreamEventFlagEventIdsWrapped | kFSEventStreamEventFlagRootChanged) != 0 {
                    c.invalid = true; continue
                }
                guard var p = arr[i] as? String else { continue }
                while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
                // Paths may be reported via the Data volume; map them back onto the firmlinked path.
                let data = "/System/Volumes/Data"
                if p.hasPrefix(data + "/"), !c.root.hasPrefix(data) { p = String(p.dropFirst(data.count)) }
                if f & kFSEventStreamEventFlagMustScanSubDirs != 0 { c.changes.subtrees.insert(p) } else { c.changes.dirty.insert(p) }
                c.events += 1
                if c.events > 300_000 { c.invalid = true }
            }
        }
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, callback, &ctx, [root] as CFArray,
                                               FSEventStreamEventId(eventID), 0, flags) else { return nil }
        let q = DispatchQueue(label: "maclens.fsevents")
        FSEventStreamSetDispatchQueue(stream, q)
        guard FSEventStreamStart(stream) else { FSEventStreamInvalidate(stream); FSEventStreamRelease(stream); return nil }
        let finished = collector.done.wait(timeout: .now() + timeout) == .success
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        return q.sync { (finished && !collector.invalid) ? collector.changes : nil }
    }
}
