import AppKit
import SwiftUI
import Charts
import MacLensCore

/// Chart colors from the validated reference palette (light/dark steps), plus the reserved status palette.
enum VizColor {
    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: 1)
        })
    }
    static let series1 = dynamic(light: 0x2a78d6, dark: 0x3987e5) // blue
    static let series2 = dynamic(light: 0xeb6834, dark: 0xd95926) // orange
    static let series3 = dynamic(light: 0x1baf7a, dark: 0x199e70) // aqua (sub-3:1 on light → always direct-labeled)
    static let good = dynamic(light: 0x0ca30c, dark: 0x0ca30c)
    static let warning = dynamic(light: 0xfab219, dark: 0xfab219)
    static let serious = dynamic(light: 0xec835a, dark: 0xec835a)
    static let critical = dynamic(light: 0xd03b3b, dark: 0xd03b3b)

    static func status(_ t: ProcessInfo.ThermalState) -> Color {
        switch t {
        case .nominal: return good
        case .fair: return warning
        case .serious: return serious
        case .critical: return critical
        @unknown default: return .gray
        }
    }
}

struct DashboardView: View {
    var body: some View {
        ScrollView { DashboardContent() }
    }
}

struct DashboardContent: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var monitor: MonitorStore
    @EnvironmentObject var history: HistoryStore
    @EnvironmentObject var ports: PortsStore
    @EnvironmentObject var artifacts: ArtifactStore
    @State private var range: Double = 15

    var points: [HistoryPoint] {
        let cutoff = Date().addingTimeInterval(-range * 60)
        return history.points.filter { $0.date >= cutoff }
    }

    var body: some View {
        let pts = points
        VStack(alignment: .leading, spacing: 14) {
            UpdateBanner()
            kpiRow(pts)
            SleepControlBar()

            HStack {
                Text("Trends").font(.headline)
                Spacer()
                Picker("Range", selection: $range) {
                    Text("5 min").tag(5.0)
                    Text("15 min").tag(15.0)
                    Text("30 min").tag(30.0)
                }
                .pickerStyle(.segmented).frame(width: 240)
            }
            Text("History is kept for 30 minutes while MacLens runs (it starts empty at launch).")
                .font(.caption).foregroundStyle(.secondary)

            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14), GridItem(.flexible(), spacing: 14)], spacing: 14) {
                TrendChart(title: "System power", unit: "W", points: pts, value: \.powerW, color: VizColor.series1, format: "%.1f W")
                TrendChart(title: "CPU load (all cores)", unit: "%", points: pts, value: \.cpuPct, color: VizColor.series1, format: "%.0f %%", yMax: 100)
                TrendChart(title: "Memory used", unit: "GB", points: pts, value: \.memUsedGB, color: VizColor.series1, format: "%.1f GB",
                           yMax: history.memory.map { Double($0.total) / 1e9 })
                TrendChart(title: "CPU temperature (hottest die)", unit: "°C", points: pts, value: \.cpuTempC, color: VizColor.series1, format: "%.0f °C")
            }

            HStack(alignment: .top, spacing: 14) {
                TopEnergyChart(processes: monitor.processes)
                ReclaimableChart(result: artifacts.result, disk: history.disk) { model.tab = .artifacts }
            }

            HStack(alignment: .top, spacing: 14) {
                Panel(title: "Keeping your Mac awake", icon: "moon.zzz") {
                    let blockers = monitor.assertions.filter(\.preventsSleep)
                    if blockers.isEmpty { Text("Nothing is preventing sleep.").foregroundStyle(.secondary) }
                    ForEach(blockers.prefix(5)) { a in
                        HStack {
                            Image(systemName: "moon.zzz.fill").foregroundStyle(.orange)
                            Text(a.processName).bold()
                            Text(AssertionText.friendly(a.type)).foregroundStyle(.secondary)
                            Spacer()
                            if let s = a.since { Text(Fmt.relative(s)).foregroundStyle(.secondary) }
                        }
                    }
                    Button("Details in Heat & Battery →") { model.tab = .heat }.buttonStyle(.link)
                }
                Panel(title: "Listening ports", icon: "network") {
                    let user = ports.rows.filter { !$0.isSystem }
                    Text("\(ports.rows.count) sockets · \(user.count) from your apps").font(.title3.bold())
                    ForEach(Array(user.sorted { $0.port < $1.port }.prefix(5))) { r in
                        HStack {
                            Text(String(r.port)).monospacedDigit().frame(width: 60, alignment: .leading)
                            Text(r.processName)
                            Spacer()
                            Text(r.proto).foregroundStyle(.secondary)
                        }
                    }
                    Button("All ports →") { model.tab = .ports }.buttonStyle(.link)
                }
            }
        }
        .padding()
        .onAppear { history.flush() }
    }

    @ViewBuilder private func kpiRow(_ pts: [HistoryPoint]) -> some View {
        let b = monitor.battery
        let tiles = b.hasBattery ? 7 : 5
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(minimum: 110), spacing: 10), count: tiles), spacing: 10) {
            StatTile(title: "Thermal", value: monitor.thermalState.label, detail: monitor.thermalState.explanation,
                     icon: monitor.thermalState.symbol, statusColor: VizColor.status(monitor.thermalState))
            StatTile(title: "Power", value: b.systemLoadW.map { String(format: "%.1f W", $0) } ?? "—",
                     detail: b.hasBattery ? (b.isCharging ? "charging" : b.onAC ? "on adapter" : "on battery") : "whole system",
                     spark: pts.compactMap(\.powerW))
            StatTile(title: "CPU", value: pts.last?.cpuPct.map { String(format: "%.0f %%", $0) } ?? "—",
                     detail: "\(ProcessInfo.processInfo.activeProcessorCount) cores", spark: pts.compactMap(\.cpuPct))
            StatTile(title: "Memory", value: history.memory.map { Fmt.bytes($0.used) } ?? "—",
                     detail: history.memory.map { "of \(Fmt.bytes($0.total))" + ($0.swapUsed > 0 ? " · swap \(Fmt.bytes($0.swapUsed))" : "") } ?? "",
                     spark: pts.compactMap(\.memUsedGB))
            StatTile(title: "CPU temp", value: history.thermal?.cpuMaxC.map { String(format: "%.0f °C", $0) } ?? "—",
                     detail: history.thermal.map { t in t.fanRPMs.isEmpty ? "fans idle" : t.fanRPMs.map { "\(Int($0))" }.joined(separator: " / ") + " rpm" } ?? "",
                     spark: pts.compactMap(\.cpuTempC))
            StatTile(title: "Battery", value: b.hasBattery ? "\(b.percent ?? 0)%" : "—",
                     detail: b.minutesRemaining.map { "\(Fmt.minutes($0)) \(b.isCharging ? "to full" : "left")" } ?? (b.hasBattery ? "" : "no battery"))
            if b.hasBattery {
                let h = monitor.batteryHealth
                StatTile(title: "Battery health", value: h?.maximumCapacityPercent.map { "\($0)%" } ?? "—",
                         detail: [h?.condition, h?.cycleCount.map { "\($0) cycles" }].compactMap { $0 }.joined(separator: " · "),
                         icon: h?.condition == nil ? nil : (h!.needsService ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"),
                         statusColor: h?.condition == nil ? nil : (h!.needsService ? VizColor.serious : VizColor.good))
            }
        }
    }
}

