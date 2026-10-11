import AppKit
import SwiftUI
import UserNotifications
import MacLensCore

enum Tab: String, CaseIterable, Identifiable {
    case dashboard, processes, heat, ports, storage, artifacts, services, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .dashboard: return "Dashboard"
        case .processes: return "Processes"
        case .heat: return "Heat & Battery"
        case .ports: return "Ports"
        case .storage: return "Storage"
        case .artifacts: return "Developer Artifacts"
        case .services: return "Additional Services"
        case .settings: return "Settings"
        }
    }
    var icon: String {
        switch self {
        case .dashboard: return "gauge.with.dots.needle.67percent"
        case .processes: return "list.bullet.rectangle"
        case .heat: return "thermometer.medium"
        case .ports: return "network"
        case .storage: return "internaldrive"
        case .artifacts: return "shippingbox"
        case .services: return "puzzlepiece.extension"
        case .settings: return "gearshape"
        }
    }
}

/// How an alert is delivered (#39). Exactly one of the two, never both.
enum AlertStyle: String, CaseIterable, Identifiable {
    case notification, character
    var id: String { rawValue }
    var title: String { self == .notification ? "Notification" : "Character" }
}

@MainActor final class Settings: ObservableObject {
    private let d = UserDefaults.standard
    @Published var refreshInterval: Double { didSet { d.set(refreshInterval, forKey: "refreshInterval") } }
    @Published var backgroundInterval: Double { didSet { d.set(backgroundInterval, forKey: "backgroundInterval") } }
    @Published var hideSystemProcesses: Bool { didSet { d.set(hideSystemProcesses, forKey: "hideSystemProcesses") } }
    /// Processes tab shows one row per application instead of per process (#34).
    @Published var groupProcessesByApp: Bool { didSet { d.set(groupProcessesByApp, forKey: "groupProcessesByApp") } }
    @Published var hideSystemPorts: Bool { didSet { d.set(hideSystemPorts, forKey: "hideSystemPorts") } }
    /// Heat keeps system processes visible by default: WindowServer & co. are often the actual heat source.
    @Published var hideSystemHeat: Bool { didSet { d.set(hideSystemHeat, forKey: "hideSystemHeat") } }
    @Published var notifyThermal: Bool { didSet { d.set(notifyThermal, forKey: "notifyThermal") } }
    @Published var notifyRunaway: Bool { didSet { d.set(notifyRunaway, forKey: "notifyRunaway") } }
    @Published var runawayCPU: Double { didSet { d.set(runawayCPU, forKey: "runawayCPU") } }
    @Published var runawayMinutes: Double { didSet { d.set(runawayMinutes, forKey: "runawayMinutes") } }
    @Published var notifyBattery: Bool { didSet { d.set(notifyBattery, forKey: "notifyBattery") } }
    @Published var batteryLow: Int { didSet { d.set(batteryLow, forKey: "batteryLow") } }
    @Published var batteryHigh: Int { didSet { d.set(batteryHigh, forKey: "batteryHigh") } }
    /// Battery, thermal and runaway-process alerts.
    @Published var alertStyle: AlertStyle { didSet { d.set(alertStyle.rawValue, forKey: "alertStyle") } }
    @Published var updateAlertStyle: AlertStyle { didSet { d.set(updateAlertStyle.rawValue, forKey: "updateAlertStyle") } }

