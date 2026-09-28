import AppKit
import SwiftUI
import MacLensCore

struct SystemDefinitionButton: View {
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.borderless)
            .help("What counts as a system process?")
            .popover(isPresented: $show) {
                Text(SystemClassifier.definition).padding().frame(width: 420).fixedSize(horizontal: false, vertical: true)
            }
    }
}

struct ProcessesView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: MonitorStore
    @EnvironmentObject var settings: Settings
    @State private var sortOrder = [KeyPathComparator(\Row.p.cpu, order: .reverse)]
    @State private var selection: ProcSample.ID?
    @State private var appSelection: AppRow.ID?
    @State private var search = ""

    /// Rows are identified by position, not PID. With PIDs, every re-sort (or CPU reshuffle between ticks) became a
    /// table move per row, and moving a row makes NSTableView build its cells even off screen: sorting ~700 processes
    /// froze the UI and left ~400 MB of cells behind (#32). By position, a re-sort only refreshes the visible rows.
    struct Row: Identifiable { var id: Int; let p: ProcSample }

    var rows: [Row] {
        monitor.processes.filter { p in
            (!settings.hideSystemProcesses || !p.isSystem) && p.matches(search)
        }.map { Row(id: 0, p: $0) }.sorted(using: sortOrder).enumerated().map { Row(id: $0.offset, p: $0.element.p) }
    }

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(hideSystem: $settings.hideSystemProcesses, hiddenCount: monitor.processes.filter(\.isSystem).count, noun: "processes", showRefresh: true) {
                Picker("", selection: $settings.groupProcessesByApp) {
                    Text("Processes").tag(false)
                    Text("Applications").tag(true)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .help("Applications adds up each app's processes (helpers, renderers and the commands it started).")
            }
            if settings.groupProcessesByApp { AppGroupsTable(search: search, selection: $appSelection) } else { processTable }
        }
        .searchable(text: $search, prompt: "Name, PID or path")
        .inspector(isPresented: inspectorShown) {
            Group {
                if settings.groupProcessesByApp, let id = appSelection {
                    if let pid = AppRow.pid(id) { ProcessDetailView(pid: pid) } else { AppGroupDetailView(id: id) }
                } else if !settings.groupProcessesByApp, let pid = selection {
                    ProcessDetailView(pid: pid)
                }
            }.inspectorColumnWidth(min: 300, ideal: 340)
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { settings.groupProcessesByApp ? appSelection != nil : selection != nil },
                set: { if !$0 { selection = nil; appSelection = nil } })
    }

    @ViewBuilder private var processTable: some View {
        let rows = self.rows
        // Selection still follows the PID, so it stays on the same process as rows move.
        let rowSelection = Binding<Int?>(get: { selection.flatMap { pid in rows.firstIndex { $0.p.pid == pid } } },
                                         set: { i in selection = i.map { rows[$0].p.pid } })
        Table(rows, selection: rowSelection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.p.name) { r in
                let p = r.p
                HStack(spacing: 4) {
                    Text(p.name).lineLimit(1)
                    if p.isSystem { Image(systemName: "gearshape.fill").foregroundStyle(.tertiary).help("System: " + p.systemReasons.joined(separator: "; ")) }
                }
            }.width(min: 160, ideal: 220)
            TableColumn("PID", value: \.p.pid) { Text(String($0.p.pid)).monospacedDigit() }.width(60)
            TableColumn("User", value: \.p.user) { Text($0.p.user) }.width(min: 60, ideal: 90)
            TableColumn("CPU %", value: \.p.cpu) { Text(Fmt.pct($0.p.cpu)).monospacedDigit() }.width(60)
            TableColumn("Memory", value: \.p.memory) { r in
                let p = r.p
                Text(Fmt.bytes(p.memory)).monospacedDigit()
                    .help(p.memoryIsFootprint ? "Physical footprint (what Activity Monitor shows)" : "Resident size — footprint of other users' processes needs root")
            }.width(80)
            TableColumn("Energy", value: \.p.energyW) { r in
                let p = r.p
                Text(Fmt.watts(p.energyW, estimated: p.energyEstimated)).monospacedDigit()
                    .help(p.energyEstimated ? "Estimated from CPU time (other users' energy counters need root)" : "Measured by the kernel's per-process CPU energy counter (rusage)")
            }.width(80)
            TableColumn("Energy (5 min)", value: \.p.avgEnergyW) { r in
                Text(Fmt.watts(r.p.avgEnergyW, estimated: !r.p.isOwn)).monospacedDigit()
            }.width(95)
        }
        StatusBar(left: "\(rows.count) processes shown · updated \(monitor.updated.formatted(date: .omitted, time: .standard))",
                  right: "~ = estimated from CPU time",
                  rightHelp: "Energy for other users' processes is estimated as CPU cores × \(String(format: "%.2f", monitor.wattsPerCore)) W/core, calibrated from your own processes.")
    }
}

