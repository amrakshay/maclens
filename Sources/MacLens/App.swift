import AppKit
import SwiftUI
import UserNotifications
import MacLensCore

/// Clicking the Dock icon with no window open asks the menu bar label (always alive) to reopen the main window.
/// Clicking an "update available" notification opens the update window the same way.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    static let reopen = Notification.Name("MacLensReopenMainWindow")
    static let showUpdate = Notification.Name("MacLensShowUpdateWindow")
    /// A water-reminder notification action; `object` is the action identifier (see `WaterStore.notificationCategory`).
    static let waterAction = Notification.Name("MacLensWaterAction")

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleURL.pathExtension == "app" {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().setNotificationCategories([WaterStore.notificationCategory])
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let kind = response.notification.request.content.userInfo["kind"] as? String
        let isUpdate = kind == "update"
        if kind == "water" {
            let action = response.actionIdentifier
            DispatchQueue.main.async { NotificationCenter.default.post(name: Self.waterAction, object: action) }
            completionHandler()
            return
        }
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: isUpdate ? Self.showUpdate : Self.reopen, object: nil)
        }
        completionHandler()
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound]) // show alerts even while MacLens is frontmost
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: Self.reopen, object: nil) }
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false } // keep the menu bar item
}

@main
struct MacLensApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.summary)
                .environmentObject(model.sleep)
                .environmentObject(model.updates)
                .environmentObject(model.water)
        } label: {
            MenuBarLabel(model: model, summary: model.summary, sleep: model.sleep)
        }
        .menuBarExtraStyle(.window)

        Window("MacLens", id: "main") {
            MainView()
                .environmentObject(model)
                .environmentObject(model.settings)
                .environmentObject(model.monitor)
                .environmentObject(model.ports)
                .environmentObject(model.disk)
                .environmentObject(model.artifacts)
                .environmentObject(model.history)
                .environmentObject(model.sleep)
                .environmentObject(model.updates)
                .environmentObject(model.water)
                .frame(minWidth: 900, minHeight: 560)
        }
        .defaultSize(width: 1180, height: 740)

        Window("Update MacLens", id: "update") {
            UpdateWindow().environmentObject(model.updates)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About MacLens") { AboutPanel.show() }
                Button("Check for Updates…") {
                    model.updates.check(userInitiated: true)
                    NotificationCenter.default.post(name: AppDelegate.showUpdate, object: nil)
                }
            }
        }
    }
}

/// Extra 1: menu bar indicator — thermal state icon plus current system power draw.
struct MenuBarLabel: View {
    let model: AppModel
    @ObservedObject var summary: SummaryStore
    @ObservedObject var sleep: SleepStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 3) {
            if sleep.isActive { Image(systemName: "cup.and.saucer.fill") } // staying awake: visible reminder
            Image(systemName: summary.thermalState.symbol)
            if let w = summary.systemW { Text(String(format: "%.0fW", w)) }
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.reopen)) { _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .onReceive(NotificationCenter.default.publisher(for: AppDelegate.showUpdate)) { _ in
            openWindow(id: "update")
            NSApp.activate(ignoringOtherApps: true)
        }
        .task {
            if model.shouldOpenWindowAtLaunch {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
                if CommandLine.arguments.contains("--autoscan-home") { model.tab = .storage; model.disk.setTarget(.home); model.disk.scan() }
                let a = CommandLine.arguments
                if a.contains("--autoscan-artifacts") { model.artifacts.scan() }
                if let i = a.firstIndex(of: "--tab"), i + 1 < a.count, let t = Tab(rawValue: a[i + 1]) { model.tab = t }
                if let dir = DebugSnapshot.directory { DebugSnapshot.run(model: model, dir: dir) }
            }
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(Tab.allCases, selection: Binding(get: { model.tab }, set: { if let t = $0 { model.tab = t } })) { t in
                Label(t.title, systemImage: t.icon).tag(t)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            Group {
                switch model.tab {
                case .dashboard: DashboardView()
                case .processes: ProcessesView()
                case .heat: HeatView()
                case .ports: PortsView()
                case .storage: StorageView()
                case .artifacts: ArtifactsView()
                case .settings: SettingsView()
                }
            }
            .navigationTitle(model.tab.title)
        }
        .onAppear { model.refreshVisibility() }
    }
}

struct MenuBarView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var summary: SummaryStore
    @EnvironmentObject var sleep: SleepStore
    @EnvironmentObject var updates: UpdateStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = updates.available {
                Button {
                    openWindow(id: "update")
                    NSApp.activate(ignoringOtherApps: true)
                } label: {
                    switch updates.phase {
                    case .installing(let step): Label("Updating to \(r.version.description): \(step)", systemImage: "arrow.triangle.2.circlepath")
                    case .failed: Label("Update to \(r.version.description) failed — details…", systemImage: "exclamationmark.triangle.fill")
                    default: Label("MacLens \(r.version.description) is available — update…", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.borderless)
                Divider()
            }
            HStack {
                Image(systemName: summary.thermalState.symbol).foregroundStyle(summary.thermalState.color)
                Text("Thermal: \(summary.thermalState.label)").font(.headline)
                Spacer()
                if let w = summary.systemW { Text(String(format: "%.1f W", w)).font(.headline.monospacedDigit()) }
            }
            if summary.battery.hasBattery {
                HStack {
                    Image(systemName: summary.battery.isCharging ? "battery.100.bolt" : "battery.75")
                    Text("\(summary.battery.percent ?? 0)%")
                    if let m = summary.battery.minutesRemaining {
                        Text("· \(Fmt.minutes(m)) \(summary.battery.isCharging ? "to full" : "left")").foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text("Top energy (5-min average)").font(.caption).foregroundStyle(.secondary)
            if summary.top.isEmpty { Text("Collecting…").foregroundStyle(.secondary) }
            ForEach(summary.top, id: \.key) { p in
                HStack {
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(Fmt.watts(p.avgEnergyW, estimated: !p.isOwn)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Divider()
            Text("Keeping your Mac awake").font(.caption).foregroundStyle(.secondary)
            if summary.blockers.isEmpty { Text("Nothing").foregroundStyle(.secondary) }
            ForEach(summary.blockers.prefix(4)) { a in
                Text("\(a.processName) — \(AssertionText.friendly(a.type))").lineLimit(1)
            }
            Divider()
            HStack {
                Image(systemName: sleep.isActive ? "cup.and.saucer.fill" : "moon.zzz")
                Text(sleep.isActive ? "Keeping Mac awake" : "Mac sleeps normally")
                Spacer()
                if sleep.isActive { Button("Allow sleep") { sleep.allowSleep() } }
                else { Button("Prevent sleep") { sleep.preventSleep() } }
            }
            WaterMenuSection()
            Divider()
            HStack {
                Button("Open MacLens") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut("o")
                Spacer()
                Button("About") { AboutPanel.show() }
                Button("Quit") { NSApp.terminate(nil) }.keyboardShortcut("q")
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { model.tickNow() }
    }
}

enum AssertionText {
    static func friendly(_ type: String) -> String {
        switch type {
        case "PreventUserIdleSystemSleep", "NoIdleSleepAssertion": return "prevents idle sleep"
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion": return "keeps display on"
        case "PreventSystemSleep": return "prevents all sleep"
        case "UserIsActive": return "user activity (temporary)"
        case "BackgroundTask": return "background task"
        case "NetworkClientActive": return "network client"
        case "ApplePushServiceTask": return "push service"
        default: return type
        }
    }
}
