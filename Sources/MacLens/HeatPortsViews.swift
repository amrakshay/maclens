import AppKit
import SwiftUI
import MacLensCore

/// Titled panel. (Used instead of GroupBox so the layer-based --snapshot capture renders it.)
struct Panel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content
        }
        .padding(10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
    }
}

typealias Card = Panel

/// "Why is it hot / why is the battery draining?"
struct HeatView: View {
    @EnvironmentObject var settings: Settings

    @EnvironmentObject var monitor: MonitorStore

    var body: some View {
        VStack(spacing: 0) {
            FilterBar(hideSystem: $settings.hideSystemHeat, hiddenCount: monitor.processes.filter(\.isSystem).count, noun: "processes", showRefresh: true)
            ScrollView { HeatContent() }
        }
    }
}

/// Maximum capacity, condition and cycles — the figures System Settings → Battery → Battery Health shows.
struct BatteryHealthSummary: View {
    let health: BatteryHealth?

    var body: some View {
        if let h = health {
            Text(h.maximumCapacityPercent.map { "\($0)%" } ?? "—").font(.title2.bold().monospacedDigit())
            Text("maximum capacity").font(.caption).foregroundStyle(.secondary)
            if let c = h.condition {
                Label(c, systemImage: h.needsService ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(h.needsService ? VizColor.serious : VizColor.good)
                    .font(.callout)
            }
            if let n = h.cycleCount {
                Text("\(n) cycles" + (h.designCycleCount.map { " of \($0) rated" } ?? "")).font(.caption)
            }
            if let f = h.fullChargeCapacity_mAh, let d = h.designCapacity_mAh {
                Text("Full charge \(f) mAh · design \(d) mAh").font(.caption).foregroundStyle(.secondary)
                    .help("Raw gauge values. System Settings' percentage comes from Apple's own health model, so it differs from this ratio.")
            }
        } else {
            Text("Reading…").foregroundStyle(.secondary)
        }
    }
}

struct HeatContent: View {
    @EnvironmentObject var monitor: MonitorStore
    @EnvironmentObject var settings: Settings
    @State private var byAverage = true

