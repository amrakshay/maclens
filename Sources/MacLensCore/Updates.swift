import Foundation
import CryptoKit

/// Semantic version (MAJOR.MINOR.PATCH[-prerelease]); a prerelease sorts before its release.
public struct SemVer: Comparable, CustomStringConvertible, Sendable {
    public let major: Int, minor: Int, patch: Int
    public let prerelease: String?

    public init?(_ s: String) {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("v") || t.hasPrefix("V") { t.removeFirst() }
        let parts = t.split(separator: "-", maxSplits: 1)
        let nums = parts[0].split(separator: ".").map { Int($0) }
        guard (1...3).contains(nums.count), nums.allSatisfy({ $0 != nil }) else { return nil }
        major = nums[0]!
        minor = nums.count > 1 ? nums[1]! : 0
        patch = nums.count > 2 ? nums[2]! : 0
        prerelease = parts.count > 1 ? String(parts[1]) : nil
    }

    public var description: String { "\(major).\(minor).\(patch)" + (prerelease.map { "-\($0)" } ?? "") }

    public static func < (a: SemVer, b: SemVer) -> Bool {
        if (a.major, a.minor, a.patch) != (b.major, b.minor, b.patch) { return (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
        switch (a.prerelease, b.prerelease) {
        case (nil, nil), (nil, _): return false
        case (_, nil): return true
        case let (x?, y?): return x < y
        }
    }
}

/// A published MacLens release, as needed for update checks.
public struct ReleaseInfo: Sendable, Equatable {
    public let version: SemVer
    public let tag: String
    public let notes: String          // release notes (Markdown) = the changelog section
    public let publishedAt: Date?
    public let pageURL: URL
    public let zipURL: URL
    public let sha256URL: URL

    public init(version: SemVer, tag: String, notes: String, publishedAt: Date?, pageURL: URL, zipURL: URL, sha256URL: URL) {
        self.version = version; self.tag = tag; self.notes = notes; self.publishedAt = publishedAt
        self.pageURL = pageURL; self.zipURL = zipURL; self.sha256URL = sha256URL
    }

    public static func == (a: ReleaseInfo, b: ReleaseInfo) -> Bool { a.tag == b.tag }
}

public enum UpdateError: LocalizedError {
    case badResponse(String), noAsset, checksumMismatch, invalidBundle(String), notNewer, install(String)
    public var errorDescription: String? {
        switch self {
        case .badResponse(let s): return "Couldn't read the latest release: \(s)"
        case .noAsset: return "The release has no MacLens zip attached."
        case .checksumMismatch: return "The download's SHA-256 doesn't match the published checksum; nothing was changed."
        case .invalidBundle(let s): return "The downloaded app failed verification (\(s)); nothing was changed."
        case .notNewer: return "The downloaded app isn't newer than the running one."
        case .install(let s): return s
        }
    }
}

/// Checks GitHub Releases for a newer MacLens and installs it. No third-party frameworks (no Sparkle).
public enum Updater {
    public static let repo = "amrakshay/maclens"
    public static let bundleID = "dev.maclens.MacLens"
    static let downloadPrefix = "https://github.com/\(repo)/releases/download/"

    // MARK: Checking

    /// Parses the GitHub `releases/latest` response. Assets must come from this repo's release downloads.
    public static func parseRelease(_ data: Data) throws -> ReleaseInfo {
        guard let j = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw UpdateError.badResponse("not JSON") }
        if let msg = j["message"] as? String, j["tag_name"] == nil { throw UpdateError.badResponse(msg) }
        guard let tag = j["tag_name"] as? String, let v = SemVer(tag) else { throw UpdateError.badResponse("missing or invalid tag") }
        if (j["draft"] as? Bool) == true || (j["prerelease"] as? Bool) == true { throw UpdateError.badResponse("latest is a draft/prerelease") }
        let assets = (j["assets"] as? [[String: Any]]) ?? []
        func asset(_ name: String) -> URL? {
            guard let a = assets.first(where: { ($0["name"] as? String) == name }),
                  let s = a["browser_download_url"] as? String, s.hasPrefix(downloadPrefix) else { return nil }
            return URL(string: s)
        }
        let base = "MacLens-\(v.major).\(v.minor).\(v.patch)\(v.prerelease.map { "-\($0)" } ?? "").zip"
        guard let zip = asset(base), let sha = asset(base + ".sha256"),
              let page = URL(string: (j["html_url"] as? String) ?? "https://github.com/\(repo)/releases/tag/\(tag)") else { throw UpdateError.noAsset }
        let date = (j["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(version: v, tag: tag, notes: (j["body"] as? String) ?? "", publishedAt: date,
                           pageURL: page, zipURL: zip, sha256URL: sha)
    }

    /// Fetches the latest published release (one unauthenticated request).
    public static func fetchLatest(currentVersion: String) async throws -> ReleaseInfo {
        var req = URLRequest(url: URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacLens/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode != 200 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw UpdateError.badResponse("HTTP \(h.statusCode)\(msg.map { ": \($0)" } ?? "")")
        }
        return try parseRelease(data)
    }

    // MARK: Install kind

    public enum InstallKind: Equatable, Sendable {
        /// Installed with `brew install --cask`; update via `brew upgrade --cask maclens`.
        case homebrew(brew: String)
        /// A downloaded .app in a folder we can write to; update by swapping the bundle.
        case direct
        /// Running from a build folder or read-only location; point the user at the release page instead.
        case unsupported(String)
    }

    public static func installKind(bundlePath: String,
                                   caskrooms: [String] = ["/opt/homebrew/Caskroom/maclens", "/usr/local/Caskroom/maclens"],
                                   brews: [String] = ["/opt/homebrew/bin/brew", "/usr/local/bin/brew"]) -> InstallKind {
        guard bundlePath.hasSuffix(".app") else { return .unsupported("not running from an app bundle (development build)") }
        if bundlePath.contains("/.build/") || bundlePath.contains("/dist/") || bundlePath.contains("/DerivedData/") {
            return .unsupported("this is a development build")
        }
        let fm = FileManager.default
        if caskrooms.contains(where: { fm.fileExists(atPath: $0) }), let brew = brews.first(where: { fm.isExecutableFile(atPath: $0) }) {
            return .homebrew(brew: brew)
        }
        guard fm.isWritableFile(atPath: PathUtil.parent(bundlePath)) else {
            return .unsupported("the app's folder isn't writable")
        }
        return .direct
    }

    // MARK: Verification helpers

    public static func sha256Hex(of url: URL) throws -> String {
        let h = SHA256.hash(data: try Data(contentsOf: url, options: .alwaysMapped))
        return h.map { String(format: "%02x", $0) }.joined()
    }

    /// "<hex>  filename" → hex
    public static func parseChecksumFile(_ text: String) -> String? {
        let hex = text.split(whereSeparator: \.isWhitespace).first.map(String.init)?.lowercased()
        guard let hex, hex.count == 64, hex.allSatisfy(\.isHexDigit) else { return nil }
        return hex
    }

    /// Verifies an unpacked app: valid code signature, our bundle id, and a version newer than `current`.
    public static func verifyBundle(_ app: URL, newerThan current: SemVer) throws -> SemVer {
        guard let plist = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) else {
            throw UpdateError.invalidBundle("no Info.plist")
        }
        guard (plist["CFBundleIdentifier"] as? String) == bundleID else { throw UpdateError.invalidBundle("unexpected bundle identifier") }
        guard let vs = plist["CFBundleShortVersionString"] as? String, let v = SemVer(vs) else { throw UpdateError.invalidBundle("no version") }
        guard v > current else { throw UpdateError.notNewer }
        let out = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        guard out.status == 0 else { throw UpdateError.invalidBundle("code signature: \(out.output.trimmingCharacters(in: .whitespacesAndNewlines))") }
        return v
    }

    // MARK: Quarantine

    static let quarantineAttr = "com.apple.quarantine"

    /// True if the item itself carries macOS's download-quarantine flag (what triggers the Gatekeeper prompt).
    public static func isQuarantined(_ url: URL) -> Bool {
        getxattr(url.path, quarantineAttr, nil, 0, 0, XATTR_NOFOLLOW) >= 0
    }

    /// Removes the quarantine flag from a bundle and everything inside it (never following symlinks).
    /// Only call this on a bundle that has just passed `verifyBundle`. Returns how many items were cleared.
    @discardableResult
    public static func clearQuarantine(_ app: URL) -> Int {
        var cleared = 0
        func clear(_ path: String) { if removexattr(path, quarantineAttr, XATTR_NOFOLLOW) == 0 { cleared += 1 } }
        clear(app.path)
        if let e = FileManager.default.enumerator(atPath: app.path) {
            for case let rel as String in e { clear(PathUtil.join(app.path, rel)) }
        }
        return cleared
    }

    /// Verifies the bundle and, only if verification passes, clears its quarantine flag. Throws (and leaves
    /// the flag alone) if the bundle fails any check.
    @discardableResult
    public static func verifyAndClearQuarantine(_ app: URL, newerThan current: SemVer) throws -> SemVer {
        let v = try verifyBundle(app, newerThan: current)
        clearQuarantine(app)
        return v
    }

    // MARK: Installing

    /// Direct install: download zip + checksum, verify, unpack, verify the app, then swap it in for `current`.
    /// The old bundle goes to the Trash (recoverable) and is restored if the swap fails.
    /// `clearQuarantine`: remove macOS's quarantine flag from the verified new bundle so it relaunches
    /// without the Gatekeeper "could not verify" prompt (#11).
    public static func installDirect(_ release: ReleaseInfo, replacing current: URL, currentVersion: SemVer,
                                     clearQuarantine clearFlag: Bool = true,
                                     progress: @escaping @Sendable (String) -> Void) async throws {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("maclens-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) } // our own temp dir only

        progress("Downloading \(release.tag)…")
        let (zipTmp, _) = try await URLSession.shared.download(from: release.zipURL)
        let zip = work.appendingPathComponent(release.zipURL.lastPathComponent)
        try FileManager.default.moveItem(at: zipTmp, to: zip)
        let (shaData, _) = try await URLSession.shared.data(from: release.sha256URL)
        guard let expected = parseChecksumFile(String(decoding: shaData, as: UTF8.self)) else { throw UpdateError.checksumMismatch }

        progress("Verifying checksum…")
        guard try sha256Hex(of: zip) == expected else { throw UpdateError.checksumMismatch }

        progress("Unpacking…")
        let unpack = work.appendingPathComponent("unpacked")
        let u = run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path])
        guard u.status == 0 else { throw UpdateError.install("Couldn't unpack the update: \(u.output)") }
        let newApp = unpack.appendingPathComponent("MacLens.app")

        progress("Verifying the new app…")
        _ = try verifyBundle(newApp, newerThan: currentVersion)
        if clearFlag { clearQuarantine(newApp) } // verified above; the swap moves this exact bundle into place

        progress("Installing…")
        var trashed: NSURL?
        try FileManager.default.trashItem(at: current, resultingItemURL: &trashed)
        do {
            try FileManager.default.moveItem(at: newApp, to: current)
        } catch {
            if let t = trashed as URL? { try? FileManager.default.moveItem(at: t, to: current) } // roll back
            throw UpdateError.install("Couldn't move the new version into place: \(error.localizedDescription)")
        }
    }

