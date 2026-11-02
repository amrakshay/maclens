import AppKit
import SwiftUI
import MacLensCore

/// Docker's disk usage (#51). Docker is asked only while the Docker tab is open, or when the user refreshes;
/// nothing runs in the background, and MacLens never starts Docker.
@MainActor final class DockerStore: ObservableObject {
    enum State: Equatable { case idle, loading, notRunning, failed(String), ready }

    struct CleanupReport {
        var deleted = 0
        var failures: [(String, String)] = []
        /// What Docker reported or estimated freeing inside its disk.
        var reported: Int64 = 0
        var diskBefore: Int64?
        var diskAfter: Int64?
    }

    @Published private(set) var items: [DockerItem] = []
    @Published private(set) var state: State = .idle
    @Published private(set) var endpoint: DockerEndpoint?
    @Published private(set) var engine = DockerEngineInfo()
    @Published private(set) var vmDisk: DockerVMDisk?
    @Published private(set) var loadedAt: Date?
    @Published private(set) var deleting = false
    @Published var report: CleanupReport?
    @Published var groups: Set<DockerGroup> = Set(DockerGroup.allCases)
    @Published var project: String?
    @Published var search = ""
    private var loading = false

    var filtered: [DockerItem] {
        items.filter { (it: DockerItem) -> Bool in
            guard groups.contains(it.group) else { return false }
            if let p = project, it.project != p { return false }
            guard !search.isEmpty else { return true }
            let text: [String] = [it.name, it.tags.joined(separator: " "), it.project ?? "", it.detail]
            return text.joined(separator: " ").localizedCaseInsensitiveContains(search)
        }
    }

    var projects: [String] { DockerProjects.names(items) }

    /// Estimated space the safe and caution groups would free (named volumes and in-use items excluded).
    var reclaimableWithoutData: Int64 {
        items.filter { $0.group.safety <= .caution }.reduce(0) { $0 + max(0, $1.frees) }
    }

    func refreshIfStale() {
        if loadedAt == nil || Date().timeIntervalSince(loadedAt!) > 60 || state != .ready { refresh() }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        if items.isEmpty { state = .loading }
        Thread.detachNewThread {
            let ep = DockerAPI.discover()
            var items: [DockerItem] = [], info = DockerEngineInfo(), err: String?
            if let ep {
                do {
                    items = try DockerCleaner.load(ep)
                    info = (try? DockerAPI.get(ep, "/version", timeout: 10)).map(DockerClassifier.engineInfo) ?? info
                } catch { err = "\(error)" }
            }
            let disk = DockerVM.disk(runtime: ep?.runtime)
            DispatchQueue.main.async {
                self.loading = false
                self.endpoint = ep
                self.vmDisk = disk
                guard ep != nil else { self.items = []; self.state = .notRunning; self.loadedAt = nil; return }
                if let err { self.state = .failed(err); return }
                self.items = items
                self.engine = info
                self.loadedAt = Date()
                self.state = .ready
                if let p = self.project, !self.projects.contains(p) { self.project = nil }
            }
        }
    }

    /// Cheap: one stat() of the VM disk file, for the summary row in Developer Artifacts.
    func measureDisk() {
        DispatchQueue.global(qos: .utility).async {
            let d = DockerVM.disk(runtime: nil)
            DispatchQueue.main.async { self.vmDisk = d }
        }
    }

    func delete(_ targets: [DockerItem], allowData: Bool, completion: @escaping () -> Void) {
        guard let ep = endpoint, !targets.isEmpty else { return }
        deleting = true
        let before = vmDisk?.allocated
        let runtime = ep.runtime
        DispatchQueue.global(qos: .userInitiated).async {
            let outcomes = DockerCleaner.delete(targets, allowData: allowData, endpoint: ep)
            let after = DockerVM.disk(runtime: runtime)?.allocated
            DispatchQueue.main.async {
                self.deleting = false
                let ok = outcomes.filter { $0.error == nil }
                self.report = CleanupReport(deleted: ok.count,
                                            failures: outcomes.compactMap { o in o.error.map { (o.item.name, $0) } },
                                            reported: ok.reduce(0) { $0 + $1.reclaimed }, diskBefore: before, diskAfter: after)
                self.refresh()
                self.remeasure(after: [20, 60, 180])
                completion()
            }
        }
    }