    init() {
        d.register(defaults: ["refreshInterval": 5.0, "backgroundInterval": 10.0,
                              "hideSystemProcesses": true, "groupProcessesByApp": false, "hideSystemPorts": true, "hideSystemHeat": false,
                              "notifyThermal": true, "notifyRunaway": true, "runawayCPU": 90.0, "runawayMinutes": 5.0,
                              "notifyBattery": true, "batteryLow": 20, "batteryHigh": 80,
                              "alertStyle": AlertStyle.notification.rawValue, "updateAlertStyle": AlertStyle.notification.rawValue])
        refreshInterval = d.double(forKey: "refreshInterval")
        backgroundInterval = d.double(forKey: "backgroundInterval")
        hideSystemProcesses = d.bool(forKey: "hideSystemProcesses")
        groupProcessesByApp = d.bool(forKey: "groupProcessesByApp")
        hideSystemPorts = d.bool(forKey: "hideSystemPorts")
        hideSystemHeat = d.bool(forKey: "hideSystemHeat")
        notifyThermal = d.bool(forKey: "notifyThermal")
        notifyRunaway = d.bool(forKey: "notifyRunaway")
        runawayCPU = d.double(forKey: "runawayCPU")
        runawayMinutes = d.double(forKey: "runawayMinutes")
        notifyBattery = d.bool(forKey: "notifyBattery")
        batteryLow = d.integer(forKey: "batteryLow")
        batteryHigh = d.integer(forKey: "batteryHigh")
        alertStyle = AlertStyle(rawValue: d.string(forKey: "alertStyle") ?? "") ?? .notification
        updateAlertStyle = AlertStyle(rawValue: d.string(forKey: "updateAlertStyle") ?? "") ?? .notification
    }
}

/// Live system data for the main window.
@MainActor final class MonitorStore: ObservableObject {
    @Published var processes: [ProcSample] = []
    @Published var battery = BatteryInfo()
    @Published var batteryHealth: BatteryHealth?
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var thermal: ThermalSummary?
    @Published var assertions: [SleepAssertion] = []
    @Published var wattsPerCore = 1.0
    @Published var updated = Date()
    @Published var precise: [Int32: Double] = [:]
    @Published var preciseDate: Date?
    @Published var preciseRunning = false

    func process(pid: Int32) -> ProcSample? { processes.first { $0.pid == pid } }

    func runPreciseSample() {
        guard !preciseRunning else { return }
        preciseRunning = true
        DispatchQueue.global(qos: .userInitiated).async {
            let r = TopSampler.samplePower()
            DispatchQueue.main.async { self.precise = r; self.preciseDate = Date(); self.preciseRunning = false }
        }
    }
}

/// Small, separately observed state for the menu bar so its label doesn't re-render with every table update.
@MainActor final class SummaryStore: ObservableObject {
    @Published var thermalState: ProcessInfo.ThermalState = .nominal
    @Published var systemW: Double?
    @Published var battery = BatteryInfo()
    @Published var top: [ProcSample] = []
    @Published var blockers: [SleepAssertion] = []
}

struct PortRow: Identifiable, Hashable {
    var id: String { entry.id }
    let entry: PortEntry
    let processName: String
    let path: String
    let user: String
    let isSystem: Bool
    var port: Int { entry.port }
    var pid: Int32 { entry.pid }
    var proto: String { entry.proto }
}

@MainActor final class PortsStore: ObservableObject {
    @Published var rows: [PortRow] = []
    @Published var updated: Date?

    func update(_ entries: [PortEntry], processes: [ProcSample]) {
        var byPid: [Int32: ProcSample] = [:]
        for p in processes { byPid[p.pid] = p }
        rows = entries.map { e in
            if let p = byPid[e.pid] {
                return PortRow(entry: e, processName: p.name, path: p.path, user: p.user, isSystem: p.isSystem)
            }
            let path = ProcList.path(pid: e.pid) ?? ""
            let user = ProcList.basic(pid: e.pid).map { UserNames.shared.name($0.uid) } ?? "?"
            return PortRow(entry: e, processName: path.isEmpty ? e.netstatName : PathUtil.lastComponent(path), path: path, user: user, isSystem: false)
        }
        updated = Date()
    }
}

@MainActor final class AppModel: ObservableObject {
    let settings = Settings()
    let monitor = MonitorStore()
    let summary = SummaryStore()
    let ports = PortsStore()
    let disk = DiskStore()
    let artifacts = ArtifactStore()
    let notifier = Notifier()
    @Published var tab: Tab = .dashboard { didSet { updateMode() } }
    let history = HistoryStore()
    let sleep = SleepStore()
    let updates = UpdateStore()
    let services = ServicesStore()
    let water = WaterStore()
    let character = CharacterStore()
    @Published private(set) var windowVisible = false
    /// Latest readings, to tell whether a queued character alert still applies.
    private var lastBattery = BatteryInfo()
    private var lastThermal: ProcessInfo.ThermalState = .nominal
    private var lastRunaway: Set<String> = []
    private let engine = Engine()
    private var observers: [NSObjectProtocol] = []
    private var didOpenAtLaunch = false