extension ProcSample {
    func matches(_ search: String) -> Bool {
        search.isEmpty || name.localizedCaseInsensitiveContains(search) || String(pid) == search || path.localizedCaseInsensitiveContains(search)
    }
}

/// A row of the Applications view: an app (with its processes as children) or one process.
struct AppRow: Identifiable {
    /// "g:<group id>" for apps, "p:<pid>" for processes.
    let id: String
    let name: String
    /// -1 for app rows, so they sort together and show no PID.
    let pid: Int32
    let count: Int
    let user: String
    let cpu: Double
    let memory: Int64
    let memoryEstimated: Bool
    let energyW: Double
    let energyEstimated: Bool
    let avgEnergyW: Double
    let avgEstimated: Bool
    let systemReasons: [String]
    var children: [AppRow]?

    init(_ g: AppGroup, children: [AppRow]) {
        id = "g:" + g.id; name = g.name; pid = -1; count = g.processes.count; user = g.user
        cpu = g.cpu; memory = g.memory; memoryEstimated = g.memoryEstimated
        energyW = g.energyW; energyEstimated = g.energyEstimated; avgEnergyW = g.avgEnergyW; avgEstimated = !g.allOwn
        systemReasons = g.isSystem ? ["every process in this group is a system process"] : []
        self.children = children
    }

    init(_ p: ProcSample) {
        id = "p:\(p.pid)"; name = p.name; pid = p.pid; count = 1; user = p.user
        cpu = p.cpu; memory = p.memory; memoryEstimated = !p.memoryIsFootprint
        energyW = p.energyW; energyEstimated = p.energyEstimated; avgEnergyW = p.avgEnergyW; avgEstimated = !p.isOwn
        systemReasons = p.systemReasons
    }

    static func pid(_ id: String) -> Int32? { id.hasPrefix("p:") ? Int32(id.dropFirst(2)) : nil }
    static func groupID(_ id: String) -> String? { id.hasPrefix("g:") ? String(id.dropFirst(2)) : nil }
}

/// Processes grouped by application (#34). Apps have stable IDs so expansion and selection survive re-sorts;
/// there are far fewer of them than processes, and children are only built when their app is expanded.
struct AppGroupsTable: View {
    @EnvironmentObject var monitor: MonitorStore
    @EnvironmentObject var settings: Settings
    let search: String
    @Binding var selection: AppRow.ID?
    @State private var sortOrder = [KeyPathComparator(\AppRow.cpu, order: .reverse)]

