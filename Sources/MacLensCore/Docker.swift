import Foundation
import Darwin

public enum DockerItemKind: String, Codable, Sendable { case container, image, volume, buildCache }

public enum DockerSafety: Int, Comparable, Sendable {
    case safe, caution, data, inUse
    public static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

/// How an item is grouped in the Docker tab, from safest to delete to not deletable at all.
public enum DockerGroup: String, CaseIterable, Codable, Sendable {
    case danglingImages, stoppedContainers, buildCache, unusedImages, anonymousVolumes, namedVolumes, inUse

    public var displayName: String {
        switch self {
        case .danglingImages: return "Dangling image"
        case .stoppedContainers: return "Stopped container"
        case .buildCache: return "Build cache"
        case .unusedImages: return "Unused image"
        case .anonymousVolumes: return "Anonymous volume"
        case .namedVolumes: return "Named volume"
        case .inUse: return "In use"
        }
    }

    public var safety: DockerSafety {
        switch self {
        case .danglingImages, .stoppedContainers, .buildCache: return .safe
        case .unusedImages, .anonymousVolumes: return .caution
        case .namedVolumes: return .data
        case .inUse: return .inUse
        }
    }

    public var explanation: String {
        switch self {
        case .danglingImages: return "Untagged leftover layers from rebuilds. Nothing refers to them."
        case .stoppedContainers: return "Containers that have exited. Their writable layer is lost; the image stays."
        case .buildCache: return "Saved build steps. The next build re-runs them once."
        case .unusedImages: return "Tagged images no container uses. Docker pulls or rebuilds them again when needed."
        case .anonymousVolumes: return "Unnamed scratch volumes no container uses (e.g. left by `docker run` without `--rm`)."
        case .namedVolumes: return "Named volumes no container uses. They often hold real data, such as databases."
        case .inUse: return "Used by a container. Docker won't delete these; remove the container first."
        }
    }
}

public struct DockerItem: Identifiable, Hashable, Sendable {
    public var id: String { kind.rawValue + ":" + ref }
    public var kind: DockerItemKind
    /// What the API addresses it by: image ID, container ID, volume name, or "all" for the build cache.
    public var ref: String
    public var name: String
    public var tags: [String] = []
    public var detail = ""
    /// Bytes, or -1 when Docker didn't report it.
    public var size: Int64 = -1
    /// Estimated bytes freed inside Docker's disk by deleting it (shared image layers are excluded), or -1 if unknown.
    public var frees: Int64 = -1
    public var created: Date?
    public var lastUsed: Date?
    public var project: String?
    public var labels: [String: String] = [:]
    public var group: DockerGroup
    public var inUseReason: String?
    /// Containers: the image they run and the volumes they mount.
    public var imageID: String?
    public var volumes: [String] = []
    public var running = false
    public var anonymous = false
    /// Named volumes may hold real data (databases), whatever group they are in right now.
    public var isNamedVolume: Bool { kind == .volume && !anonymous }

    public init(kind: DockerItemKind, ref: String, name: String, group: DockerGroup) {
        self.kind = kind; self.ref = ref; self.name = name; self.group = group
    }
}

public struct DockerEngineInfo: Sendable, Equatable {
    public var platform = ""
    public var version = ""
    public init(platform: String = "", version: String = "") { self.platform = platform; self.version = version }
}

/// Turns `GET /system/df` into grouped items. Pure, so the self-test can feed it recorded responses.
public enum DockerClassifier {
    public static let projectLabel = "com.docker.compose.project"
    public static let anonymousLabel = "com.docker.volume.anonymous"
    static let activeStates: Set<String> = ["running", "paused", "restarting", "removing"]