    /// The runtime hands freed blocks back to macOS asynchronously, so the VM disk is measured again a few times.
    private func remeasure(after delays: [Double]) {
        for d in delays {
            DispatchQueue.main.asyncAfter(deadline: .now() + d) {
                guard let path = self.vmDisk?.path, let rt = self.vmDisk?.runtime, let m = DockerVM.measure(path, runtime: rt) else { return }
                self.vmDisk = m
                self.report?.diskAfter = m.allocated
            }
        }
    }
}

extension DockerItem {
    var groupSort: Int { DockerGroup.allCases.firstIndex(of: group) ?? 0 }
    var projectSort: String { project ?? "" }
    var createdSort: Date { lastUsed ?? created ?? .distantPast }
}

extension DockerSafety {
    var color: Color {
        switch self {
        case .safe: return .green
        case .caution: return .yellow
        case .data: return .red
        case .inUse: return .secondary
        }
    }
    var label: String {
        switch self {
        case .safe: return "Safe to delete"
        case .caution: return "Comes back when needed (re-pull or rebuild)"
        case .data: return "May hold real data"
        case .inUse: return "In use: can't be deleted"
        }
    }
}

struct DockerView: View {
    @EnvironmentObject var store: DockerStore
    @State private var selection = Set<DockerItem.ID>()
    @State private var sortOrder = [KeyPathComparator(\PositionRow<DockerItem>.item.groupSort),
                                    KeyPathComparator(\PositionRow<DockerItem>.item.size, order: .reverse)]
    @State private var confirm: DockerConfirm?

    var rows: [PositionRow<DockerItem>] { PositionRow.sorted(store.filtered, by: sortOrder) }
    var selected: [DockerItem] { store.items.filter { selection.contains($0.id) } }