    var rows: [AppRow] {
        AppGrouping.group(monitor.processes).compactMap { g -> AppRow? in
            let nameHit = !search.isEmpty && g.name.localizedCaseInsensitiveContains(search)
            var shown = g
            shown.processes = g.processes.filter { (!settings.hideSystemProcesses || !$0.isSystem) && (nameHit || $0.matches(search)) }
            guard let first = shown.processes.first else { return nil }
            // A lone process outside any app bundle (most daemons) is just a process row.
            if shown.processes.count == 1 && g.bundlePath == nil { return AppRow(first) }
            return AppRow(shown, children: shown.processes.map(AppRow.init).sorted(using: sortOrder))
        }.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        Table(rows, children: \.children, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { r in
                HStack(spacing: 4) {
                    Text(r.name).lineLimit(1)
                    if r.pid < 0 { Text("\(r.count)").font(.caption).monospacedDigit().foregroundStyle(.secondary).help("\(r.count) processes") }
                    if !r.systemReasons.isEmpty { Image(systemName: "gearshape.fill").foregroundStyle(.tertiary).help("System: " + r.systemReasons.joined(separator: "; ")) }
                }
            }.width(min: 180, ideal: 240)
            TableColumn("PID", value: \.pid) { r in Text(r.pid < 0 ? "" : String(r.pid)).monospacedDigit() }.width(60)
            TableColumn("User", value: \.user) { Text($0.user) }.width(min: 60, ideal: 90)
            TableColumn("CPU %", value: \.cpu) { Text(Fmt.pct($0.cpu)).monospacedDigit() }.width(60)
            TableColumn("Memory", value: \.memory) { r in
                Text((r.memoryEstimated && r.memory >= 0 ? "~" : "") + Fmt.bytes(r.memory)).monospacedDigit()
                    .help(r.memoryEstimated ? "Includes resident size for other users' processes (their footprint needs root)" : "Physical footprint (what Activity Monitor shows)")
            }.width(85)
            TableColumn("Energy", value: \.energyW) { r in Text(Fmt.watts(r.energyW, estimated: r.energyEstimated)).monospacedDigit() }.width(80)
            TableColumn("Energy (5 min)", value: \.avgEnergyW) { r in Text(Fmt.watts(r.avgEnergyW, estimated: r.avgEstimated)).monospacedDigit() }.width(95)
        }
        StatusBar(left: "\(rows.filter { $0.pid < 0 }.count) apps · \(rows.reduce(0) { $0 + $1.count }) processes shown · updated \(monitor.updated.formatted(date: .omitted, time: .standard))",
                  right: "~ = estimated",
                  rightHelp: "App totals add up their processes. Memory is marked ~ when it includes other users' resident size; energy when it includes CPU-based estimates.")
    }
}

/// Totals for one app, plus a graceful Quit for running GUI apps. There is deliberately no force-kill of a whole group.
struct AppGroupDetailView: View {
    let id: String
    @EnvironmentObject var monitor: MonitorStore