    init() {
        engine.onSample = { [weak self] out in self?.apply(out) }
        engine.start(currentMode())
        let nc = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // Close notifications arrive before the window hides; re-check on the next runloop turn.
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.refreshVisibility() } }
            })
        }
        if settings.notifyThermal || settings.notifyRunaway || settings.notifyBattery || updates.autoCheck { notifier.requestAuthorization() }
        updates.notify = { [weak self] r in
            guard let self else { return }
            self.notifier.postUpdate(r, current: self.updates.currentVersionString, style: self.settings.updateAlertStyle)
        }
        updates.start()
        services.refreshPorts = { [weak self] in self?.refreshPortsNow() }
        observers.append(NotificationCenter.default.addObserver(forName: AppDelegate.waterAction, object: nil, queue: .main) { [weak self] n in
            let action = n.object as? String ?? ""
            MainActor.assumeIsolated { self?.water.handleNotificationAction(action) }
        })
        water.notify = { [weak self] in self?.notifier.postWater() }
        if water.enabled && water.style == .notification { notifier.requestAuthorization() }
        setUpCharacter()
    }

    /// Desktop character (#39): every alert shown as Character goes through one queue.
    private func setUpCharacter() {
        character.water = water
        notifier.showCharacter = { [weak self] a in self?.character.add(a) }
        water.showCharacter = { [weak self] in
            guard let self else { return }
            self.character.add(CharacterStore.water(interval: self.water.intervalMinutes))
        }
        water.characterVisible = { [weak self] in self?.character.contains(.water) ?? false }
        character.isValid = { [weak self] a in self?.characterAlertApplies(a) ?? false }
        character.openTab = { [weak self] tab in
            self?.tab = tab
            NotificationCenter.default.post(name: AppDelegate.reopen, object: nil)
        }
        character.openUpdate = { NotificationCenter.default.post(name: AppDelegate.showUpdate, object: nil) }
        if let i = CommandLine.arguments.firstIndex(of: "--character-snapshot"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1], isDirectory: true)
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    DebugSnapshot.renderCharacters(model: self, dir: dir)
                    NSApp.terminate(nil)
                }
            }
        }
        // Developer and measurement aid: `--character KIND` shows a test character shortly after launch.
        let a = CommandLine.arguments
        if let i = a.firstIndex(of: "--character"), i + 1 < a.count, let kind = CharacterAlertKind(rawValue: a[i + 1]) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in MainActor.assumeIsolated { self?.character.test(kind) } }
            // `--character-dismiss-after S`: dismiss it S seconds later, to measure what's left once it has gone.
            if let j = a.firstIndex(of: "--character-dismiss-after"), j + 1 < a.count, let secs = Double(a[j + 1]) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2 + secs) { [weak self] in MainActor.assumeIsolated { self?.character.dismissVisible() } }
            }
        }
    }

    /// A queued alert is shown only if it's still set to Character and still true when its turn comes
    /// (e.g. after a screen share ends): battery still low, Mac still hot, process still running away, update still pending.
    private func characterAlertApplies(_ a: CharacterAlert) -> Bool {
        let s = settings
        let b = lastBattery
        switch a.kind {
        case .water: return water.enabled && water.style == .character && water.inWorkHours && !water.isPaused
        case .batteryLow:
            return s.alertStyle == .character && s.notifyBattery && !b.isCharging && !b.onAC && (b.percent ?? 100) <= s.batteryLow
        case .batteryHigh:
            return s.alertStyle == .character && s.notifyBattery && (b.isCharging || b.onAC) && (b.percent ?? 0) >= s.batteryHigh - 2
        case .hot: return s.alertStyle == .character && s.notifyThermal && lastThermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        case .runaway: return s.alertStyle == .character && s.notifyRunaway && a.subject.map(lastRunaway.contains) == true
        case .update: return s.updateAlertStyle == .character && updates.available != nil
        }
    }

    var shouldOpenWindowAtLaunch: Bool {
        defer { didOpenAtLaunch = true }
        return !didOpenAtLaunch && !CommandLine.arguments.contains("--background")
    }

    func refreshVisibility() {
        let visible = NSApp.windows.contains { w in
            (w.identifier?.rawValue ?? "").hasPrefix("main") && w.isVisible && !w.isMiniaturized &&
                (w.occlusionState.contains(.visible) || DebugSnapshot.directory != nil || CommandLine.arguments.contains("--assume-visible"))
                // (debug/measurement flags: treat the window as on-screen even if the display is asleep)
        }
        if visible != windowVisible {
            windowVisible = visible
            updateMode()
            if !visible && !CommandLine.arguments.contains("--autoscan-home") { disk.releaseTreeIfIdle() }
        }
    }

    func settingsChanged() { updateMode() }

    private func currentMode() -> SampleMode {
        var m = SampleMode()
        m.runawayCPU = settings.runawayCPU
        m.runawayMinutes = settings.runawayMinutes
        if windowVisible {
            m.interval = settings.refreshInterval
            switch tab {
            case .processes, .heat: m.foreignEvery = 0
            case .ports, .services: m.ports = true
            case .dashboard: m.foreignEvery = 10; m.ports = true
            default: break
            }
            m.temps = tab == .heat || tab == .dashboard
        } else {
            m.interval = settings.backgroundInterval
        }
        return m
    }

    func updateMode() { engine.setMode(currentMode()) }
    func tickNow() { engine.tickNow() }

    func refreshPortsNow() {
        engine.refreshPortsNow { [weak self] entries in
            guard let self else { return }
            self.ports.update(entries, processes: self.monitor.processes)
            if self.tab == .services { self.services.update(ports: entries, processes: self.monitor.processes) }
        }
    }

    private func apply(_ out: SampleOutput) {
        if windowVisible {
            if monitor.processes != out.processes { monitor.processes = out.processes }
            monitor.battery = out.battery
            if monitor.batteryHealth != out.health { monitor.batteryHealth = out.health }
            monitor.thermalState = out.thermalState
            if let t = out.thermal { monitor.thermal = t }
            monitor.assertions = out.assertions
            monitor.wattsPerCore = out.wattsPerCore
            monitor.updated = Date()
        } else if !monitor.processes.isEmpty {
            monitor.processes = [] // drop the big array while hidden
        }
        if let p = out.ports {
            ports.update(p, processes: out.processes)
            if windowVisible && tab == .services { services.update(ports: p, processes: out.processes) }
        }
        history.append(out, publish: windowVisible && tab == .dashboard)
        sleep.update(from: out.processes)

        let top = Array(out.processes.filter { $0.avgEnergyW > 0 && $0.pid != 0 }
            .sorted { $0.avgEnergyW > $1.avgEnergyW }.prefix(3))
        let blockers = out.assertions.filter(\.preventsSleep)
        if summary.thermalState != out.thermalState { summary.thermalState = out.thermalState }
        if summary.systemW.map({ Int($0.rounded()) }) != out.battery.systemLoadW.map({ Int($0.rounded()) }) { summary.systemW = out.battery.systemLoadW }
        if summary.battery != out.battery { summary.battery = out.battery }
        if summary.top.map(\.pid) != top.map(\.pid) || summary.top.map({ Int($0.avgEnergyW * 10) }) != top.map({ Int($0.avgEnergyW * 10) }) { summary.top = top }
        if summary.blockers != blockers { summary.blockers = blockers }

        lastBattery = out.battery
        lastThermal = out.thermalState
        lastRunaway = Set(out.runaway.map(\.name))
        notifier.evaluate(thermal: out.thermalState, runaway: out.runaway, settings: settings)
        notifier.evaluateBattery(out.battery, settings: settings)
        character.tick() // returns at once while nothing is queued
    }
}

