import Foundation
import Darwin

public enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case nodeModules, pythonVenv, condaEnv, mavenTarget, gradleBuild, rustTarget
    case mavenRepository, gradleCache, xcodeDerivedData, npmCache, pipCache, homebrewCache

    public var displayName: String {
        switch self {
        case .nodeModules: return "node_modules"
        case .pythonVenv: return "Python venv"
        case .condaEnv: return "Conda env"
        case .mavenTarget: return "Maven target/"
        case .gradleBuild: return "Gradle build/"
        case .rustTarget: return "Rust target/"
        case .mavenRepository: return "~/.m2 repository"
        case .gradleCache: return "Gradle cache"
        case .xcodeDerivedData: return "Xcode DerivedData"
        case .npmCache: return "npm cache"
        case .pipCache: return "pip cache"
        case .homebrewCache: return "Homebrew cache"
        }
    }

    public var detectionRule: String {
        switch self {
        case .nodeModules: return "node_modules/ next to a package.json"
        case .pythonVenv: return "a folder containing pyvenv.cfg (any name)"
        case .condaEnv: return "a folder containing conda-meta/ (base installs are excluded)"
        case .mavenTarget: return "target/ next to a pom.xml"
        case .gradleBuild: return "build/ next to build.gradle(.kts) or settings.gradle(.kts)"
        case .rustTarget: return "target/ next to a Cargo.toml"
        case .mavenRepository: return "~/.m2/repository"
        case .gradleCache: return "~/.gradle/caches and ~/.gradle/wrapper/dists"
        case .xcodeDerivedData: return "~/Library/Developer/Xcode/DerivedData/*"
        case .npmCache: return "~/.npm/_cacache"
        case .pipCache: return "~/Library/Caches/pip"
        case .homebrewCache: return "~/Library/Caches/Homebrew"
        }
    }

    /// Shared caches: deleting them forces a re-download on the next build.
    public var isGlobalCache: Bool {
        switch self {
        case .mavenRepository, .gradleCache, .npmCache, .pipCache, .homebrewCache: return true
        default: return false
        }
    }

    public var redownloadWarning: String? {
        switch self {
        case .mavenRepository: return "Maven will re-download every dependency on the next build of every project."
        case .gradleCache: return "Gradle will re-download dependencies and wrapper distributions on the next build."
        case .npmCache: return "npm will re-download packages instead of using its local cache."
        case .pipCache: return "pip will re-download wheels on the next install."
        case .homebrewCache: return "Homebrew will re-download bottles when reinstalling or upgrading."
        case .xcodeDerivedData: return "Xcode will re-index and rebuild the project from scratch."
        case .nodeModules: return nil
        case .pythonVenv, .condaEnv: return "Packages must be reinstalled (e.g. pip install -r requirements.txt) to use this environment again."
        default: return nil
        }
    }
}

public struct Artifact: Codable, Identifiable, Hashable, Sendable {
    public var id: String { path }
    public var kind: ArtifactKind
    public var path: String
    public var projectPath: String?
    public var projectName: String
    public var allocSize: Int64 = 0
    public var logicalSize: Int64 = 0
    /// Estimated bytes freed on deletion: private (unshared) size of files with a single link.
    public var reclaimable: Int64 = 0
    public var itemCount: Int64 = 0
    public var newestInside: Date?
    public var projectActivity: Date?
    public var gitActivity: Date?
    public var lastActivity: Date?
    public var lastActivitySource = ""

    public var daysSinceActivity: Int? {
        lastActivity.map { Int(Date().timeIntervalSince($0) / 86400) }
    }
}

public struct ArtifactScanResult: Codable, Sendable {
    public var roots: [String]
    public var artifacts: [Artifact]
    public var eventID: UInt64
    public var volumeUUID: String?
    public var date: Date
    public var duration: Double = 0
    public var reusedSizes = 0
}

/// Finds developer build artifacts by marker files, sizes them, and dates their last activity.
public final class ArtifactScanner: @unchecked Sendable {
    public let progress = ScanProgress()
    private var pools: [AnyObject] = []
    private let lock = NSLock()
    private var cancelled = false

    public init() {}

    public func cancel() {
        lock.lock(); cancelled = true
        for p in pools { (p as? WorkPool<DiscoverItem>)?.cancel(); (p as? WorkPool<SizeItem>)?.cancel() }
        lock.unlock()
    }
    private var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    struct DiscoverItem { let path: String; let depth: Int }
    struct SizeItem { let artifact: Int; let path: String }