    var body: some View {
        let gid = AppRow.groupID(id)
        if let g = AppGrouping.group(monitor.processes).first(where: { $0.id == gid }) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(g.name).font(.title3.bold()).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        row("Processes", "\(g.processes.count)")
                        row("User", g.user)
                        row("CPU", Fmt.pct(g.cpu) + " %")
                        row("Memory", (g.memoryEstimated ? "~" : "") + Fmt.bytes(g.memory) + (g.memoryEstimated ? " (includes resident size)" : " footprint"))
                        row("Energy", Fmt.watts(g.energyW, estimated: g.energyEstimated) + "  ·  5-min " + Fmt.watts(g.avgEnergyW, estimated: !g.allOwn))
                    }
                    if let b = g.bundlePath {
                        Panel(title: "Application", icon: "app") {
                            VStack(alignment: .leading) {
                                Text(b).font(.caption.monospaced()).textSelection(.enabled)
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: b)]) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Panel(title: "Heaviest processes", icon: "list.number") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(g.processes.sorted { $0.cpu > $1.cpu }.prefix(8), id: \.pid) { p in
                                HStack {
                                    Text(p.name).lineLimit(1).truncationMode(.middle)
                                    Spacer()
                                    Text(Fmt.pct(p.cpu) + " %").monospacedDigit().foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    QuitAppControls(group: g)
                }
                .padding()
            }
        } else {
            Text("This app has no running processes.").foregroundStyle(.secondary).padding()
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

/// "Quit App", like ⌘Q: asks the app to quit so it can save or prompt first. The app's main process still goes through
/// `ProcessControl.policy`, so MacLens itself, critical components and other users' apps are refused.
struct QuitAppControls: View {
    let group: AppGroup
    @State private var confirm = false
    @State private var info: String?

    var app: NSRunningApplication? {
        guard let b = group.bundlePath else { return nil }
        let want = URL(fileURLWithPath: b).resolvingSymlinksInPath().path
        return NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy != .prohibited && $0.bundleURL?.resolvingSymlinksInPath().path == want
        }
    }

    var body: some View {
        let app = self.app
        let main = app.flatMap { a in group.processes.first { $0.pid == a.processIdentifier } }
        let policy = main.map { ProcessControl.policy(pid: $0.pid, name: $0.name, uid: $0.uid, systemReasons: $0.systemReasons) }
        let refusal = app == nil ? "Not a running app with a menu or Dock icon. Stop individual processes from the list instead."
                                 : main == nil ? "The app's main process isn't in this group." : policy?.refusal
        VStack(alignment: .leading, spacing: 6) {
            Button("Quit App…") { confirm = true }
                .disabled(refusal != nil)
                .help(refusal ?? "Asks the app to quit, the same as choosing Quit from its menu (⌘Q).")
            if let refusal { Label(refusal, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            if case .warn(let w) = policy { Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if let info { Text(info).font(.caption).foregroundStyle(.orange) }
        }
        .alert("Quit \(group.name)?", isPresented: $confirm) {
            Button("Quit") {
                guard let app else { return }
                if app.terminate() {
                    info = "Asked \(group.name) to quit. It may ask you to save changes first."
                    DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                        if !app.isTerminated { info = "\(group.name) is still running. It may be waiting on a dialog." }
                    }
                } else {
                    info = "\(group.name) didn't accept the quit request."
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if case .warn(let w) = policy { Text("⚠️ \(w)") }
            else { Text("Same as choosing Quit from the app's menu (⌘Q). The app can save your work or ask you first.") }
        }
    }
}

struct RefreshPicker: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var model: AppModel
    var body: some View {
        Picker("Refresh every", selection: $settings.refreshInterval) {
            ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
        }
        .pickerStyle(.menu)
        .fixedSize()
        .help("Refresh interval while this window is visible")
        .onChange(of: settings.refreshInterval) { model.settingsChanged() }
    }
}

/// Filter row above a table: hide-system toggle (with its definition) and, optionally, the refresh interval.
struct FilterBar<Trailing: View>: View {
    @Binding var hideSystem: Bool
    let hiddenCount: Int
    let noun: String
    var showRefresh = false
    @ViewBuilder var trailing: Trailing

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Toggle("Hide system \(noun)", isOn: $hideSystem).toggleStyle(.checkbox)
                SystemDefinitionButton()
                if hideSystem && hiddenCount > 0 {
                    Text("\(hiddenCount) hidden").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                trailing
                if showRefresh { RefreshPicker() }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            Divider()
        }
    }
}

extension FilterBar where Trailing == EmptyView {
    init(hideSystem: Binding<Bool>, hiddenCount: Int, noun: String, showRefresh: Bool = false) {
        self.init(hideSystem: hideSystem, hiddenCount: hiddenCount, noun: noun, showRefresh: showRefresh) { EmptyView() }
    }
}

/// Status line below a table, on its own bar so rows never scroll underneath the text.
struct StatusBar: View {
    let left: String
    var right: String = ""
    var rightHelp: String = ""

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(left)
                Spacer()
                if !right.isEmpty { Text(right).help(rightHelp) }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .background(.bar)
    }
}

struct ProcessDetailView: View {
    let pid: Int32
    @EnvironmentObject var monitor: MonitorStore
    @EnvironmentObject var ports: PortsStore
    @EnvironmentObject var model: AppModel
    @State private var args: [String]?

    var body: some View {
        if let p = monitor.process(pid: pid) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(p.name).font(.title3.bold()).textSelection(.enabled)
                    Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                        row("PID", String(p.pid))
                        row("Parent", "\(p.ppid) \(monitor.process(pid: p.ppid)?.name ?? "")")
                        row("User", "\(p.user) (uid \(p.uid))")
                        row("Started", Fmt.date(p.startDate))
                        row("CPU", Fmt.pct(p.cpu) + " %  ·  5-min " + Fmt.pct(p.avgCPU) + " %")
                        row("Memory", Fmt.bytes(p.memory) + (p.memoryIsFootprint ? " footprint" : " resident"))
                        row("Energy", Fmt.watts(p.energyW, estimated: p.energyEstimated) + "  ·  5-min " + Fmt.watts(p.avgEnergyW, estimated: !p.isOwn))
                        if p.wakeupsPerSec >= 0 { row("Wakeups", String(format: "%.0f /s", p.wakeupsPerSec)) }
                        if p.isSystem { row("System", p.systemReasons.joined(separator: "\n")) }
                    }
                    Panel(title: "Executable", icon: "terminal") {
                        VStack(alignment: .leading) {
                            Text(p.path.isEmpty ? "unavailable" : p.path).font(.caption.monospaced()).textSelection(.enabled)
                            if !p.path.isEmpty {
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p.path)]) }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Panel(title: "Arguments", icon: "text.alignleft") {
                        Group {
                            if let args { Text(args.joined(separator: " ")).font(.caption.monospaced()).textSelection(.enabled) }
                            else { Text("Not visible without root (owned by \(p.user)).").foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Panel(title: "Listening ports", icon: "network") {
                        let mine = ports.rows.filter { $0.pid == pid }
                        Group {
                            if mine.isEmpty { Text("None").foregroundStyle(.secondary) }
                            ForEach(mine) { r in Text("\(r.proto) \(r.entry.address):\(r.port)").font(.caption.monospaced()) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    KillControls(process: p)
                }
                .padding()
            }
            .task(id: pid) {
                args = ProcList.arguments(pid: pid)
                model.refreshPortsNow()
            }
        } else {
            Text("Process \(pid) has exited.").foregroundStyle(.secondary).padding()
        }
    }

    @ViewBuilder private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }
}

/// Terminate / Force Kill with confirmation. Critical and other users' processes are refused; macOS components need an extra warning.
struct KillControls: View {
    let process: ProcSample
    @State private var pending: KillSignal?
    @State private var error: String?
    @State private var info: String?

    var policy: KillPolicy { ProcessControl.policy(pid: process.pid, name: process.name, uid: process.uid, systemReasons: process.systemReasons) }

    var body: some View {
        let policy = self.policy
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button("Terminate…") { pending = .terminate }
                Button("Force Kill…", role: .destructive) { pending = .forceKill }
            }
            .disabled(policy.isRefused)
            .help(policy.refusal ?? "SIGTERM asks the process to quit cleanly; SIGKILL stops it immediately without cleanup.")
            if let r = policy.refusal { Label(r, systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary) }
            if case .warn(let w) = policy { Label(w, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            if let info { Text(info).font(.caption).foregroundStyle(.orange) }
        }
        .alert(pending.map { "\($0.label): \(process.name)?" } ?? "", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button(policy.isWarn ? "Kill anyway" : (pending == .forceKill ? "Force Kill" : "Terminate"), role: .destructive) {
                if let s = pending {
                    error = ProcessControl.send(s, to: process.key, name: process.name, systemReasons: process.systemReasons, confirmedWarning: true)
                    info = nil
                    if error == nil && s == .terminate {
                        // SIGTERM first; if it's still alive shortly after, point at the explicit second step.
                        let key = process.key
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            if ProcList.basic(pid: key.pid)?.start == key.start {
                                info = "Still running 3 s after SIGTERM. Use Force Kill (SIGKILL) if it doesn't quit."
                            }
                        }
                    }
                }
                pending = nil
            }
            Button("Cancel", role: .cancel) { pending = nil }
        } message: {
            if case .warn(let w) = policy {
                Text("⚠️ \(w)\n\nPID \(process.pid) · \(process.path)")
            } else if pending == .forceKill {
                Text("SIGKILL stops PID \(process.pid) immediately; unsaved work is lost. Try Terminate first.")
            } else {
                Text("Sends SIGTERM to PID \(process.pid) so it can quit cleanly.")
            }
        }
    }
}

extension KillPolicy {
    var refusal: String? { if case .refused(let r) = self { return r }; return nil }
    var isRefused: Bool { refusal != nil }
    var isWarn: Bool { if case .warn = self { return true }; return false }
}