    private struct DF: Decodable {
        var Images: [Image]?
        var Containers: [Container]?
        var Volumes: [Volume]?
        var BuildCache: [Cache]?
    }
    private struct Image: Decodable {
        var Id: String
        var RepoTags: [String]?
        var Created: Int64?
        var Size: Int64?
        var SharedSize: Int64?
        var Containers: Int64?
        var Labels: [String: String]?
    }
    private struct Container: Decodable {
        var Id: String
        var Names: [String]?
        var Image: String?
        var ImageID: String?
        var Created: Int64?
        var SizeRw: Int64?
        var State: String?
        var Status: String?
        var Labels: [String: String]?
        var Mounts: [Mount]?
    }
    private struct Mount: Decodable { var `Type`: String?; var Name: String? }
    private struct Volume: Decodable {
        var Name: String
        var CreatedAt: String?
        var Driver: String?
        var Labels: [String: String]?
        var UsageData: Usage?
    }
    private struct Usage: Decodable { var RefCount: Int64?; var Size: Int64? }
    private struct Cache: Decodable {
        var InUse: Bool?
        var Shared: Bool?
        var Size: Int64?
        var LastUsedAt: String?
    }

    public static func items(systemDF data: Data) throws -> [DockerItem] {
        let df: DF
        do { df = try JSONDecoder().decode(DF.self, from: data) } catch { throw DockerError.decode("\(error)") }
        var out: [DockerItem] = []

        let containers = df.Containers ?? []
        func containerName(_ c: Container) -> String {
            (c.Names?.first).map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 } ?? String(c.Id.prefix(12))
        }
        /// Why something used by these containers can't be deleted yet.
        func usedReason(_ users: [Container]) -> String? {
            guard !users.isEmpty else { return nil }
            if let r = users.first(where: { activeStates.contains($0.State ?? "") }) {
                return "Used by running container \(containerName(r))" + (users.count > 1 ? " and \(users.count - 1) more" : "") + "."
            }
            return "Used by stopped container \(containerName(users[0]))" + (users.count > 1 ? " and \(users.count - 1) more" : "") +
                ". Delete the container first."
        }

        for c in containers {
            let running = activeStates.contains(c.State ?? "")
            var it = DockerItem(kind: .container, ref: c.Id, name: containerName(c), group: running ? .inUse : .stoppedContainers)
            it.detail = [c.Image, c.Status].compactMap { $0 }.joined(separator: " · ")
            it.size = c.SizeRw ?? -1
            it.frees = c.SizeRw ?? -1
            it.created = c.Created.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            it.labels = c.Labels ?? [:]
            it.project = it.labels[projectLabel]
            it.imageID = c.ImageID
            it.volumes = (c.Mounts ?? []).filter { $0.Type == "volume" }.compactMap(\.Name)
            it.running = running
            if running { it.inUseReason = "Running (\(c.State ?? "")). Stop it before deleting." }
            out.append(it)
        }

        for i in df.Images ?? [] {
            let tags = (i.RepoTags ?? []).filter { $0 != "<none>:<none>" }
            let users = containers.filter { $0.ImageID == i.Id }
            var it = DockerItem(kind: .image, ref: i.Id, name: tags.first ?? "<none>", group: .unusedImages)
            it.tags = tags
            it.size = i.Size ?? -1
            if let s = i.Size, let sh = i.SharedSize {
                it.frees = sh < 0 ? s : (sh <= s ? s - sh : -1) // -1: Docker's shared size exceeds the size (multi-platform index)
            }
            it.created = i.Created.map { Date(timeIntervalSince1970: TimeInterval($0)) }
            it.labels = i.Labels ?? [:]
            it.project = it.labels[projectLabel]
            it.detail = String(i.Id.replacingOccurrences(of: "sha256:", with: "").prefix(12)) + (tags.count > 1 ? " · \(tags.count) tags" : "")
            if let r = usedReason(users) {
                it.group = .inUse; it.inUseReason = r
            } else if (i.Containers ?? 0) > 0 {
                it.group = .inUse; it.inUseReason = "Used by \(i.Containers!) container(s)."
            } else {
                it.group = tags.isEmpty ? .danglingImages : .unusedImages
            }
            out.append(it)
        }