struct HistoryPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let powerW: Double?
    let cpuPct: Double?
    let memUsedGB: Double?
    let cpuTempC: Double?
}

/// Rolling 30-minute history for the dashboard charts. Recorded on every tick (cheap), published only while the dashboard is on screen.
@MainActor final class HistoryStore: ObservableObject {
    @Published private(set) var points: [HistoryPoint] = []
    @Published private(set) var memory: SystemStats.Memory?
    @Published private(set) var disk: SystemStats.Disk?
    @Published private(set) var thermal: ThermalSummary?
    private var buffer: [HistoryPoint] = []
    private var lastTemp: (Date, Double)?
    let window: TimeInterval = 30 * 60

    func append(_ out: SampleOutput, publish: Bool) {
        let now = Date()
        if let t = out.thermal?.cpuMaxC { lastTemp = (now, t) }
        let temp = lastTemp.flatMap { now.timeIntervalSince($0.0) < 45 ? $0.1 : nil }
        let p = HistoryPoint(date: now, powerW: out.battery.systemLoadW, cpuPct: out.cpuLoad,
                             memUsedGB: out.memory.map { Double($0.used) / 1e9 } /* decimal GB, like the byte formatter */, cpuTempC: temp)
        // Keep points at least 4 s apart so the buffer stays small at fast refresh rates.
        if buffer.count >= 2, now.timeIntervalSince(buffer[buffer.count - 2].date) < 4 { buffer[buffer.count - 1] = p } else { buffer.append(p) }
        while let f = buffer.first, now.timeIntervalSince(f.date) > window { buffer.removeFirst() }
        if let m = out.memory { memoryLatest = m }
        if let d = out.disk { diskLatest = d }
        if let t = out.thermal { thermalLatest = t }
        if publish { flush() }
    }

