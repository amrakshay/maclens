import AppKit
import SwiftUI
import MacLensCore

/// Status and start/stop for optional services (VoiceMode today). Updated only while the tab is visible:
/// state comes from the sampler's port scan, and the service CLI runs only when the user clicks something.
@MainActor final class ServicesStore: ObservableObject {
    struct Row: Identifiable, Equatable {
        var id: String { component.id }
        let component: VoiceMode.Component
        var state: ServiceState
        var startsAtLogin: Bool
        var cpu: Double = -1
        var memory: Int64 = -1
    }
    struct Message: Equatable { let ok: Bool; let text: String }

    @Published private(set) var executable: String?
    @Published private(set) var rows: [Row] = []
    @Published private(set) var busy: [String: VoiceMode.Action] = [:]
    /// Components started from here that aren't listening yet (Kokoro takes ~10 s to load its model).
    @Published private(set) var starting: [String: Date] = [:]
    @Published private(set) var messages: [String: Message] = [:]
    @Published private(set) var updated: Date?
    /// Asks the sampler for a fresh port scan so a start/stop shows up right away.
    var refreshPorts: (() -> Void)?
    private var lastPorts: [PortEntry] = []
    private var lastProcesses: [ProcSample] = []

    init() { refreshInstall() }

    var installed: Bool { executable != nil }
    var anyBusy: Bool { !busy.isEmpty }

    /// Re-checks the CLI and install markers (cheap file-existence checks).
    func refreshInstall() {
        executable = VoiceMode.locate()
        recompute()
    }

    func update(ports: [PortEntry], processes: [ProcSample]) {
        lastPorts = ports
        lastProcesses = processes
        recompute()
        updated = Date()
    }

    private func recompute() {
        var byPid: [Int32: ProcSample] = [:]
        for p in lastProcesses { byPid[p.pid] = p }
        let hasCLI = executable != nil
        let listeners = lastPorts
        let new = VoiceMode.components.map { c -> Row in
            let installed = hasCLI && VoiceMode.isInstalled(c)
            let s = VoiceMode.state(of: c, installed: installed, listeners: listeners,
                                    arguments: { ProcList.arguments(pid: $0) },
                                    name: { byPid[$0]?.name ?? ProcList.path(pid: $0).map(PathUtil.lastComponent) ?? "PID \($0)" })
            var r = Row(component: c, state: s, startsAtLogin: VoiceMode.startsAtLogin(c))
            if case .running(let pid) = s, let p = byPid[pid] { r.cpu = p.cpu; r.memory = p.memory }
            return r
        }
        for r in new where r.state.isRunning || Date().timeIntervalSince(starting[r.id] ?? .distantPast) > 120 {
            if starting[r.id] != nil { starting[r.id] = nil }
        }
        if new != rows { rows = new }
    }

    func isStarting(_ id: String) -> Bool { starting[id] != nil }

    func perform(_ action: VoiceMode.Action, _ ids: [String]) {
        guard let exe = executable else { return }
        let comps = VoiceMode.components.filter { ids.contains($0.id) && busy[$0.id] == nil }
        guard !comps.isEmpty else { return }
        for c in comps { busy[c.id] = action; messages[c.id] = nil }
        Task.detached(priority: .userInitiated) {
            for c in comps {
                let r = VoiceMode.run(action, c, executable: exe)
                await MainActor.run {
                    self.busy[c.id] = nil
                    self.messages[c.id] = Message(ok: r.ok, text: r.output.isEmpty ? (r.ok ? "Done." : "Failed with no output.") : r.output)
                    if action == .start && r.ok { self.starting[c.id] = Date() }
                    if action == .stop { self.starting[c.id] = nil }
                    self.recompute()
                    self.refreshPorts?()
                }
            }
        }
    }
}

struct ServicesView: View {
    @EnvironmentObject var services: ServicesStore
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Optional background services you can run only when you need them, to save memory and CPU. MacLens starts and stops them with their own command-line tools, as you (no root).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    VoiceModePanel()
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            StatusBar(left: services.updated.map { "Updated \($0.formatted(date: .omitted, time: .standard))" } ?? "Checking…",
                      right: "Status comes from listening ports; the service CLI runs only when you click")
        }
        .onAppear { services.refreshInstall(); model.refreshPortsNow() }
    }
}

struct VoiceModePanel: View {
    @EnvironmentObject var services: ServicesStore
    @EnvironmentObject var model: AppModel

    private var available: [ServicesStore.Row] { services.rows.filter { $0.state != .notInstalled } }

