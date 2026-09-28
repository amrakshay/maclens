import AppKit
import SwiftUI
import UserNotifications
import MacLensCore

/// Opt-in water reminders (#28). Off by default; while off, no timer exists.
/// While on, one timer ticks every minute; each tick is a few cheap reads (session dictionary, HID idle time, screen watcher).
@MainActor final class WaterStore: ObservableObject {
    enum Style: String, CaseIterable, Identifiable {
        case notification, onScreen
        var id: String { rawValue }
        var title: String { self == .notification ? "Notification" : "On-screen alert" }
    }

    private let d = UserDefaults.standard
    @Published var enabled: Bool { didSet { d.set(enabled, forKey: "waterEnabled"); restart() } }
    @Published var intervalMinutes: Int { didSet { d.set(intervalMinutes, forKey: "waterInterval"); apply() } }
    @Published var style: Style { didSet { d.set(style.rawValue, forKey: "waterStyle") } }
    @Published var skipWhileSharing: Bool { didSet { d.set(skipWhileSharing, forKey: "waterSkipSharing") } }
    @Published var startMinutes: Int { didSet { d.set(startMinutes, forKey: "waterStart"); apply() } }
    @Published var endMinutes: Int { didSet { d.set(endMinutes, forKey: "waterEnd"); apply() } }
    @Published var weekdays: Set<Int> { didSet { d.set(Array(weekdays).sorted(), forKey: "waterWeekdays"); apply() } }
    @Published var timeZoneID: String { didSet { d.set(timeZoneID, forKey: "waterTimeZone"); apply() } }
    @Published private(set) var pausedUntil: Date? { didSet { d.set(pausedUntil, forKey: "waterPausedUntil") } }
    /// Why the last tick didn't show a reminder, for the menu bar status line.
    @Published private(set) var waiting: WaterReminderEngine.Why?
    @Published private(set) var nextDue: Date?

    private var engine = WaterReminderEngine()
    private var timer: Timer?
    private let panel = WaterPanelController()
    var notify: (() -> Void)?

    init() {
        d.register(defaults: ["waterEnabled": false, "waterInterval": 30, "waterStyle": Style.notification.rawValue,
                              "waterSkipSharing": true, "waterStart": 600, "waterEnd": 1140,
                              "waterWeekdays": [2, 3, 4, 5, 6], "waterTimeZone": "Asia/Kolkata"])
        enabled = d.bool(forKey: "waterEnabled")
        intervalMinutes = d.integer(forKey: "waterInterval")
        style = Style(rawValue: d.string(forKey: "waterStyle") ?? "") ?? .notification
        skipWhileSharing = d.bool(forKey: "waterSkipSharing")
        startMinutes = d.integer(forKey: "waterStart")
        endMinutes = d.integer(forKey: "waterEnd")
        weekdays = Set((d.array(forKey: "waterWeekdays") as? [Int]) ?? [2, 3, 4, 5, 6])
        timeZoneID = d.string(forKey: "waterTimeZone") ?? "Asia/Kolkata"
        pausedUntil = (d.object(forKey: "waterPausedUntil") as? Date).flatMap { $0 > Date() ? $0 : nil }
        panel.store = self
        apply()
        restart()
    }

    var schedule: WorkSchedule {
        WorkSchedule(start: startMinutes, end: endMinutes, weekdays: weekdays, timeZone: TimeZone(identifier: timeZoneID) ?? .current)
    }
    var isPaused: Bool { pausedUntil.map { $0 > Date() } ?? false }
    var inWorkHours: Bool { schedule.contains(Date()) }

    private func apply() {
        engine.interval = TimeInterval(max(5, intervalMinutes) * 60)
        engine.schedule = schedule
        engine.pausedUntil = pausedUntil
        engine.reset()
        tick()
    }