    private var memoryLatest: SystemStats.Memory?
    private var diskLatest: SystemStats.Disk?
    private var thermalLatest: ThermalSummary?

    func flush() {
        points = buffer
        memory = memoryLatest
        disk = diskLatest
        if thermalLatest != thermal { thermal = thermalLatest }
    }
}

/// Extra 5: notifications for serious thermal state and runaway processes.
@MainActor final class Notifier {
    private var lastThermal: ProcessInfo.ThermalState = .nominal
    private var notified: [ProcKey: Date] = [:]
    var available: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }
    /// Set by `AppModel`: alerts whose style is Character go to the desktop character instead (#39).
    var showCharacter: ((CharacterAlert) -> Void)?

    func requestAuthorization() {
        guard available else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func evaluate(thermal: ProcessInfo.ThermalState, runaway: [ProcSample], settings: Settings) {
        if settings.notifyThermal, thermal.rawValue >= ProcessInfo.ThermalState.serious.rawValue, lastThermal.rawValue < ProcessInfo.ThermalState.serious.rawValue {
            if settings.alertStyle == .character, let showCharacter {
                showCharacter(CharacterAlert(kind: .hot, title: "Your Mac is running hot", message: "Thermal state is \(thermal.label). Heat & Battery shows what's using energy."))
            } else {
                post("Your Mac is running hot", "Thermal state is \(thermal.label). Open MacLens → Heat & Battery to see what's using energy.")
            }
        }
        lastThermal = thermal
        guard settings.notifyRunaway else { return }
        let now = Date()
        notified = notified.filter { now.timeIntervalSince($0.value) < 3600 }
        for p in runaway where notified[p.key] == nil {
            notified[p.key] = now
            deliver(.runaway, "\(p.name) is using a lot of CPU",
                    String(format: "%.0f%% CPU for over %.0f min (PID %d).", p.avgCPU, settings.runawayMinutes, p.pid),
                    subject: p.name, style: settings.alertStyle)
        }
    }

    private var batteryState = BatteryAlertState()

    /// Battery level alerts: once when the level is reached, re-armed only after moving back past the threshold.
    func evaluateBattery(_ b: BatteryInfo, settings: Settings) {
        guard b.hasBattery, let pct = b.percent else { return }
        let alert = batteryState.update(percent: pct, charging: b.isCharging, onAC: b.onAC,
                                        low: settings.batteryLow, high: settings.batteryHigh)
        guard settings.notifyBattery, let alert else { return }
        switch alert {
        case .low(let p):
            deliver(.batteryLow, "Battery at \(p)%", "Your battery dropped to your \(settings.batteryLow)% alert level. Plug in soon." +
                    (b.minutesRemaining.map { " About \(Fmt.minutes($0)) left." } ?? ""), style: settings.alertStyle)
        case .high(let p):
            deliver(.batteryHigh, "Battery charged to \(p)%", "Reached your \(settings.batteryHigh)% alert level. You can unplug to reduce battery wear.",
                    style: settings.alertStyle)
        }
    }

    /// One notification per new version; clicking it opens the update window (see AppDelegate).
    func postUpdate(_ r: ReleaseInfo, current: String, style: AlertStyle) {
        let title = "MacLens \(r.version.description) is available"
        if style == .character, let showCharacter {
            showCharacter(CharacterAlert(kind: .update, title: title, message: "You have \(current). See what's new and update."))
        } else {
            post(title, "You have \(current). Click to see what's new and update.", userInfo: ["kind": "update"])
        }
    }

    private func deliver(_ kind: CharacterAlertKind, _ title: String, _ body: String, subject: String? = nil, style: AlertStyle) {
        if style == .character, let showCharacter {
            showCharacter(CharacterAlert(kind: kind, title: title, message: body, subject: subject))
        } else {
            post(title, body)
        }
    }

    func postWater() {
        post("Time to drink some water", "Take a sip and stretch for a moment.", userInfo: ["kind": "water"], category: WaterStore.categoryID)
    }

    /// Why a notification won't appear, if we can tell. nil = it should show (Focus / Do Not Disturb can still hide it).
    func deliveryProblem() async -> String? {
        guard available else {
            return "This development build (swift run) can't post notifications; it writes them to its log. They work in the installed MacLens.app."
        }
        let s = await UNUserNotificationCenter.current().notificationSettings()
        switch s.authorizationStatus {
        case .denied: return "Notifications are turned off for MacLens. Allow them in System Settings → Notifications → MacLens."
        case .notDetermined: requestAuthorization(); return "macOS is asking whether MacLens may send notifications. Allow it, then try again."
        default: return s.alertSetting == .disabled ? "MacLens notifications are set to not show banners. Change the style in System Settings → Notifications → MacLens." : nil
        }
    }

    func sendTest() {
        requestAuthorization()
        post("MacLens test alert", "Notifications are working. Battery, thermal and runaway-process alerts will look like this.")
    }

    private func post(_ title: String, _ body: String, userInfo: [String: String] = [:], category: String? = nil) {
        // Pass the text as an argument: a "%" in it ("20% alert") must not be parsed as a format specifier (#26).
        guard available else { NSLog("%@", "MacLens notification: \(title) — \(body)"); return }
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.userInfo = userInfo
        if let category { c.categoryIdentifier = category }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }
}

extension ProcessInfo.ThermalState {
    var label: String {
        switch self {
        case .nominal: return "Nominal"
        case .fair: return "Fair"
        case .serious: return "Serious"
        case .critical: return "Critical"
        @unknown default: return "Unknown"
        }
    }
    var explanation: String {
        switch self {
        case .nominal: return "No thermal pressure."
        case .fair: return "Slightly elevated; fans may spin up."
        case .serious: return "macOS is throttling performance to cool down."
        case .critical: return "Heavy throttling; the system is at its thermal limit."
        @unknown default: return ""
        }
    }
    var color: Color {
        switch self {
        case .nominal: return .green
        case .fair: return .yellow
        case .serious: return .orange
        case .critical: return .red
        @unknown default: return .gray
        }
    }
    var symbol: String {
        switch self {
        case .nominal: return "thermometer.low"
        case .fair: return "thermometer.medium"
        case .serious: return "thermometer.high"
        case .critical: return "flame"
        @unknown default: return "thermometer"
        }
    }
}