    var body: some View {
        Panel(title: "VoiceMode", icon: "waveform") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Local speech-to-text and text-to-speech for voice conversations with Claude Code.")
                    Spacer()
                    if services.installed {
                        Button("Start all") { act(.start, available.filter { !$0.state.isRunning }) }
                            .disabled(services.anyBusy || available.allSatisfy { $0.state.isRunning || services.isStarting($0.id) })
                        Button("Stop all") { act(.stop, available.filter { $0.state.isRunning || services.isStarting($0.id) }) }
                            .disabled(services.anyBusy || !available.contains { $0.state.isRunning || services.isStarting($0.id) })
                    }
                }
                if let exe = services.executable {
                    Text("Using \(PathUtil.abbreviate(exe))").font(.caption).foregroundStyle(.secondary)
                } else {
                    NotInstalledWarning()
                }
                ForEach(services.rows) { r in
                    Divider()
                    ServiceRow(row: r).disabled(!services.installed)
                }
            }
        }
    }

    private func act(_ a: VoiceMode.Action, _ rows: [ServicesStore.Row]) {
        services.perform(a, rows.map(\.id))
    }
}

struct NotInstalledWarning: View {
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
            VStack(alignment: .leading, spacing: 4) {
                Text("VoiceMode isn't installed").font(.headline)
                Text("MacLens couldn't find the `voicemode` command in ~/.local/bin, /opt/homebrew/bin, /usr/local/bin or your PATH. Install it by following VoiceMode's instructions, install the services you want (for example `voicemode service install kokoro`), then come back to this tab.")
                    .fixedSize(horizontal: false, vertical: true)
                Link("VoiceMode on GitHub", destination: URL(string: "https://github.com/mbailey/voicemode")!)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.12)))
    }
}

struct ServiceRow: View {
    let row: ServicesStore.Row
    @EnvironmentObject var services: ServicesStore
    @EnvironmentObject var model: AppModel

    private var c: VoiceMode.Component { row.component }
    private var busy: VoiceMode.Action? { services.busy[c.id] }
    private var starting: Bool { services.isStarting(c.id) && !row.state.isRunning }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(dotColor).frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.title).font(.headline)
                    Text("\(c.summary) · port \(String(c.port))").font(.caption).foregroundStyle(.secondary)
                }
                .frame(width: 230, alignment: .leading)
                statusText.frame(minWidth: 220, alignment: .leading)
                Spacer()
                controls
            }
            if let m = services.messages[c.id] {
                Text(m.text)
                    .font(.caption.monospaced())
                    .foregroundStyle(m.ok ? Color.secondary : Color.red)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 19)
            }
        }
        .padding(.vertical, 2)
    }

    private var dotColor: Color {
        switch row.state {
        case .running: return .green
        case .portInUse: return .orange
        case .stopped: return starting ? .yellow : .secondary
        case .notInstalled: return .secondary.opacity(0.4)
        }
    }

    @ViewBuilder private var statusText: some View {
        switch row.state {
        case .running(let pid):
            VStack(alignment: .leading, spacing: 1) {
                Text("Running").foregroundStyle(.green)
                Text("PID \(String(pid)) · \(Fmt.pct(row.cpu))% CPU · \(Fmt.bytes(row.memory))")
                    .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    .help("CPU and memory of the process listening on the port")
            }
        case .portInUse(let pid, let name):
            Text("Port \(String(c.port)) is used by \(name) (PID \(String(pid)))").foregroundStyle(.orange)
        case .stopped:
            if starting { HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Starting… (loading the model)") } }
            else { Text("Stopped").foregroundStyle(.secondary) }
        case .notInstalled:
            Text(services.installed ? "Not installed — voicemode service install \(c.id)" : "Not installed")
                .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }

    @ViewBuilder private var controls: some View {
        if row.state != .notInstalled {
            HStack(spacing: 12) {
                Toggle("Start at login", isOn: Binding(get: { row.startsAtLogin },
                                                       set: { services.perform($0 ? .enable : .disable, [c.id]) }))
                    .toggleStyle(.checkbox)
                    .help("voicemode service enable/disable: installs or removes a LaunchAgent so launchd starts it at every login")
                    .disabled(busy != nil)
                if let busy {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text(busy == .stop ? "Stopping…" : "Working…") }
                        .frame(width: 90)
                } else if row.state.isRunning || starting {
                    Button("Stop") { services.perform(.stop, [c.id]) }.frame(width: 90)
                } else {
                    Button("Start") { services.perform(.start, [c.id]) }
                        .frame(width: 90)
                        .disabled({ if case .portInUse = row.state { return true }; return false }())
                }
            }
        }
    }
}