    private func restart() {
        timer?.invalidate(); timer = nil
        guard enabled else { panel.close(); waiting = nil; nextDue = nil; return }
        let t = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.tick() } }
        t.tolerance = 10 // lets macOS coalesce the wakeup
        RunLoop.main.add(t, forMode: .common)
        timer = t
        engine.reset()
        tick()
    }

    func tick() {
        guard enabled else { return }
        let now = Date()
        let away = PresenceSignals.screenIsLocked() || (PresenceSignals.idleSeconds() ?? 0) >= engine.interval
        let sharing = skipWhileSharing && (PresenceSignals.screenIsShared() ?? false)
        let decision = engine.tick(now: now, sharing: sharing, away: away, alertVisible: panel.isVisible)
        if pausedUntil != engine.pausedUntil { pausedUntil = engine.pausedUntil }
        nextDue = engine.nextDue
        switch decision {
        case .show: waiting = nil; show()
        case .wait(let why): waiting = why
        }
    }

    private func show() {
        switch style {
        case .notification: notify?()
        case .onScreen: panel.show(interval: intervalMinutes)
        }
    }

    // MARK: Actions

    nonisolated static let categoryID = "water"
    /// Actions on the notification (shown under Options when hovering the banner). Clicking or dismissing it counts as Done.
    nonisolated static var notificationCategory: UNNotificationCategory {
        UNNotificationCategory(identifier: categoryID, actions: [
            UNNotificationAction(identifier: "done", title: "Done"),
            UNNotificationAction(identifier: "snooze10", title: "Snooze 10 min"),
            UNNotificationAction(identifier: "pause60", title: "Pause 1 hour"),
            UNNotificationAction(identifier: "pauseShift", title: "Pause until end of shift"),
        ], intentIdentifiers: [], options: [.customDismissAction])
    }

    func handleNotificationAction(_ id: String) {
        switch id {
        case "snooze10": snooze(minutes: 10)
        case "pause60": pause(minutes: 60)
        case "pauseShift": pauseUntilEndOfShift()
        default: done() // "done", a click on the banner, or dismissing it
        }
    }

    func done() { engine.done(now: Date()); panel.close(); nextDue = engine.nextDue }
    func snooze(minutes: Int) { engine.snooze(TimeInterval(minutes * 60), now: Date()); panel.close(); nextDue = engine.nextDue }

    func pause(minutes: Int) { setPause(Date().addingTimeInterval(TimeInterval(minutes * 60))) }
    func pauseUntilEndOfShift() { setPause(schedule.shiftEnd(containing: Date()) ?? Date()) }
    func resume() { setPause(nil) }
    private func setPause(_ until: Date?) {
        pausedUntil = until
        engine.pausedUntil = until
        panel.close()
        tick() // on resume, a reminder owed during the pause shows now
    }

    func showTest() { style == .notification ? notify?() : panel.show(interval: intervalMinutes) }

    var statusLine: String {
        let fmt: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        if let p = pausedUntil, p > Date() { return "Paused until \(fmt(p))" }
        switch waiting {
        case .offHours: return "Outside work hours"
        case .sharing: return "Waiting until screen sharing ends"
        case .away: return "Skipped while you were away"
        default: return nextDue.map { "Next reminder at \(fmt($0))" } ?? "Starting…"
        }
    }
}

// MARK: - On-screen alert

/// A floating panel above every window, on every Space and over full-screen apps. It never takes keyboard focus from what you're typing in.
@MainActor final class WaterPanelController {
    weak var store: WaterStore?
    private var panel: NSPanel?
    var isVisible: Bool { panel?.isVisible ?? false }

    func show(interval: Int) {
        guard let store else { return }
        let p = panel ?? makePanel()
        p.contentView = NSHostingView(rootView: WaterAlertView(interval: interval).environmentObject(store))
        p.setContentSize(p.contentView!.fittingSize)
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            p.setFrameOrigin(NSPoint(x: f.midX - p.frame.width / 2, y: f.maxY - p.frame.height - 40))
        }
        p.orderFrontRegardless()
        panel = p
    }

    func close() { panel?.orderOut(nil) }

    private func makePanel() -> NSPanel {
        // Borderless, so the panel is exactly as tall as its content (a hidden title bar still takes height).
        let p = WaterPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 160),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.becomesKeyOnlyIfNeeded = true
        return p
    }
}

/// Borderless panels refuse key status by default; allow it on click so the buttons and Pause menu respond to the first click.
/// It's non-activating and `becomesKeyOnlyIfNeeded`, so showing it never moves keyboard focus.
final class WaterPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

struct WaterAlertView: View {
    let interval: Int
    @EnvironmentObject var water: WaterStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 16, height: 16)
                Text("MacLens").font(.caption.weight(.semibold))
                Text("· Water reminder").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Image(systemName: "drop.fill").font(.system(size: 30)).foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Time to drink some water").font(.title3.weight(.semibold))
                    Text("Your \(interval)-minute reminder. Take a sip and stretch for a moment.").foregroundStyle(.secondary)
                }
            }
            HStack {
                PauseMenu(label: "Pause…")
                Spacer()
                Button("Snooze 10 min") { water.snooze(minutes: 10) }
                Button("Done") { water.done() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.12)))
    }
}

struct PauseMenu: View {
    let label: String
    @EnvironmentObject var water: WaterStore

