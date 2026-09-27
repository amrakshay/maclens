import AppKit
import SwiftUI
import MacLensCore

struct CaffeinateInstance: Identifiable, Equatable {
    var id: ProcKey { key }
    let key: ProcKey
    let args: String
    let started: Date
    let startedByMacLens: Bool
    var preventsDisplaySleep: Bool { args.contains("d") }
}

/// Tracks every running `caffeinate` (MacLens's own and any you started elsewhere) and starts/stops MacLens's `caffeinate -d`.
@MainActor final class SleepStore: ObservableObject {
    @Published private(set) var running: [CaffeinateInstance] = []
    @Published var lastError: String?
    private var children: [ProcKey: Process] = [:]
    private var argsCache: [ProcKey: String] = [:]
    /// Instances MacLens started, persisted so they're still labelled correctly after a relaunch.
    private var ours: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "caffeinateStartedByMacLens") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "caffeinateStartedByMacLens") }
    }
    private static func tag(_ k: ProcKey) -> String { "\(k.pid):\(k.start)" }

    var isActive: Bool { !running.isEmpty }
    var external: [CaffeinateInstance] { running.filter { !$0.startedByMacLens } }

    /// Called on every sample with the full process list (works while the window is closed too).
    func update(from processes: [ProcSample]) {
        let mine = processes.filter { $0.path == Caffeinate.path && $0.isOwn }
        let tags = ours
        let now = mine.map { p -> CaffeinateInstance in
            let args = argsCache[p.key] ?? {
                let a = (ProcList.arguments(pid: p.pid) ?? ["caffeinate"]).joined(separator: " ")
                argsCache[p.key] = a
                return a
            }()
            return CaffeinateInstance(key: p.key, args: args, started: p.startDate, startedByMacLens: tags.contains(Self.tag(p.key)))
        }.sorted { $0.started < $1.started }
        if now != running { running = now }
        // Forget instances that have exited.
        let alive = Set(mine.map(\.key))
        ours = tags.filter { t in alive.contains { Self.tag($0) == t } }
        children = children.filter { alive.contains($0.key) || $0.value.isRunning }
        argsCache = argsCache.filter { alive.contains($0.key) }
    }

    func preventSleep() {
        do {
            let (p, key) = try Caffeinate.start()
            children[key] = p
            ours.insert(Self.tag(key))
            running.append(CaffeinateInstance(key: key, args: "caffeinate -d", started: Date(), startedByMacLens: true))
            lastError = nil
        } catch {
            lastError = "Couldn't start caffeinate: \(error.localizedDescription)"
        }
    }

    /// Stops every running caffeinate so the Mac sleeps normally again.
    func allowSleep() {
        var errors: [String] = []
        for c in running {
            if let e = Caffeinate.stop(c.key) { errors.append("PID \(c.key.pid): \(e)") }
        }
        lastError = errors.isEmpty ? nil : errors.joined(separator: "\n")
        running.removeAll { r in !errors.contains { $0.hasPrefix("PID \(r.key.pid):") } }
    }
}

/// Dashboard control: one button to keep the Mac awake (`caffeinate -d`) and to let it sleep again.
struct SleepControlBar: View {
    @EnvironmentObject var sleep: SleepStore
    @State private var confirmStopExternal = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: sleep.isActive ? "cup.and.saucer.fill" : "moon.zzz")
                .font(.title2)
                .foregroundStyle(sleep.isActive ? VizColor.warning : .secondary)
                .frame(width: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(sleep.isActive ? "Keeping your Mac awake" : "Your Mac sleeps normally").font(.headline)
                if sleep.running.isEmpty {
                    Text("Prevent sleep runs caffeinate -d: the display and system stay awake until you allow sleep again. It keeps running if you quit MacLens.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(sleep.running) { c in
                        Text("\(c.args) · PID \(c.key.pid) · since \(Fmt.relative(c.started)) · " +
                             (c.startedByMacLens ? "started by MacLens" : "started outside MacLens"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let e = sleep.lastError { Text(e).font(.caption).foregroundStyle(VizColor.critical) }
            }
            Spacer()
            if sleep.isActive {
                Button("Allow sleep") {
                    if sleep.external.isEmpty { sleep.allowSleep() } else { confirmStopExternal = true }
                }
                .controlSize(.large)
                .help("Stops caffeinate so macOS can sleep on its normal schedule")
            } else {
                Button("Prevent sleep") { sleep.preventSleep() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .help("Runs caffeinate -d")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(sleep.isActive ? VizColor.warning.opacity(0.12) : Color.secondary.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(sleep.isActive ? VizColor.warning.opacity(0.6) : .clear))
        .alert("Stop caffeinate started outside MacLens?", isPresented: $confirmStopExternal) {
            Button("Stop all and allow sleep", role: .destructive) { sleep.allowSleep() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(sleep.external.map { "PID \($0.key.pid): \($0.args) (since \(Fmt.relative($0.started)))" }.joined(separator: "\n") +
                 "\n\nWhatever started it (a script or terminal) may expect it to keep running.")
        }
    }
}