        for v in df.Volumes ?? [] {
            let labels = v.Labels ?? [:]
            let users = containers.filter { c in (c.Mounts ?? []).contains { $0.Type == "volume" && $0.Name == v.Name } }
            let anonymous = isAnonymousVolume(name: v.Name, labels: labels)
            var it = DockerItem(kind: .volume, ref: v.Name, name: anonymous ? String(v.Name.prefix(12)) + "…" : v.Name,
                                group: anonymous ? .anonymousVolumes : .namedVolumes)
            it.labels = labels
            it.anonymous = anonymous
            it.project = labels[projectLabel]
            it.size = v.UsageData?.Size ?? -1
            it.frees = it.size
            it.created = v.CreatedAt.flatMap(parseDate)
            it.detail = (anonymous ? "anonymous" : "named") + (v.Driver.map { $0 == "local" ? "" : " · \($0)" } ?? "")
            if let r = usedReason(users) {
                it.group = .inUse; it.inUseReason = r
            } else if (v.UsageData?.RefCount ?? 0) > 0 {
                it.group = .inUse; it.inUseReason = "Used by \(v.UsageData!.RefCount!) container(s)."
            }
            out.append(it)
        }

        let cache = df.BuildCache ?? []
        if !cache.isEmpty {
            let idle = cache.filter { $0.InUse != true }
            var it = DockerItem(kind: .buildCache, ref: "all", name: "Build cache (\(cache.count) entries)",
                                group: idle.isEmpty ? .inUse : .buildCache)
            it.size = cache.reduce(0) { $0 + max(0, $1.Size ?? 0) }
            it.frees = idle.filter { $0.Shared != true }.reduce(0) { $0 + max(0, $1.Size ?? 0) }
            it.lastUsed = cache.compactMap { $0.LastUsedAt.flatMap(parseDate) }.max()
            let shared = cache.filter { $0.Shared == true }.count
            it.detail = "\(idle.count) not in use" + (shared > 0 ? " · \(shared) shared with images (freed only when those images go)" : "")
            if idle.isEmpty { it.inUseReason = "A build is using the cache right now." }
            out.append(it)
        }
        return out
    }

    /// Docker 23+ labels anonymous volumes; older engines only give them a random 64-hex-digit name.
    public static func isAnonymousVolume(name: String, labels: [String: String]) -> Bool {
        if labels[anonymousLabel] != nil { return true }
        return name.count == 64 && name.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    /// RFC 3339 with up to nanosecond fractions, which ISO8601DateFormatter can't read.
    static func parseDate(_ s: String) -> Date? {
        var t = s
        if let dot = t.firstIndex(of: ".") {
            let rest = t[dot...]
            let zone = rest.firstIndex { $0 == "Z" || $0 == "+" || $0 == "-" } ?? rest.endIndex
            t.removeSubrange(dot..<zone)
        }
        return ISO8601DateFormatter().date(from: t)
    }

    public static func engineInfo(version data: Data) -> DockerEngineInfo {
        let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return DockerEngineInfo(platform: (j["Platform"] as? [String: Any])?["Name"] as? String ?? "", version: j["Version"] as? String ?? "")
    }
}

/// Everything a compose project left behind, and what must be kept because it's still running.
public struct DockerProjectPlan: Sendable {
    public var project: String
    public var remove: [DockerItem]
    public var keep: [DockerItem]
    public var size: Int64 { remove.reduce(0) { $0 + max(0, $1.frees) } }
}

public enum DockerProjects {
    public static func names(_ items: [DockerItem]) -> [String] {
        Array(Set(items.compactMap(\.project))).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Stopped containers of the project, then images and volumes that only those containers use (or that carry the
    /// project's label). Running containers, and anything another container still uses, are kept.
    public static func plan(_ project: String, items: [DockerItem]) -> DockerProjectPlan {
        let containers = items.filter { $0.kind == .container }
        let mine = containers.filter { $0.project == project }
        let removedContainers = mine.filter { !$0.running }
        let removedIDs = Set(removedContainers.map(\.ref))
        let others = containers.filter { !removedIDs.contains($0.ref) }
        var remove = removedContainers, keep = mine.filter(\.running)
        for it in items where it.kind == .image || it.kind == .volume {
            let usedByRemoved = removedContainers.contains { it.kind == .image ? $0.imageID == it.ref : $0.volumes.contains(it.ref) }
            let usedByOthers = others.contains { it.kind == .image ? $0.imageID == it.ref : $0.volumes.contains(it.ref) }
            guard it.project == project || usedByRemoved else { continue }
            if usedByOthers { keep.append(it) } else { remove.append(it) }
        }
        return DockerProjectPlan(project: project, remove: remove, keep: keep)
    }
}

public struct DockerDeleteProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    /// "Checking with Docker", "Deleting", "Pruning" or "Done".
    public let step: String
    public let current: String
    public init(done: Int, total: Int, step: String, current: String) { self.done = done; self.total = total; self.step = step; self.current = current }
    public var fraction: Double { total == 0 ? 1 : Double(done) / Double(total) }
}

public struct DockerDeleteOutcome: Sendable {
    public let item: DockerItem
    public let error: String?
    /// Bytes Docker reported freeing (build cache), else the item's estimate.
    public let reclaimed: Int64
}

/// The single source of truth for "may this Docker item be deleted?", enforced inside `delete`, not just in the UI.
public enum DockerCleaner {
    /// Development/testing fence, like MACLENS_DELETE_SANDBOX: when set, only items carrying this label are deleted.
    public static let sandboxLabel: String? = ProcessInfo.processInfo.environment["MACLENS_DOCKER_SANDBOX"]

