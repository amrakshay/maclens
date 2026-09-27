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
    @State private var sortOrder = [KeyPathComparator(\ProcSample.cpu, order: .reverse)]
    @State private var selection: ProcSample.ID?
    @State private var search = ""

    var rows: [ProcSample] {
        monitor.processes.filter { p in
            (!settings.hideSystemProcesses || !p.isSystem) &&
            (search.isEmpty || p.name.localizedCaseInsensitiveContains(search) || String(p.pid) == search || p.path.localizedCaseInsensitiveContains(search))
        }.sorted(using: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
        FilterBar(hideSystem: $settings.hideSystemProcesses, hiddenCount: monitor.processes.filter(\.isSystem).count, noun: "processes", showRefresh: true)
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Name", value: \.name) { p in
                HStack(spacing: 4) {
                    Text(p.name).lineLimit(1)
                    if p.isSystem { Image(systemName: "gearshape.fill").foregroundStyle(.tertiary).help("System: " + p.systemReasons.joined(separator: "; ")) }
                }
            }.width(min: 160, ideal: 220)
            TableColumn("PID", value: \.pid) { Text(String($0.pid)).monospacedDigit() }.width(60)
            TableColumn("User", value: \.user) { Text($0.user) }.width(min: 60, ideal: 90)
            TableColumn("CPU %", value: \.cpu) { Text(Fmt.pct($0.cpu)).monospacedDigit() }.width(60)
            TableColumn("Memory", value: \.memory) { p in
                Text(Fmt.bytes(p.memory)).monospacedDigit()
                    .help(p.memoryIsFootprint ? "Physical footprint (what Activity Monitor shows)" : "Resident size — footprint of other users' processes needs root")
            }.width(80)
            TableColumn("Energy", value: \.energyW) { p in
                Text(Fmt.watts(p.energyW, estimated: p.energyEstimated)).monospacedDigit()
                    .help(p.energyEstimated ? "Estimated from CPU time (other users' energy counters need root)" : "Measured by the kernel's per-process CPU energy counter (rusage)")
            }.width(80)
            TableColumn("Energy (5 min)", value: \.avgEnergyW) { p in
                Text(Fmt.watts(p.avgEnergyW, estimated: !p.isOwn)).monospacedDigit()
            }.width(95)
        }
        StatusBar(left: "\(rows.count) processes shown · updated \(monitor.updated.formatted(date: .omitted, time: .standard))",
                  right: "~ = estimated from CPU time",
                  rightHelp: "Energy for other users' processes is estimated as CPU cores × \(String(format: "%.2f", monitor.wattsPerCore)) W/core, calibrated from your own processes.")
        }
        .searchable(text: $search, prompt: "Name, PID or path")
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let pid = selection { ProcessDetailView(pid: pid).inspectorColumnWidth(min: 300, ideal: 340) }
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
