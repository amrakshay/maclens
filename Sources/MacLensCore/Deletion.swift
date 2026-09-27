import Foundation
import Darwin

public enum DeletionVerdict: Equatable, Sendable {
    case allowed
    case blocked(String)
    public var reason: String? { if case .blocked(let r) = self { return r }; return nil }
    public var isAllowed: Bool { self == .allowed }
}

/// The single source of truth for "may this path be deleted?". Enforced inside `Deleter`, not just in the UI.
public enum DeletionGuard {
    public static let protectedRoots = ["/System", "/usr", "/bin", "/sbin", "/Library", "/private", "/etc", "/var", "/tmp", "/cores", "/dev"]
    public static let exceptions = ["/usr/local"]

    public static let summary = """
    Deletion is blocked for: anything under /System, /usr (except /usr/local), /bin, /sbin, /Library, /private \
    (including /etc, /var, /tmp), SIP-protected or immutable items, mount points and volume roots, your home folder \
    itself, and anything not owned by you.
    """

    public static func check(_ path: String) -> DeletionVerdict {
        guard path.hasPrefix("/") else { return .blocked("Not an absolute path.") }
        var p = path
        while p.count > 1 && p.hasSuffix("/") { p.removeLast() }
        if p == "/" { return .blocked("The startup volume root can't be deleted.") }
        let comps = p.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
        if comps.contains(where: { $0 == "." || $0 == ".." || $0.isEmpty }) { return .blocked("Path contains '.' or '..' components.") }

        var st = stat()
        guard lstat(p, &st) == 0 else { return .blocked("Item no longer exists.") }

        // Canonical location: resolve the parent (so /tmp → /private/tmp) but not the item itself (a symlink is removed as a link).
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let parent = PathUtil.parent(p)
        guard realpath(parent, &buf) != nil else { return .blocked("Can't resolve the parent folder.") }
        var canonical = PathUtil.join(String(cString: buf), PathUtil.lastComponent(p))
        // The Data volume is firmlinked into /; judge it by its logical location.
        let data = "/System/Volumes/Data"
        if canonical.hasPrefix(data + "/") { canonical = String(canonical.dropFirst(data.count)) }

        if let root = protectedRoots.first(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }),
           !exceptions.contains(where: { canonical == $0 || canonical.hasPrefix($0 + "/") }) || canonical == "/usr/local" {
            return .blocked("\(root) is a protected system location.")
        }
        let home = PathUtil.home
        if canonical == home || ["/Users", "/Applications", "/Volumes", "/opt", "/Users/Shared"].contains(canonical) {
            return .blocked("\(canonical) is a top-level system or home folder.")
        }
        if canonical.hasPrefix("/Volumes/"), canonical.dropFirst("/Volumes/".count).contains("/") == false {
            return .blocked("Volume roots can't be deleted.")
        }
        if st.st_flags & UInt32(SF_RESTRICTED) != 0 || getxattr(p, "com.apple.rootless", nil, 0, 0, XATTR_NOFOLLOW) >= 0 {
            return .blocked("Protected by System Integrity Protection.")
        }
        if st.st_flags & UInt32(SF_IMMUTABLE | UF_IMMUTABLE | SF_NOUNLINK | UF_APPEND | SF_APPEND) != 0 {
            return .blocked("Item is locked/immutable.")
        }
        if st.st_uid != getuid() {
            return .blocked("Owned by \(UserNames.shared.name(st.st_uid)), not you.")
        }
        var pst = stat()
        if lstat(parent, &pst) == 0, pst.st_dev != st.st_dev {
            return .blocked("This is a mount point.")
        }
        return .allowed
    }
}

public enum DeleteMode: Sendable { case trash, permanent }

public struct DeleteOutcome: Sendable {
    public let path: String
    public let error: String?
}

public enum Deleter {
    /// Optional safety net for development/testing: when MACLENS_DELETE_SANDBOX is set, nothing outside it is deleted.
    static let sandbox: String? = ProcessInfo.processInfo.environment["MACLENS_DELETE_SANDBOX"]

    public static func delete(_ paths: [String], mode: DeleteMode) -> [DeleteOutcome] {
        paths.map { path in
            if let s = sandbox, !(path == s || path.hasPrefix(s + "/")) {
                return DeleteOutcome(path: path, error: "Outside MACLENS_DELETE_SANDBOX (\(s)).")
            }
            if case .blocked(let why) = DeletionGuard.check(path) { return DeleteOutcome(path: path, error: why) }
            do {
                let url = URL(fileURLWithPath: path)
                switch mode {
                case .trash: try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                case .permanent: try FileManager.default.removeItem(at: url)
                }
                return DeleteOutcome(path: path, error: nil)
            } catch {
                return DeleteOutcome(path: path, error: error.localizedDescription)
            }
        }
    }
}