    public static let summary = """
    Docker deletions are permanent (there is no Trash). MacLens never deletes running containers or anything a \
    container uses, never forces a delete, and deletes named volumes only after a separate confirmation. Each item is \
    re-read from Docker right before it is deleted.
    """

    public static func verdict(_ item: DockerItem, allowData: Bool) -> DeletionVerdict {
        if let s = sandboxLabel, item.labels[s] == nil { return .blocked("Outside MACLENS_DOCKER_SANDBOX (no \(s) label).") }
        if item.group == .inUse { return .blocked(item.inUseReason ?? "In use.") }
        if item.group == .namedVolumes && !allowData { return .blocked("Named volume: may hold data, needs its own confirmation.") }
        return .allowed
    }

    public static func load(_ ep: DockerEndpoint) throws -> [DockerItem] {
        try DockerClassifier.items(systemDF: DockerAPI.get(ep, "/system/df", timeout: 180))
    }

    /// Deletes containers first, then images, volumes and the build cache, re-reading Docker before each stage so
    /// that images and volumes freed by deleting a project's containers can go in the same run.
    /// `progress` is called before each step (on the calling thread); `isCancelled` is checked between items, and
    /// items not reached are reported as cancelled.
    public static func delete(_ items: [DockerItem], allowData: Bool, endpoint ep: DockerEndpoint,
                              progress: ((DockerDeleteProgress) -> Void)? = nil,
                              isCancelled: (() -> Bool)? = nil) -> [DockerDeleteOutcome] {
        var out: [DockerDeleteOutcome] = []
        let total = items.count
        func report(_ step: String, _ name: String) { progress?(DockerDeleteProgress(done: out.count, total: total, step: step, current: name)) }
        for stage in [DockerItemKind.container, .image, .volume, .buildCache] {
            let wanted = items.filter { $0.kind == stage }
            guard !wanted.isEmpty else { continue }
            if isCancelled?() == true { out += wanted.map { .init(item: $0, error: "Cancelled.", reclaimed: 0) }; continue }
            report("Checking with Docker", "")
            let fresh: [String: DockerItem]
            do { fresh = Dictionary(try load(ep).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) } catch {
                out += wanted.map { DockerDeleteOutcome(item: $0, error: "\(error)", reclaimed: 0) }
                continue
            }
            for item in wanted {
                if isCancelled?() == true { out.append(.init(item: item, error: "Cancelled.", reclaimed: 0)); continue }
                guard let now = fresh[item.id] else { out.append(.init(item: item, error: "No longer exists.", reclaimed: 0)); continue }
                if item.kind != .buildCache && now.created != item.created {
                    out.append(.init(item: item, error: "Changed since it was listed. Refresh and try again.", reclaimed: 0)); continue
                }
                if let why = verdict(now, allowData: allowData).reason { out.append(.init(item: item, error: why, reclaimed: 0)); continue }
                report(item.kind == .buildCache ? "Pruning" : "Deleting", item.name)
                do {
                    let freed = try perform(now, ep)
                    out.append(.init(item: item, error: nil, reclaimed: freed))
                } catch {
                    out.append(.init(item: item, error: "\(error)", reclaimed: 0))
                }
            }
        }
        report("Done", "")
        return out
    }