    var offenders: [ProcSample] {
        monitor.processes.filter { p in p.pid != 0 && (!settings.hideSystemHeat || !p.isSystem) }
            .sorted { byAverage ? $0.avgEnergyW > $1.avgEnergyW : $0.energyW > $1.energyW }
            .prefix(15).map { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) { // cards share the tallest card's height (see fixedSize below)
                    Card(title: "Thermal state", icon: monitor.thermalState.symbol) {
                        Text(monitor.thermalState.label).font(.title2.bold()).foregroundStyle(monitor.thermalState.color)
                        Text(monitor.thermalState.explanation).font(.caption).foregroundStyle(.secondary)
                    }
                    Card(title: "Power", icon: "bolt.fill") {
                        let b = monitor.battery
                        Text(b.systemLoadW.map { String(format: "%.1f W", $0) } ?? "—").font(.title2.bold().monospacedDigit())
                        Text("whole-system draw").font(.caption).foregroundStyle(.secondary)
                        if b.hasBattery {
                            Text("\(b.percent ?? 0)% · " + (b.isCharging ? "charging" : b.onAC ? "on power adapter" : "on battery"))
                            if let w = b.batteryW, abs(w) >= 0.1 { Text(String(format: w < 0 ? "Battery draining %.1f W" : "Battery charging at %.1f W", abs(w))).font(.caption) }
                            if let a = b.adapterW { Text(String(format: "Adapter supplying %.1f W", a)).font(.caption).foregroundStyle(.secondary) }
                            if let m = b.minutesRemaining { Text("\(Fmt.minutes(m)) \(b.isCharging ? "to full" : "remaining")").font(.caption) }
                        }
                    }
                    if monitor.battery.hasBattery {
                        Card(title: "Battery health", icon: "battery.100percent") {
                            BatteryHealthSummary(health: monitor.batteryHealth)
                        }
                    }
                    Card(title: "Temperatures", icon: "thermometer.variable") {
                        if let t = monitor.thermal {
                            Text(t.cpuMaxC.map { String(format: "CPU %.0f °C", $0) } ?? "CPU —").font(.title2.bold().monospacedDigit())
                            if let a = t.cpuAvgC { Text(String(format: "avg %.0f °C across dies", a)).font(.caption).foregroundStyle(.secondary) }
                            if let b = t.batteryC { Text(String(format: "Battery %.0f °C", b)).font(.caption) }
                            if let s = t.ssdC { Text(String(format: "SSD %.0f °C", s)).font(.caption) }
                        } else { Text("Reading sensors…").foregroundStyle(.secondary) }
                    }
                    Card(title: "Fans", icon: "fan") {
                        if let f = monitor.thermal?.fanRPMs, !f.isEmpty {
                            ForEach(Array(f.enumerated()), id: \.offset) { i, r in Text("Fan \(i + 1): \(Int(r)) rpm").monospacedDigit() }
                        } else { Text(monitor.thermal == nil ? "—" : "No fans / idle").foregroundStyle(.secondary) }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                Panel(title: "Top energy users", icon: "flame") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Picker("Rank by", selection: $byAverage) {
                                Text("5-minute average").tag(true)
                                Text("Right now").tag(false)
                            }.pickerStyle(.segmented).frame(width: 280)
                            Spacer()
                            if monitor.preciseRunning { ProgressView().controlSize(.small) }
                            Button("Precise sample") { monitor.runPreciseSample() }
                                .disabled(monitor.preciseRunning)
                                .help("Runs /usr/bin/top once (~1 s of CPU) to get Apple's energy-impact score for every process, including root's.")
                        }
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                            GridRow {
                                ForEach(["Process", "Energy now", "Energy 5 min", "CPU now", "CPU 5 min", "Wakeups/s", "top POWER"], id: \.self) {
                                    Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                }
                            }
                            Divider().gridCellUnsizedAxes(.horizontal)
                            ForEach(offenders, id: \.key) { p in
                                GridRow {
                                    HStack(spacing: 4) {
                                        Text(p.name).lineLimit(1).truncationMode(.middle)
                                        if p.isSystem { Image(systemName: "gearshape.fill").foregroundStyle(.tertiary).help("System: " + p.systemReasons.joined(separator: "; ")) }
                                    }
                                    .frame(minWidth: 180, maxWidth: 300, alignment: .leading)
                                    Text(Fmt.watts(p.energyW, estimated: p.energyEstimated))
                                    Text(Fmt.watts(p.avgEnergyW, estimated: !p.isOwn)).bold()
                                    Text(Fmt.pct(p.cpu) + " %")
                                    Text(Fmt.pct(p.avgCPU) + " %")
                                    Text(p.wakeupsPerSec < 0 ? "—" : String(format: "%.0f", p.wakeupsPerSec))
                                    Text(monitor.precise[p.pid].map { String(format: "%.1f", $0) } ?? "—")
                                }
                                .monospacedDigit()
                            }
                        }
                        Text("macOS has no per-process heat metric. This ranks processes by energy: measured by the kernel's per-process CPU energy counter for your own processes; for other users' (root, _system) it's estimated as CPU time × \(String(format: "%.2f", monitor.wattsPerCore)) W/core, calibrated from your processes (\"~\"). \"Precise sample\" asks /usr/bin/top, which has Apple's entitlement to read every process." + (monitor.preciseDate.map { " Last precise sample: \(Fmt.relative($0))." } ?? ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }

                Panel(title: "Keeping your Mac awake (power assertions)", icon: "moon.zzz") {
                    VStack(alignment: .leading, spacing: 6) {
                        if monitor.assertions.isEmpty { Text("No power assertions.").foregroundStyle(.secondary) }
                        ForEach(monitor.assertions) { a in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: a.preventsSleep ? "moon.zzz.fill" : "circle.dotted").foregroundStyle(a.preventsSleep ? .orange : .secondary)
                                Text(a.processName).bold()
                                Text(AssertionText.friendly(a.type))
                                Text(a.name).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Text("PID \(a.pid)").foregroundStyle(.secondary).monospacedDigit()
                                if let s = a.since { Text(Fmt.relative(s)).foregroundStyle(.secondary) }
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
        }
        .padding()
    }
}

struct PortsView: View {
    @EnvironmentObject var ports: PortsStore
    @EnvironmentObject var monitor: MonitorStore
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var model: AppModel
    @State private var search = ""
    @State private var sortOrder = [KeyPathComparator(\PositionRow<PortRow>.item.port)]
    @State private var selection: PortRow.ID?
    @State private var freePort = ""

    var rows: [PositionRow<PortRow>] {
        PositionRow.sorted(ports.rows.filter { r in
            (!settings.hideSystemPorts || !r.isSystem) &&
            (search.isEmpty || String(r.port).contains(search) || r.processName.localizedCaseInsensitiveContains(search) ||
             String(r.pid) == search || r.path.localizedCaseInsensitiveContains(search) || r.user.localizedCaseInsensitiveContains(search))
        }, by: sortOrder)
    }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            FilterBar(hideSystem: $settings.hideSystemPorts, hiddenCount: ports.rows.filter(\.isSystem).count, noun: "ports") {
                Button { model.refreshPortsNow() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Refresh now (the list also refreshes automatically)")
            }
            FreePortBar(freePort: $freePort)
            Divider()
            Table(rows, selection: rows.selection($selection), sortOrder: $sortOrder) {
                TableColumn("Port", value: \.item.port) { Text(String($0.item.port)).monospacedDigit() }.width(60)
                TableColumn("Proto", value: \.item.proto) { r in Text("\(r.item.proto) \(r.item.entry.family)") }.width(90)
                TableColumn("Address", value: \.item.entry.address) { Text($0.item.entry.address == "*" ? "all interfaces" : $0.item.entry.address) }.width(min: 90, ideal: 120)
                TableColumn("PID", value: \.item.pid) { Text(String($0.item.pid)).monospacedDigit() }.width(60)
                TableColumn("Process", value: \.item.processName) { r in
                    HStack(spacing: 4) { Text(r.item.processName); if r.item.isSystem { Image(systemName: "gearshape.fill").foregroundStyle(.tertiary) } }
                }.width(min: 120, ideal: 160)
                TableColumn("User", value: \.item.user) { Text($0.item.user) }.width(80)
                TableColumn("Path", value: \.item.path) { Text($0.item.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help($0.item.path) }
            }
            StatusBar(left: "\(rows.count) listening sockets shown" + (ports.updated.map { " · updated \($0.formatted(date: .omitted, time: .standard))" } ?? ""),
                      right: "TCP in LISTEN state and bound UDP sockets, for all users (no root needed)")
        }
        .searchable(text: $search, prompt: "Port, process, PID, user or path")
        .inspector(isPresented: Binding(get: { selection != nil }, set: { if !$0 { selection = nil } })) {
            if let id = selection, let r = ports.rows.first(where: { $0.id == id }) {
                ProcessDetailView(pid: r.pid).inspectorColumnWidth(min: 300, ideal: 340)
            }
        }
        .onAppear { model.refreshPortsNow() }
    }
}

/// Extra 4: "who is on port N?" → terminate in one step.
struct FreePortBar: View {
    @Binding var freePort: String
    @EnvironmentObject var ports: PortsStore
    @EnvironmentObject var monitor: MonitorStore
    @EnvironmentObject var model: AppModel

    var owners: [PortRow] {
        guard let n = Int(freePort) else { return [] }
        var seen = Set<Int32>()
        return ports.rows.filter { $0.port == n && seen.insert($0.pid).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Free a port", systemImage: "bolt.horizontal.circle")
                TextField("e.g. 3000", text: $freePort).frame(width: 90).textFieldStyle(.roundedBorder)
                    .onSubmit { model.refreshPortsNow() }
                if Int(freePort) != nil && owners.isEmpty { Text("Nothing is listening on \(freePort).").foregroundStyle(.secondary) }
                Spacer()
            }
            ForEach(owners) { r in
                HStack(alignment: .top) {
                    Text("\(r.processName) (PID \(r.pid), \(r.user))").bold()
                    if let p = monitor.process(pid: r.pid) { KillControls(process: p) }
                    else { Text("Open the Processes tab once to load details.").foregroundStyle(.secondary) }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }
}