    var body: some View {
        VStack(spacing: 0) {
            header
            if let r = store.report { reportBanner(r) }
            switch store.state {
            case .notRunning:
                ContentUnavailableView {
                    Label("Docker is not running", systemImage: "square.stack.3d.up.slash")
                } description: {
                    Text("MacLens doesn't start Docker. Start Docker Desktop, OrbStack, Colima or Rancher Desktop, then press Refresh.")
                } actions: { Button("Refresh") { store.refresh() } }
                .frame(maxHeight: .infinity)
            case .failed(let e) where store.items.isEmpty:
                ContentUnavailableView("Couldn't read Docker's usage", systemImage: "exclamationmark.triangle", description: Text(e))
                    .frame(maxHeight: .infinity)
            case .idle, .loading:
                ProgressView("Asking Docker…").frame(maxHeight: .infinity)
            default:
                table
                footer
            }
        }
        .onAppear { store.refreshIfStale() }
        .sheet(item: $confirm) { c in
            DockerConfirmSheet(confirm: c) { allowData in
                let targets = c.items
                confirm = nil
                store.delete(targets, allowData: allowData) { selection.removeAll() }
            } onCancel: { confirm = nil }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let ep = store.endpoint {
                    Label(store.engine.platform.isEmpty ? ep.runtime : store.engine.platform, systemImage: "square.stack.3d.up")
                        .help("Socket: \(ep.socketPath)" + (store.engine.version.isEmpty ? "" : "\nEngine \(store.engine.version)"))
                }
                if let d = store.vmDisk {
                    Text("VM disk \(Fmt.bytes(d.allocated)) on disk")
                        .help("\(d.path)\nThe file's nominal size, \(Fmt.bytes(d.apparent)), is the disk limit, not usage: the file is sparse.")
                }
                Spacer(minLength: 0)
                if store.deleting { ProgressView().controlSize(.small); Text("Deleting…") }
                else if store.state == .loading || (store.state == .ready && store.loadedAt == nil) { ProgressView().controlSize(.small) }
                if let t = store.loadedAt { Text(Date().timeIntervalSince(t) < 60 ? "Updated just now" : "Updated \(Fmt.relative(t))").font(.callout).foregroundStyle(.secondary) }
                Button("Refresh") { store.refresh() }.keyboardShortcut("r").disabled(store.deleting)
            }
            HStack(spacing: 10) {
                Menu("Groups (\(store.groups.count)/\(DockerGroup.allCases.count))") {
                    Button("All") { store.groups = Set(DockerGroup.allCases) }
                    Button("Deletable only") { store.groups = Set(DockerGroup.allCases.filter { $0 != .inUse }) }
                    Divider()
                    ForEach(DockerGroup.allCases, id: \.self) { g in
                        Toggle(g.displayName, isOn: Binding(get: { store.groups.contains(g) },
                                                            set: { on in if on { store.groups.insert(g) } else { store.groups.remove(g) } }))
                    }
                }
                .fixedSize()
                Picker("Project", selection: $store.project) {
                    Text("All projects").tag(String?.none)
                    ForEach(store.projects, id: \.self) { Text($0).tag(String?.some($0)) }
                }
                .fixedSize()
                .help("Compose project (com.docker.compose.project label)")
                if let p = store.project {
                    Button("Clean Up Project…") {
                        let plan = DockerProjects.plan(p, items: store.items)
                        confirm = DockerConfirm(title: "Clean up project \(p)?", items: plan.remove, kept: plan.keep, project: true)
                    }
                    .disabled(store.deleting)
                    .help("Deletes the project's stopped containers, then the images and volumes only they used. Running containers and anything shared are kept.")
                }
                Divider().frame(height: 18)
                Button("Select Safe Items") {
                    selection = Set(store.filtered.filter { $0.group.safety == .safe }.map(\.id))
                }
                .help("Selects dangling images, stopped containers and the build cache in the current view.")
                Spacer(minLength: 12)
                TextField("Filter by name, tag or project", text: $store.search).textFieldStyle(.roundedBorder).frame(maxWidth: 240)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var table: some View {
        let rows = self.rows
        return Table(rows, selection: rows.selection($selection), sortOrder: $sortOrder) {
            TableColumn("Group", value: \.item.groupSort) { r in
                let it = r.item
                HStack(spacing: 6) {
                    if it.group == .inUse { Image(systemName: "lock.fill").foregroundStyle(.secondary) }
                    else { Circle().fill(it.group.safety.color).frame(width: 9, height: 9) }
                    Text(it.group.displayName)
                }
                .help(it.group.safety.label + ". " + (it.inUseReason ?? it.group.explanation))
            }.width(min: 130, ideal: 150)
            TableColumn("Name", value: \.item.name) { r in
                let it = r.item
                HStack(spacing: 4) {
                    Image(systemName: icon(it.kind)).foregroundStyle(.secondary)
                    Text(it.name).lineLimit(1).truncationMode(.middle)
                    if it.isNamedVolume && it.group == .inUse { Image(systemName: "cylinder.split.1x2").foregroundStyle(.red).help("Named volume: may hold data") }
                }
                .help(([it.name] + it.tags.dropFirst()).joined(separator: "\n"))
            }.width(min: 180, ideal: 280)
            TableColumn("Size", value: \.item.size) { Text(Fmt.bytes($0.item.size)).monospacedDigit() }.width(80)
            TableColumn("Frees", value: \.item.frees) { r in
                Text(r.item.frees < 0 ? "—" : "~" + Fmt.bytes(r.item.frees)).monospacedDigit()
                    .help("Estimated space freed inside Docker's disk. Image layers shared with other images aren't counted. macOS gets it back only when Docker returns it.")
            }.width(85)
            TableColumn("Project", value: \.item.projectSort) { Text($0.item.project ?? "").lineLimit(1) }.width(min: 80, ideal: 130)
            TableColumn("Created / used", value: \.item.createdSort) { r in
                let it = r.item
                Text(Fmt.relative(it.lastUsed ?? it.created))
                    .help(it.lastUsed != nil ? "Last used \(Fmt.date(it.lastUsed))" : "Created \(Fmt.date(it.created))")
            }.width(min: 100, ideal: 120)
            TableColumn("Details", value: \.item.detail) { r in
                Text(r.item.inUseReason ?? r.item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(r.item.inUseReason ?? r.item.detail)
            }
        }
        .contextMenu(forSelectionType: Int.self) { positions in
            let its = rows.items(at: positions)
            Button("Copy Name") { copy(its.map { $0.tags.first ?? ($0.kind == .volume ? $0.ref : $0.name) }) }
            Button("Copy ID") { copy(its.map(\.ref)) }
            if let p = its.first?.project { Button("Show Project \(p)") { store.project = p } }
        }
    }

    private var footer: some View {
        let shown = store.filtered
        let sel = selected
        let deletable = sel.filter { $0.group != .inUse }
        return HStack {
            Text("\(shown.count) items · \(Fmt.bytes(shown.reduce(0) { $0 + max(0, $1.size) }))")
            Text("· ~\(Fmt.bytes(store.reclaimableWithoutData)) reclaimable without named volumes")
                .foregroundStyle(.secondary)
                .help("Safe and caution groups across everything Docker reported. Named volumes and in-use items are excluded.")
            if !sel.isEmpty {
                Text("· selected \(sel.count): ~\(Fmt.bytes(deletable.reduce(0) { $0 + max(0, $1.frees) }))").bold()
            }
            Spacer()
            Button("Delete…", role: .destructive) {
                confirm = DockerConfirm(title: "Delete \(sel.count) Docker items?", items: sel, kept: [], project: false)
            }
            .disabled(deletable.isEmpty || store.deleting)
            .help(sel.isEmpty ? "Select one or more items" : deletable.isEmpty ? "Everything selected is in use" : "Docker deletions are permanent.")
        }
        .font(.callout)
        .padding(10)
        .background(.bar)
    }

    private func reportBanner(_ r: DockerStore.CleanupReport) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: r.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(r.failures.isEmpty ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Deleted \(r.deleted) item\(r.deleted == 1 ? "" : "s"), about \(Fmt.bytes(r.reported)) inside Docker." +
                     (r.failures.isEmpty ? "" : " \(r.failures.count) couldn't be deleted."))
                if let b = r.diskBefore, let a = r.diskAfter {
                    let gained = b - a
                    Text(gained > 0 ? "VM disk \(Fmt.bytes(b)) → \(Fmt.bytes(a)) so far: macOS got \(Fmt.bytes(gained)) back."
                                    : "VM disk still \(Fmt.bytes(a)). macOS gets the space back only when Docker returns it, which can lag; MacLens re-measures for a few minutes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(r.failures.prefix(5).enumerated()), id: \.offset) { _, f in
                    Text("\(f.0): \(f.1)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Button { store.report = nil } label: { Image(systemName: "xmark") }.buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary.opacity(0.5))
    }

    private func icon(_ k: DockerItemKind) -> String {
        switch k {
        case .container: return "shippingbox"
        case .image: return "square.stack.3d.up"
        case .volume: return "cylinder"
        case .buildCache: return "hammer"
        }
    }

    private func copy(_ lines: [String]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
    }
}

struct DockerConfirm: Identifiable {
    let id = UUID()
    let title: String
    let items: [DockerItem]
    let kept: [DockerItem]
    /// Project clean-up: images and volumes in the plan are in use only by the plan's own containers.
    let project: Bool
}

struct DockerConfirmSheet: View {
    let confirm: DockerConfirm
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void
    @State private var dataAcknowledged = false

    var body: some View {
        let skipped = confirm.project ? [] : confirm.items.filter { $0.group == .inUse }
        let allowed = confirm.items.filter { it in !skipped.contains { $0.id == it.id } }
        let named = allowed.filter(\.isNamedVolume)
        let other = allowed.filter { !$0.isNamedVolume }
        VStack(alignment: .leading, spacing: 12) {
            Text(confirm.title).font(.title3.bold())
            Text("About \(Fmt.bytes(allowed.reduce(0) { $0 + max(0, $1.frees) })) will be freed inside Docker's disk" +
                 (named.isEmpty ? "." : " (\(Fmt.bytes(other.reduce(0) { $0 + max(0, $1.frees) })) without the named volumes)."))
            Label("Docker deletions are permanent. There is no Trash.", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            ForEach(Array(Set(allowed.map(\.group)).filter { $0.safety == .caution }).sorted { $0.rawValue < $1.rawValue }, id: \.self) { g in
                Label(g.explanation, systemImage: "arrow.down.circle").foregroundStyle(.orange)
            }
            List {
                if !other.isEmpty {
                    Section("Delete (\(other.count))") { ForEach(other) { row($0) } }
                }
                if !named.isEmpty {
                    Section("Named volumes (\(named.count)): may hold data") { ForEach(named) { row($0) } }
                }
                if !confirm.kept.isEmpty {
                    Section("Kept: running or shared with another container") {
                        ForEach(confirm.kept) { Text("\($0.name) · \($0.inUseReason ?? $0.group.displayName)").font(.caption).foregroundStyle(.secondary) }
                    }
                }
                if !skipped.isEmpty {
                    Section("Skipped: in use") {
                        ForEach(skipped) { Text("\($0.name) · \($0.inUseReason ?? "")").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
            if !named.isEmpty {
                Toggle(isOn: $dataAcknowledged) {
                    Text("I understand the \(named.count) named volume\(named.count == 1 ? "" : "s") above may hold databases or other data, and will be erased.")
                }
                .toggleStyle(.checkbox)
                .foregroundStyle(.red)
            }
            HStack {
                if !named.isEmpty && !dataAcknowledged {
                    Text("Without this, named volumes are skipped.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button("Delete Permanently", role: .destructive) { onConfirm(dataAcknowledged) }
                    .disabled(other.isEmpty && !dataAcknowledged)
            }
        }
        .padding(20)
        .frame(width: 660)
    }

    private func row(_ it: DockerItem) -> some View {
        HStack {
            Circle().fill(it.isNamedVolume ? Color.red : it.group.safety.color).frame(width: 8, height: 8)
            Text(it.kind == .volume ? it.ref : it.name).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
            Text(it.group == .inUse ? it.kind.rawValue : it.group.displayName).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(it.frees < 0 ? "—" : Fmt.bytes(it.frees)).monospacedDigit()
        }
    }
}

/// One line in Developer Artifacts pointing at the Docker tab (#51). Only stats the VM disk file; doesn't ask Docker.
struct DockerSummaryRow: View {
    @EnvironmentObject var docker: DockerStore
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let d = docker.vmDisk {
            HStack(spacing: 8) {
                Image(systemName: "square.stack.3d.up").foregroundStyle(.secondary)
                Text("Docker: \(Fmt.bytes(d.allocated)) on disk (\(d.runtime) VM)" +
                     (docker.state == .ready ? " · ~\(Fmt.bytes(docker.reclaimableWithoutData)) reclaimable" : ""))
                Spacer()
                Button("Open Docker →") { model.tab = .docker }.buttonStyle(.link)
            }
            .font(.callout)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