/// Headline number with an optional sparkline (no axes) or a status color that always comes with an icon + label.
struct StatTile: View {
    let title: String
    let value: String
    var detail: String = ""
    var icon: String? = nil
    var statusColor: Color? = nil
    var spark: [Double] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).foregroundStyle(statusColor ?? .primary) }
                Text(value).font(.title2.bold().monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            }
            Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            if spark.count >= 2 {
                Sparkline(values: spark).stroke(VizColor.series1, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .frame(height: 26)
            } else {
                Spacer().frame(height: 26)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))
        .overlay(alignment: .leading) {
            if let statusColor { RoundedRectangle(cornerRadius: 2).fill(statusColor).frame(width: 3).padding(.vertical, 8) }
        }
    }
}

/// Axis-less trend line drawn as a plain Path (much lighter than a Chart for a 26 pt sparkline).
struct Sparkline: Shape {
    let values: [Double]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        guard values.count >= 2, let lo = values.min(), let hi = values.max() else { return p }
        let span = max(hi - lo, 1e-9)
        for (i, v) in values.enumerated() {
            let pt = CGPoint(x: rect.minX + rect.width * CGFloat(i) / CGFloat(values.count - 1),
                             y: rect.maxY - rect.height * CGFloat((v - lo) / span))
            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
        }
        return p
    }
}

/// One measure over time: 2 px line over a faint area, recessive grid, hover crosshair with the exact value.
struct TrendChart: View {
    let title: String
    let unit: String
    let points: [HistoryPoint]
    let value: KeyPath<HistoryPoint, Double?>
    let color: Color
    let format: String
    var yMax: Double? = nil
    @State private var hover: Date?