    var body: some View {
        Menu(label) {
            Button("30 minutes") { water.pause(minutes: 30) }
            Button("1 hour") { water.pause(minutes: 60) }
            Button("2 hours") { water.pause(minutes: 120) }
            Button("Until end of shift") { water.pauseUntilEndOfShift() }.disabled(!water.inWorkHours)
        }
        .fixedSize()
    }
}

// MARK: - Menu bar and Settings

struct WaterMenuSection: View {
    @EnvironmentObject var water: WaterStore

    var body: some View {
        if water.enabled {
            Divider()
            HStack {
                Image(systemName: water.isPaused ? "drop" : "drop.fill").foregroundStyle(.blue)
                Text(water.statusLine).lineLimit(1)
                Spacer()
                if water.isPaused { Button("Resume now") { water.resume() } }
                else { PauseMenu(label: "Pause") }
            }
        }
    }
}

struct WaterSettingsSection: View {
    @EnvironmentObject var water: WaterStore
    @EnvironmentObject var model: AppModel
    @State private var testNote: String?
    private let days = [(2, "Mon"), (3, "Tue"), (4, "Wed"), (5, "Thu"), (6, "Fri"), (7, "Sat"), (1, "Sun")]

    var body: some View {
        Section("Water reminders") {
            Toggle("Remind me to drink water", isOn: $water.enabled)
            Group {
                Picker("Every", selection: $water.intervalMinutes) {
                    ForEach([15, 20, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) min").tag($0) }
                }
                HStack {
                    Text("Work hours")
                    Spacer()
                    TimeField(minutes: $water.startMinutes)
                    Text("to")
                    TimeField(minutes: $water.endMinutes)
                }
                Picker("Time zone", selection: $water.timeZoneID) {
                    ForEach(timeZones, id: \.self) { Text(zoneLabel($0)).tag($0) }
                }
                HStack {
                    Text("Workdays")
                    Spacer()
                    ForEach(days, id: \.0) { day in
                        Toggle(day.1, isOn: Binding(get: { water.weekdays.contains(day.0) },
                                                    set: { on in if on { water.weekdays.insert(day.0) } else { water.weekdays.remove(day.0) } }))
                            .toggleStyle(.button)
                    }
                }
                Picker("Show as", selection: $water.style) {
                    ForEach(WaterStore.Style.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Skip while the screen is shared, recorded or mirrored", isOn: $water.skipWhileSharing)
                HStack {
                    Button("Show a test reminder") { test() }
                    Text(water.statusLine).foregroundStyle(.secondary)
                }
                if let testNote {
                    Label(testNote, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
            }
            .disabled(!water.enabled)
            Text("Off by default. Reminders appear only during work hours on workdays. One skipped while you share your screen or pause is shown once, when that ends; while the Mac is locked or idle longer than the interval, it's skipped. Reminders never pile up. The on-screen alert stays above all windows until you click Done, Snooze or Pause. Screen-sharing detection is confirmed for Zoom; if another app isn't detected, use Pause from the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: water.style) { testNote = nil }
        .onChange(of: water.startMinutes) { if water.endMinutes <= water.startMinutes { water.endMinutes = min(24 * 60 - 1, water.startMinutes + 60) } }
    }

    private func test() {
        testNote = nil
        water.showTest()
        guard water.style == .notification else { return }
        Task { testNote = await model.notifier.deliveryProblem() }
    }

    private var timeZones: [String] {
        var z = ["Asia/Kolkata", TimeZone.current.identifier, "UTC", "Europe/London", "America/New_York", "America/Los_Angeles"]
        if !z.contains(water.timeZoneID) { z.append(water.timeZoneID) }
        var seen = Set<String>()
        return z.filter { seen.insert($0).inserted }
    }

    private func zoneLabel(_ id: String) -> String {
        let tz = TimeZone(identifier: id)
        let abbr = tz?.abbreviation() ?? ""
        let name = id == "Asia/Kolkata" ? "India (IST)" : id.replacingOccurrences(of: "_", with: " ")
        return id == TimeZone.current.identifier && id != "Asia/Kolkata" ? "\(name) — this Mac (\(abbr))" : "\(name) (\(abbr))"
    }
}

/// Minutes-after-midnight edited as a time.
struct TimeField: View {
    @Binding var minutes: Int
    var body: some View {
        DatePicker("", selection: Binding(
            get: { Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date() },
            set: { let c = Calendar.current.dateComponents([.hour, .minute], from: $0); minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0) }),
                   displayedComponents: .hourAndMinute)
            .labelsHidden()
            .fixedSize()
    }
}