    /// Homebrew install: `brew upgrade --cask maclens` (brew refreshes its taps first). Afterwards the installed
    /// app is verified like a direct download; only then is Homebrew's quarantine flag cleared (#11).
    public static func installHomebrew(brew: String, appPath: String, currentVersion: SemVer, clearQuarantine clearFlag: Bool = true,
                                       progress: @escaping @Sendable (String) -> Void) async throws {
        progress("Running brew upgrade --cask maclens…")
        let out = await Task.detached { run(brew, ["upgrade", "--cask", "maclens"], env: ["HOMEBREW_NO_ENV_HINTS": "1"]) }.value
        guard out.status == 0 else {
            throw UpdateError.install("brew upgrade failed:\n" + out.output.suffix(800))
        }
        progress("Verifying the upgraded app…")
        let app = URL(fileURLWithPath: appPath)
        do {
            _ = try verifyBundle(app, newerThan: currentVersion)
        } catch UpdateError.notNewer {
            throw UpdateError.install("brew finished but the installed app isn't newer yet. Homebrew may not have seen the new cask; try `brew update` and update again.")
        }
        if clearFlag { clearQuarantine(app) }
    }

    /// Relaunches the app at `path` after this process exits.
    public static func relaunch(appPath: String) {
        let script = "while /bin/kill -0 \(getpid()) 2>/dev/null; do /bin/sleep 0.3; done; /usr/bin/open \"$0\""
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script, appPath]
        try? p.run() // detached helper; it outlives us and reopens the app
    }

    @discardableResult
    static func run(_ path: String, _ args: [String], env: [String: String] = [:]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        var e = ProcessInfo.processInfo.environment
        e["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        for (k, v) in env { e[k] = v }
        p.environment = e
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