    var body: some View {
        let data = points.compactMap { p in p[keyPath: value].map { (p.date, $0) } }
        let selected = hover.flatMap { h in data.min { abs($0.0.timeIntervalSince(h)) < abs($1.0.timeIntervalSince(h)) } }
        Panel(title: title, icon: "chart.xyaxis.line") {
            HStack(alignment: .firstTextBaseline) {
                Text(data.last.map { String(format: format, $0.1) } ?? "—").font(.title3.bold().monospacedDigit())
                if data.count > 1 {
                    let vals = data.map(\.1)
                    Text(String(format: "min " + format + " · max " + format, vals.min()!, vals.max()!))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if data.count < 2 {
                Text("Collecting…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 140)
            } else {
                Chart {
                    ForEach(data, id: \.0) { d in
                        AreaMark(x: .value("Time", d.0), y: .value(unit, d.1))
                            .foregroundStyle(color.opacity(0.12))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", d.0), y: .value(unit, d.1))
                            .foregroundStyle(color)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                            .interpolationMethod(.monotone)
                    }
                    if let s = selected {
                        RuleMark(x: .value("Time", s.0)).foregroundStyle(.secondary.opacity(0.5))
                        PointMark(x: .value("Time", s.0), y: .value(unit, s.1))
                            .foregroundStyle(color).symbolSize(64)
                            .annotation(position: .top, alignment: .center, spacing: 6) {
                                VStack(spacing: 1) {
                                    Text(String(format: format, s.1)).font(.caption.bold().monospacedDigit())
                                    Text(s.0.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                                }
                                .padding(.horizontal, 6).padding(.vertical, 3)
                                .background(RoundedRectangle(cornerRadius: 5).fill(.background).shadow(radius: 1))
                            }
                    }
                }
                .chartYScale(domain: 0...(yMax ?? max(1, (data.map(\.1).max() ?? 1) * 1.15)))
                .chartXAxis {
                    let short = (data.last?.0.timeIntervalSince(data[0].0) ?? 0) < 300
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(.quaternary)
                        AxisValueLabel(format: short ? .dateTime.hour().minute().second() : .dateTime.hour().minute())
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                .chartXSelection(value: $hover)
                .frame(height: 140)
            }
        }
    }
}

/// Ranking → horizontal bars, one color, value labels at the bar ends.
struct TopEnergyChart: View {
    let processes: [ProcSample]

    var body: some View {
        let top = Array(processes.filter { $0.avgEnergyW > 0 && $0.pid != 0 }.sorted { $0.avgEnergyW > $1.avgEnergyW }.prefix(8))
        Panel(title: "Top energy users (5-min average)", icon: "flame") {
            if top.isEmpty {
                Text("Collecting…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 200)
            } else {
                Chart(top, id: \.key) { p in
                    BarMark(x: .value("Watts", p.avgEnergyW), y: .value("Process", p.name + " " + String(p.pid)), height: .fixed(10))
                        .foregroundStyle(VizColor.series1)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text(verbatim: "\(p.name) (\(p.pid))").font(.caption).lineLimit(1)
                        }
                        .annotation(position: .trailing, spacing: 4) {
                            Text(Fmt.watts(p.avgEnergyW, estimated: !p.isOwn)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisGridLine().foregroundStyle(.quaternary); AxisValueLabel() } }
                .chartYAxis(.hidden)
                .chartXScale(domain: 0...((top.first?.avgEnergyW ?? 1) * 1.25))
                .frame(height: CGFloat(top.count) * 36 + 20)
                Text("~ = estimated from CPU time (other users' processes). Measured values come from the kernel's per-process energy counter.")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}

/// Disk capacity plus reclaimable developer artifacts by type (from the last Developer Artifacts scan).
struct ReclaimableChart: View {
    let result: ArtifactScanResult?
    let disk: SystemStats.Disk?
    let openArtifacts: () -> Void

    var body: some View {
        Panel(title: "Disk & reclaimable developer artifacts", icon: "internaldrive") {
            if let d = disk {
                let used = d.total - d.available
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(Fmt.bytes(d.available)) available of \(Fmt.bytes(d.total))").font(.title3.bold())
                    GeometryReader { g in
                        let frac = CGFloat(Double(used) / Double(max(1, d.total)))
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.15))
                            RoundedRectangle(cornerRadius: 4).fill(VizColor.series1).frame(width: max(4, g.size.width * frac - 1))
                        }
                    }
                    .frame(height: 10)
                    Text("\(Fmt.bytes(used)) used").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let r = result, !r.artifacts.isEmpty {
                let byKind = Dictionary(grouping: r.artifacts, by: \.kind)
                    .map { (kind: $0.key, bytes: $0.value.reduce(0) { $0 + $1.reclaimable }, count: $0.value.count) }
                    .filter { $0.bytes > 0 }
                    .sorted { $0.bytes > $1.bytes }
                let total = byKind.reduce(0) { $0 + $1.bytes }
                Text("\(Fmt.bytes(total)) reclaimable across \(r.artifacts.count) items · scanned \(Fmt.relative(r.date))")
                    .font(.callout).padding(.top, 6)
                Chart(byKind, id: \.kind) { k in
                    BarMark(x: .value("Bytes", Double(k.bytes) / 1e9), y: .value("Type", k.kind.displayName), height: .fixed(10))
                        .foregroundStyle(VizColor.series1)
                        .clipShape(UnevenRoundedRectangle(bottomTrailingRadius: 4, topTrailingRadius: 4))
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text(k.kind.displayName).font(.caption).lineLimit(1)
                        }
                        .annotation(position: .trailing, spacing: 4) {
                            Text("\(Fmt.bytes(k.bytes)) · \(k.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { v in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let g = v.as(Double.self) { Text("\(Int(g)) GB") } }
                } }
                .chartYAxis(.hidden)
                .chartXScale(domain: 0...(Double(byKind.first?.bytes ?? 1) / 1e9 * 1.35))
                .frame(height: CGFloat(byKind.count) * 36 + 20)
            } else {
                Text("No developer-artifact scan yet.").foregroundStyle(.secondary).padding(.top, 6)
            }
            Button("Open Developer Artifacts →", action: openArtifacts).buttonStyle(.link)
        }
    }
}