    /// Never forced: Docker itself refuses anything still in use.
    static func perform(_ it: DockerItem, _ ep: DockerEndpoint) throws -> Int64 {
        func call(_ method: String, _ path: String) throws -> Data {
            let r = try DockerAPI.request(ep, method, path, timeout: 300)
            guard (200..<300).contains(r.status) else { throw DockerError.http(r.status, r.message) }
            return r.body
        }
        switch it.kind {
        case .container:
            _ = try call("DELETE", "/containers/\(DockerAPI.segment(it.ref))")
        case .image:
            // An image with several tags is deleted by untagging each one; deleting by ID would need force.
            if it.tags.isEmpty { _ = try call("DELETE", "/images/\(DockerAPI.segment(it.ref))") }
            for t in it.tags { _ = try call("DELETE", "/images/\(DockerAPI.segment(t))") }
        case .volume:
            _ = try call("DELETE", "/volumes/\(DockerAPI.segment(it.ref))")
        case .buildCache:
            let body = try call("POST", "/build/prune?all=true")
            let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
            return (j?["SpaceReclaimed"] as? NSNumber)?.int64Value ?? max(0, it.frees)
        }
        return max(0, it.frees)
    }
}

/// The VM disk file a Mac Docker runtime keeps everything in. Freed space inside Docker shows up here only once the
/// runtime hands the blocks back to macOS, so the allocated size is measured, not assumed.
public struct DockerVMDisk: Sendable, Equatable {
    public let path: String
    public let runtime: String
    /// Bytes actually on disk (the file is sparse).
    public let allocated: Int64
    /// The file's nominal size: the disk limit, not usage.
    public let apparent: Int64
}

public enum DockerVM {
    static func candidates(home: String) -> [(String, String)] {
        [(PathUtil.join(home, "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw"), "Docker Desktop"),
         (PathUtil.join(home, "Library/Containers/com.docker.docker/Data/vms/0/data/Docker.qcow2"), "Docker Desktop"),
         (PathUtil.join(home, ".colima/_lima/colima/diffdisk"), "Colima")]
    }

    /// The disk of the given runtime, else the first one found.
    public static func disk(runtime: String? = nil, home: String = PathUtil.home) -> DockerVMDisk? {
        let all = candidates(home: home).compactMap { measure($0.0, runtime: $0.1) }
        return all.first { $0.runtime == runtime } ?? all.first
    }

    public static func measure(_ path: String, runtime: String) -> DockerVMDisk? {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        return DockerVMDisk(path: path, runtime: runtime, allocated: Int64(st.st_blocks) * 512, apparent: Int64(st.st_size))
    }

    /// For the Storage tab: names a known VM disk file instead of leaving it a mystery.
    public static func label(forPath path: String, home: String = PathUtil.home) -> String? {
        candidates(home: home).first { $0.0 == path }.map { "\($0.1) VM disk: images, containers, volumes and build cache" }
    }
}
