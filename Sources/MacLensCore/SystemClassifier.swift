import Foundation
import Security

/// Decides whether a process counts as "system" for the hide-system toggle.
public final class SystemClassifier: @unchecked Sendable {
    public static let definition = """
    A process is "system" if any of these is true:
    • It runs as root, as a user ID below 500, or as a user whose name starts with "_" (e.g. _windowserver).
    • Its executable is under /System, /usr/libexec, /usr/sbin, /sbin or /Library/Apple.
    • It is an Apple-signed daemon: code signature satisfies "anchor apple", it was started by launchd, and it is not an app in /Applications.
    Shells and tools in /bin and /usr/bin are not treated as system — you usually started them.
    Ports owned by system processes are hidden together with the process.
    """

    static let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"]

    private var appleSigned: [String: Bool] = [:]
    private var pending = Set<String>()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "maclens.codesign", qos: .utility)

    public init() {}

    /// Returns the reasons a process is system; empty means not system.
    /// The Apple-signature check runs asynchronously and is cached per path.
    public func classify(uid: uid_t, user: String, path: String, ppid: Int32) -> [String] {
        var reasons: [String] = []
        if uid == 0 {
            reasons.append("runs as root")
        } else if uid < 500 || user.hasPrefix("_") {
            reasons.append("runs as system user \(user) (uid \(uid))")
        }
        if let p = Self.systemPrefixes.first(where: { path.hasPrefix($0) }) {
            reasons.append("executable in \(p.dropLast())")
        }
        if reasons.isEmpty, ppid == 1, !path.isEmpty, !Self.isApplicationBundle(path) {
            if isAppleSigned(path) { reasons.append("Apple-signed daemon/agent") }
        }
        return reasons
    }

    static func isApplicationBundle(_ path: String) -> Bool {
        (path.hasPrefix("/Applications/") || path.hasPrefix(PathUtil.home + "/Applications/")) && path.contains(".app/")
    }

    private func isAppleSigned(_ path: String) -> Bool {
        lock.lock()
        if let v = appleSigned[path] { lock.unlock(); return v }
        let schedule = pending.insert(path).inserted
        lock.unlock()
        if schedule {
            queue.async { [weak self] in
                let v = Self.checkAppleSignature(path)
                guard let self else { return }
                self.lock.lock(); self.appleSigned[path] = v; self.pending.remove(path); self.lock.unlock()
            }
        }
        return false
    }

    public static func checkAppleSignature(_ path: String) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess, let code else { return false }
        var req: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req else { return false }
        // Signature/requirement check only; skip hashing the whole executable and resources.
        let flags = SecCSFlags(rawValue: kSecCSDoNotValidateExecutable | kSecCSDoNotValidateResources)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
    }
}