    /// Folder names never descended into while searching for projects.
    static let skipNames: Set<String> = [".git", ".hg", ".svn", ".Trash", "__pycache__", ".idea", ".vscode", ".cache", ".DS_Store"]
    /// Skipped only directly under the home folder (global caches are handled separately).
    static let skipAtHome: Set<String> = ["Library", ".m2", ".gradle", ".npm", ".cargo", ".rustup", ".Trash", "Pictures", "Music", "Movies"]
    static let packageSuffixes = [".app", ".photoslibrary", ".musiclibrary", ".framework", ".bundle", ".xcarchive", ".tvlibrary"]
    static let gradleMarkers = ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
    static let artifactDirNames: Set<String> = ["node_modules", "target", "build", ".venv", "venv", ".gradle", "__pycache__"]

    public static func cacheURL() -> URL { AppPaths.cacheDir.appendingPathComponent("artifacts.json") }

    public static func loadCache() -> ArtifactScanResult? {
        guard let d = try? Data(contentsOf: cacheURL()) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(ArtifactScanResult.self, from: d)
    }

    public static func saveCache(_ r: ArtifactScanResult) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        if let d = try? enc.encode(r) { try? d.write(to: cacheURL(), options: .atomic) }
    }

    public func scan(roots: [String], home: String = PathUtil.home, previous: ArtifactScanResult?, threads: Int = 6) -> ArtifactScanResult? {
        let started = monotonicSeconds()
        lock.lock(); cancelled = false; pools = []; lock.unlock()
        progress.reset()
        let startEvent = FSEventsHistory.currentEventID()
        let uuid = FSEventsHistory.volumeUUID(for: home)

        // 1. Discover by markers.
        var found: [Artifact] = []
        let foundLock = NSLock()
        func emit(_ a: Artifact) { foundLock.lock(); found.append(a); foundLock.unlock() }

        let discover = WorkPool<DiscoverItem>(roots.map { DiscoverItem(path: $0, depth: 0) })
        lock.lock(); pools.append(discover); lock.unlock()
        discover.run(threads: threads) { [progress] item, buf in
            let fd = BulkDir.open(item.path)
            guard fd >= 0 else { progress.add(dirs: 1, skipped: 1); return }
            var files = Set<String>()
            var dirs: [String] = []
            BulkDir.forEach(fd: fd, buffer: buf) { e in
                if e.isDirectory { if !e.isMountPoint { dirs.append(e.name) } } else { files.insert(e.name) }
            }
            close(fd)
            progress.add(dirs: 1, files: files.count, current: item.path)
            let dirSet = Set(dirs)

            if files.contains("pyvenv.cfg") {
                emit(Self.projectArtifact(.pythonVenv, item.path, project: PathUtil.parent(item.path)))
                return
            }
            if dirSet.contains("conda-meta") {
                if dirSet.contains("envs") && (dirSet.contains("pkgs") || dirSet.contains("condabin")) {
                    discover.push([DiscoverItem(path: PathUtil.join(item.path, "envs"), depth: item.depth + 1)]) // base install: only its envs
                } else {
                    emit(Artifact(kind: .condaEnv, path: item.path, projectPath: nil, projectName: "conda: " + PathUtil.lastComponent(item.path)))
                }
                return
            }
            var next: [DiscoverItem] = []
            for name in dirs {
                let child = PathUtil.join(item.path, name)
                switch name {
                case "node_modules":
                    if files.contains("package.json") { emit(Self.projectArtifact(.nodeModules, child, project: item.path)) }
                    continue // never search inside node_modules
                case "target" where files.contains("pom.xml"):
                    emit(Self.projectArtifact(.mavenTarget, child, project: item.path)); continue
                case "target" where files.contains("Cargo.toml"):
                    emit(Self.projectArtifact(.rustTarget, child, project: item.path)); continue
                case "build" where Self.gradleMarkers.contains(where: files.contains):
                    emit(Self.projectArtifact(.gradleBuild, child, project: item.path)); continue
                default: break
                }
                if Self.skipNames.contains(name) { continue }
                if item.path == home && Self.skipAtHome.contains(name) { continue }
                if Self.packageSuffixes.contains(where: name.hasSuffix) { continue }
                if item.depth < 16 { next.append(DiscoverItem(path: child, depth: item.depth + 1)) }
            }
            discover.push(next)
        }
        if isCancelled { return nil }

        // 2. Global caches and well-known locations.
        found += Self.globalArtifacts(home: home)

        // Dedupe and drop artifacts nested inside another artifact.
        var byPath: [String: Artifact] = [:]
        for a in found where byPath[a.path] == nil { byPath[a.path] = a }
        var keptPaths = Set<String>()
        var kept: [Artifact] = []
        for p in byPath.keys.sorted(by: { $0.count < $1.count }) {
            var anc = PathUtil.parent(p), nested = false
            while anc != "/" && !nested { nested = keptPaths.contains(anc); anc = PathUtil.parent(anc) }
            if nested { continue }
            keptPaths.insert(p); kept.append(byPath[p]!)
        }
        found = kept

        // 3. Size them, reusing previous sizes for artifacts FSEvents says are unchanged.
        var reusable: [String: Artifact] = [:]
        if let prev = previous, prev.volumeUUID == uuid, prev.eventID > 0,
           let changes = FSEventsHistory.changes(under: home, since: prev.eventID) {
            let touched = changes.touchedAncestors()
            for a in prev.artifacts where !changes.anythingChanged(under: a.path, touched: touched) { reusable[a.path] = a }
        }
        var toSize: [SizeItem] = []
        var reused = 0
        for i in found.indices {
            if let old = reusable[found[i].path], old.kind == found[i].kind {
                found[i].allocSize = old.allocSize; found[i].logicalSize = old.logicalSize
                found[i].reclaimable = old.reclaimable; found[i].itemCount = old.itemCount
                found[i].newestInside = old.newestInside
                reused += 1
            } else {
                toSize.append(SizeItem(artifact: i, path: found[i].path))
            }
        }
        var alloc = [Int64](repeating: 0, count: found.count), logical = alloc, reclaim = alloc, items = alloc
        var newest = [Int64](repeating: 0, count: found.count)
        var hardlinks = Set<UInt64>()
        let accLock = NSLock()
        let sizer = WorkPool<SizeItem>(toSize)
        lock.lock(); pools.append(sizer); lock.unlock()
        sizer.run(threads: threads) { [progress] item, buf in
            let fd = BulkDir.open(item.path)
            guard fd >= 0 else { return }
            var st = stat(); fstat(fd, &st)
            var a: Int64 = 0, l: Int64 = 0, r: Int64 = 0, n: Int64 = 0, newestM = Int64(st.st_mtimespec.tv_sec)
            var subs: [SizeItem] = []
            var links: [UInt64] = []
            var linkSizes: [(Int64, Int64)] = []
            BulkDir.forEach(fd: fd, buffer: buf, privateSize: true) { e in
                guard e.devID == st.st_dev else { return }
                n += 1
                newestM = max(newestM, e.mtime)
                if e.isDirectory {
                    if !e.isMountPoint { subs.append(SizeItem(artifact: item.artifact, path: PathUtil.join(item.path, e.name))) }
                    return
                }
                if e.linkCount > 1 {
                    links.append(e.fileID); linkSizes.append((e.allocSize, e.logicalSize)) // shared: counted once, never "reclaimable"
                    return
                }
                a += e.allocSize; l += e.logicalSize
                r += e.privateSize >= 0 ? e.privateSize : e.allocSize
            }
            close(fd)
            accLock.lock()
            for (k, id) in links.enumerated() where hardlinks.insert(id).inserted { a += linkSizes[k].0; l += linkSizes[k].1 }
            alloc[item.artifact] += a; logical[item.artifact] += l; reclaim[item.artifact] += r; items[item.artifact] += n
            newest[item.artifact] = max(newest[item.artifact], newestM)
            accLock.unlock()
            progress.add(dirs: 1, files: Int(n), bytes: a, current: item.path)
            sizer.push(subs)
        }
        if isCancelled { return nil }
        for s in toSize where s.artifact < found.count {
            let i = s.artifact
            found[i].allocSize = alloc[i]; found[i].logicalSize = logical[i]
            found[i].reclaimable = reclaim[i]; found[i].itemCount = items[i]
            found[i].newestInside = newest[i] > 0 ? Date(timeIntervalSince1970: Double(newest[i])) : nil
        }

        // 4. Last activity.
        let artifactPaths = Set(found.map(\.path))
        DispatchQueue.concurrentPerform(iterations: found.count) { i in
            accLock.lock(); var a = found[i]; accLock.unlock()
            if let proj = a.projectPath {
                let pa = Self.projectActivity(proj, excluding: artifactPaths)
                let ga = Self.gitActivity(from: proj, home: home)
                accLock.lock(); a.projectActivity = pa; a.gitActivity = ga; accLock.unlock()
            }
            Self.resolveLastActivity(&a)
            accLock.lock(); found[i] = a; accLock.unlock()
        }

        return ArtifactScanResult(roots: roots, artifacts: found.sorted { $0.allocSize > $1.allocSize },
                                  eventID: startEvent, volumeUUID: uuid, date: Date(),
                                  duration: monotonicSeconds() - started, reusedSizes: reused)
    }

    static func projectArtifact(_ kind: ArtifactKind, _ path: String, project: String) -> Artifact {
        Artifact(kind: kind, path: path, projectPath: project, projectName: PathUtil.lastComponent(project))
    }

    static func globalArtifacts(home: String) -> [Artifact] {
        var out: [Artifact] = []
        func add(_ kind: ArtifactKind, _ rel: String, name: String) {
            let p = PathUtil.join(home, rel)
            if PathUtil.isDirectory(p) { out.append(Artifact(kind: kind, path: p, projectPath: nil, projectName: name)) }
        }
        add(.mavenRepository, ".m2/repository", name: "Maven (all projects)")
        add(.gradleCache, ".gradle/caches", name: "Gradle (all projects)")
        add(.gradleCache, ".gradle/wrapper/dists", name: "Gradle wrappers")
        add(.npmCache, ".npm/_cacache", name: "npm (all projects)")
        add(.pipCache, "Library/Caches/pip", name: "pip (all projects)")
        add(.homebrewCache, "Library/Caches/Homebrew", name: "Homebrew")

        let dd = PathUtil.join(home, "Library/Developer/Xcode/DerivedData")
        for e in BulkDir.list(dd).entries where e.isDirectory {
            let p = PathUtil.join(dd, e.name)
            let plist = NSDictionary(contentsOfFile: PathUtil.join(p, "info.plist"))
            let ws = plist?["WorkspacePath"] as? String
            let name = ws.map { PathUtil.lastComponent($0) } ?? e.name.components(separatedBy: "-").first ?? e.name
            out.append(Artifact(kind: .xcodeDerivedData, path: p, projectPath: ws.map(PathUtil.parent), projectName: name))
        }

        // Conda envs registered outside the scanned roots.
        if let txt = try? String(contentsOfFile: PathUtil.join(home, ".conda/environments.txt"), encoding: .utf8) {
            for line in txt.split(separator: "\n").map({ $0.trimmingCharacters(in: .whitespaces) }) where !line.isEmpty {
                let isEnv = PathUtil.isDirectory(PathUtil.join(line, "conda-meta"))
                let isBase = PathUtil.isDirectory(PathUtil.join(line, "condabin"))
                if isEnv && !isBase { out.append(Artifact(kind: .condaEnv, path: line, projectPath: nil, projectName: "conda: " + PathUtil.lastComponent(line))) }
            }
        }
        return out
    }

    /// Newest mtime among the project's own files (depth ≤ 3, bounded), skipping artifact and VCS folders.
    static func projectActivity(_ project: String, excluding artifacts: Set<String>) -> Date? {
        var newest: Int64 = 0
        var queue: [(String, Int)] = [(project, 0)]
        var seen = 0
        let buf = BulkDir.allocateBuffer()
        defer { buf.deallocate() }
        while seen < 4000, let (dir, depth) = queue.popLast() {
            let fd = BulkDir.open(dir)
            guard fd >= 0 else { continue }
            BulkDir.forEach(fd: fd, buffer: buf) { e in
                seen += 1
                let p = PathUtil.join(dir, e.name)
                if e.isDirectory {
                    if artifacts.contains(p) || artifactDirNames.contains(e.name) || e.name == ".git" { return }
                    newest = max(newest, e.mtime)
                    if depth < 3 { queue.append((p, depth + 1)) }
                } else {
                    newest = max(newest, e.mtime)
                }
            }
            close(fd)
        }
        return newest > 0 ? Date(timeIntervalSince1970: Double(newest)) : nil
    }

    /// Latest git activity (commit, checkout, pull or index update) for the repo containing `path`.
    static func gitActivity(from path: String, home: String) -> Date? {
        var cur = path
        while true {
            let dotgit = PathUtil.join(cur, ".git")
            var gitDir: String?
            if PathUtil.isDirectory(dotgit) {
                gitDir = dotgit
            } else if let s = try? String(contentsOfFile: dotgit, encoding: .utf8), s.hasPrefix("gitdir:") {
                let g = s.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
                gitDir = g.hasPrefix("/") ? g : PathUtil.join(cur, g)
            }
            if let g = gitDir {
                return ["logs/HEAD", "index", "HEAD"].compactMap { PathUtil.mtime(PathUtil.join(g, $0)) }.max()
            }
            if cur == home || cur == "/" || !cur.hasPrefix(home) { return nil }
            cur = PathUtil.parent(cur)
        }
    }

    public static func resolveLastActivity(_ a: inout Artifact) {
        var candidates: [(Date, String)] = []
        if let d = a.projectActivity { candidates.append((d, "project files modified")) }
        if let d = a.gitActivity { candidates.append((d, "git activity")) }
        if let d = a.newestInside {
            candidates.append((d, a.kind.isGlobalCache ? "dependency written" : a.kind == .condaEnv ? "env modified" : "artifact modified"))
        }
        if let best = candidates.max(by: { $0.0 < $1.0 }) {
            a.lastActivity = best.0
            a.lastActivitySource = best.1
        }
    }
}
