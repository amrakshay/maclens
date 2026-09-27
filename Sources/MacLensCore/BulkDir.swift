import Foundation
import Darwin

/// One directory entry as returned by getattrlistbulk(2).
public struct BulkEntry {
    public var name = ""
    public var objType: UInt32 = 0
    public var devID: Int32 = 0
    public var mtime: Int64 = 0
    public var fileID: UInt64 = 0
    public var linkCount: UInt32 = 1
    public var logicalSize: Int64 = 0
    public var allocSize: Int64 = 0
    /// Bytes freed if this file were deleted (excludes blocks shared with clones/snapshots). -1 = not requested.
    public var privateSize: Int64 = -1
    public var isMountPoint = false
    public var isDirectory: Bool { objType == 2 } // VDIR
    public var isSymlink: Bool { objType == 5 }   // VLNK
}

/// Fast directory enumeration: one syscall returns names, types, sizes and ids for a batch of entries,
/// with no per-file stat(). Symlinks are reported as themselves (never followed).
public enum BulkDir {
    static let cmnName: UInt32 = 0x0000_0001
    static let cmnDevID: UInt32 = 0x0000_0002
    static let cmnObjType: UInt32 = 0x0000_0008
    static let cmnModTime: UInt32 = 0x0000_0400
    static let cmnFileID: UInt32 = 0x0200_0000
    static let cmnError: UInt32 = 0x2000_0000
    static let cmnReturnedAttrs: UInt32 = 0x8000_0000
    static let dirMountStatus: UInt32 = 0x0000_0004
    static let fileLinkCount: UInt32 = 0x0000_0001
    static let fileTotalSize: UInt32 = 0x0000_0002
    static let fileAllocSize: UInt32 = 0x0000_0004
    static let cmnextPrivateSize: UInt32 = 0x0000_0008
    static let optAttrCmnExtended: UInt64 = 0x0000_0020
    static let mntStatusMountPoint: UInt32 = 0x0000_0001

    public static let bufferSize = 256 * 1024

    public static func allocateBuffer() -> UnsafeMutableRawPointer {
        UnsafeMutableRawPointer.allocate(byteCount: bufferSize, alignment: 16)
    }

    /// Opens a directory without following a final symlink.
    public static func open(_ path: String) -> Int32 {
        Darwin.open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    }

    /// Enumerates `fd`. Returns 0 on success or an errno.
    @discardableResult
    public static func forEach(fd: Int32, buffer: UnsafeMutableRawPointer, privateSize: Bool = false,
                               _ body: (inout BulkEntry) -> Void) -> Int32 {
        var al = attrlist()
        al.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        al.commonattr = cmnReturnedAttrs | cmnName | cmnDevID | cmnObjType | cmnModTime | cmnFileID | cmnError
        al.dirattr = dirMountStatus
        al.fileattr = fileLinkCount | fileTotalSize | fileAllocSize
        al.forkattr = privateSize ? cmnextPrivateSize : 0
        let options: UInt64 = privateSize ? optAttrCmnExtended : 0

        while true {
            let n = withUnsafeMutablePointer(to: &al) { getattrlistbulk(fd, $0, buffer, bufferSize, options) }
            if n < 0 { return errno }
            if n == 0 { return 0 }
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<n {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                var p = entry + 4
                let rCommon = p.loadUnaligned(as: UInt32.self)
                let rDir = (p + 8).loadUnaligned(as: UInt32.self)
                let rFile = (p + 12).loadUnaligned(as: UInt32.self)
                let rFork = (p + 16).loadUnaligned(as: UInt32.self)
                p += 20
                var e = BulkEntry()
                var err: UInt32 = 0
                if rCommon & cmnName != 0 {
                    let off = Int(p.loadUnaligned(as: Int32.self))
                    e.name = String(cString: (p + off).assumingMemoryBound(to: CChar.self))
                    p += 8
                }
                if rCommon & cmnDevID != 0 { e.devID = p.loadUnaligned(as: Int32.self); p += 4 }
                if rCommon & cmnObjType != 0 { e.objType = p.loadUnaligned(as: UInt32.self); p += 4 }
                if rCommon & cmnModTime != 0 { e.mtime = p.loadUnaligned(as: Int64.self); p += 16 }
                if rCommon & cmnFileID != 0 { e.fileID = p.loadUnaligned(as: UInt64.self); p += 8 }
                if rCommon & cmnError != 0 { err = p.loadUnaligned(as: UInt32.self); p += 4 }
                if rDir & dirMountStatus != 0 {
                    e.isMountPoint = p.loadUnaligned(as: UInt32.self) & mntStatusMountPoint != 0
                    p += 4
                }
                if rFile & fileLinkCount != 0 { e.linkCount = p.loadUnaligned(as: UInt32.self); p += 4 }
                if rFile & fileTotalSize != 0 { e.logicalSize = p.loadUnaligned(as: Int64.self); p += 8 }
                if rFile & fileAllocSize != 0 { e.allocSize = p.loadUnaligned(as: Int64.self); p += 8 }
                if rFork & cmnextPrivateSize != 0 { e.privateSize = p.loadUnaligned(as: Int64.self); p += 8 }
                if err == 0 && !e.name.isEmpty { body(&e) }
                entry += length
            }
        }
    }

    /// Convenience: all entries of a path.
    public static func list(_ path: String, privateSize: Bool = false) -> (entries: [BulkEntry], errno: Int32) {
        let fd = open(path)
        guard fd >= 0 else { return ([], errno) }
        defer { close(fd) }
        let buf = allocateBuffer()
        defer { buf.deallocate() }
        var out: [BulkEntry] = []
        let r = forEach(fd: fd, buffer: buf, privateSize: privateSize) { out.append($0) }
        return (out, r)
    }
}

/// A LIFO work pool (depth-first keeps the frontier small) over a fixed number of threads.
public final class WorkPool<Item> {
    private var stack: [Item]
    private var active = 0
    private var cancelled = false
    private let cond = NSCondition()

    public init(_ initial: [Item]) { stack = initial }

    public var isCancelled: Bool { cond.lock(); defer { cond.unlock() }; return cancelled }

    public func cancel() { cond.lock(); cancelled = true; cond.broadcast(); cond.unlock() }

    public func push(_ items: [Item]) {
        guard !items.isEmpty else { return }
        cond.lock(); stack.append(contentsOf: items); cond.broadcast(); cond.unlock()
    }

    /// Blocks until all work is done or cancelled. `work` gets a per-thread scratch buffer.
    public func run(threads: Int, _ work: @escaping (Item, UnsafeMutableRawPointer) -> Void) {
        let group = DispatchGroup()
        for _ in 0..<max(1, threads) {
            group.enter()
            Thread.detachNewThread { [self] in
                let buf = BulkDir.allocateBuffer()
                defer { buf.deallocate(); group.leave() }
                while true {
                    cond.lock()
                    while stack.isEmpty && active > 0 && !cancelled { cond.wait() }
                    if cancelled || stack.isEmpty { cond.broadcast(); cond.unlock(); return }
                    let item = stack.removeLast()
                    active += 1
                    cond.unlock()
                    autoreleasepool { work(item, buf) }
                    cond.lock()
                    active -= 1
                    if stack.isEmpty && active == 0 { cond.broadcast() }
                    cond.unlock()
                }
            }
        }
        group.wait()
    }
}

