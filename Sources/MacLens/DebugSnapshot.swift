import AppKit
import SwiftUI
import MacLensCore

/// Developer aid: `MacLens --snapshot DIR` renders the main window for each tab into DIR/<tab>.png and quits.
/// Uses the app's own view caching, so it needs no Screen Recording permission.
@MainActor enum DebugSnapshot {
    static var directory: URL? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count else { return nil }
        return URL(fileURLWithPath: a[i + 1], isDirectory: true)
    }

    static func run(model: AppModel, dir: URL) {
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try? await Task.sleep(for: .seconds(2))
            model.refreshVisibility()
            let grouped = model.settings.groupProcessesByApp
            model.settings.groupProcessesByApp = false // processes.png is the flat list; processes-apps.png the grouped one
            for tab in Tab.allCases {
                if tab == .storage && model.disk.scanning { while model.disk.scanning { try? await Task.sleep(for: .seconds(1)) } }
                model.tab = tab
                if tab == .processes { model.tickNow() }
                try? await Task.sleep(for: .seconds(tab == .heat ? 8 : tab == .dashboard ? Double(ProcessInfo.processInfo.environment["DASH_WAIT"] ?? "20") ?? 20 : 5))
                model.refreshVisibility()
                capture(dir.appendingPathComponent("\(tab.rawValue).png"))
                if tab == .heat { renderOffscreen(HeatContent(), model: model, to: dir.appendingPathComponent("heat-content.png")) }
                if tab == .dashboard { renderOffscreen(DashboardContent(), model: model, to: dir.appendingPathComponent("dashboard-content.png")) }
            }
            // Processes grouped by application (#34).
            model.settings.groupProcessesByApp = true
            model.tab = .processes
            try? await Task.sleep(for: .seconds(3))
            capture(dir.appendingPathComponent("processes-apps.png"))
            model.settings.groupProcessesByApp = grouped
            // What machines without VoiceMode see on the Additional Services tab.
            renderOffscreen(NotInstalledWarning().padding().frame(width: 760), model: model, to: dir.appendingPathComponent("services-not-installed.png"))
            renderCharacters(model: model, dir: dir)
            // Water reminders (#28): the on-screen alert (Settings → Water reminders is in settings.png only when scrolled into view).
            renderOffscreen(WaterAlertView(interval: 30).frame(width: 440), model: model, to: dir.appendingPathComponent("water-alert.png"))
            // Update window with a sample release (no real newer release exists to show it otherwise).
            let cur = model.updates.currentVersion
            let next = "\(cur.major).\(cur.minor + 1).0" // always newer than the running build
            model.updates.preview(ReleaseInfo(
                version: SemVer(next)!, tag: "v" + next,
                notes: "## [1.1.0](https://github.com/amrakshay/maclens/compare/v1.0.0...v1.1.0) (2026-09-28)\n\n### Features\n\n* in-app update checker with changelog and **Update and restart** ([#5](https://github.com/amrakshay/maclens/issues/5))\n\n### Bug Fixes\n\n* use Homebrew 6 `depends_on macos` syntax in the cask",
                publishedAt: Date().addingTimeInterval(-3600), pageURL: URL(string: "https://github.com/amrakshay/maclens/releases")!,
                zipURL: URL(string: "https://github.com/amrakshay/maclens/releases/download/v1.1.0/MacLens-1.1.0.zip")!,
                sha256URL: URL(string: "https://github.com/amrakshay/maclens/releases/download/v1.1.0/MacLens-1.1.0.zip.sha256")!))
            renderOffscreen(UpdateWindow(), model: model, to: dir.appendingPathComponent("update-window.png"))
            if let notes = model.updates.latest?.notes {
                renderOffscreen(ReleaseNotesView(markdown: notes).padding().frame(width: 520, alignment: .leading), model: model,
                                to: dir.appendingPathComponent("update-notes.png"))
            }
            model.tab = .dashboard
            try? await Task.sleep(for: .seconds(2))
            renderOffscreen(UpdateBanner().frame(width: 900), model: model, to: dir.appendingPathComponent("update-banner.png"))
            if let r = model.updates.latest {
                model.updates.preview(r, phase: .installing("Refreshing Homebrew (brew update)…"))
                renderOffscreen(UpdateBanner().frame(width: 900), model: model, to: dir.appendingPathComponent("update-banner-installing.png"))
                let err = "brew finished but the installed app isn't newer. Run `brew update && brew upgrade --cask maclens` in Terminal, then reopen MacLens."
                model.updates.preview(r, phase: .failed(err))
                renderOffscreen(UpdateBanner().frame(width: 900), model: model, to: dir.appendingPathComponent("update-banner-failed.png"))
                renderOffscreen(UpdateWindow(), model: model, to: dir.appendingPathComponent("update-window-failed.png"))
            }
            // About window (#20, #46): the real window in both appearances, plus an ImageRenderer copy of its content.
            AboutPanel.show()
            if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "about" }) {
                for (name, look) in [("about.png", NSAppearance.Name.aqua), ("about-dark.png", .darkAqua)] {
                    w.appearance = NSAppearance(named: look)
                    try? await Task.sleep(for: .seconds(1))
                    capture(w, to: dir.appendingPathComponent(name))
                }
                w.appearance = nil
            }
            let about = ImageRenderer(content: AboutView(installKind: .homebrew(brew: "/opt/homebrew/bin/brew")).background(Color(nsColor: .windowBackgroundColor)))
            about.scale = 2
            if let img = about.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("about-content.png"))
            }
            NSApp.terminate(nil)
        }
    }

    /// Desktop character (#39): every expression with its bubble, and a sheet of poses (walk cycle, walking off, blink)
    /// on light and dark backgrounds. `MacLens --character-snapshot DIR` renders only these, then quits.
    static func renderCharacters(model: AppModel, dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for k in CharacterAlertKind.allCases {
            renderOffscreen(CharacterPreview(alert: CharacterStore.sample(k)).frame(width: 300), model: model,
                            to: dir.appendingPathComponent("character-\(k.rawValue).png"))
        }
        for dark in [false, true] {
            renderOffscreen(CharacterPoseSheet().padding().background(dark ? Color(white: 0.12) : Color(white: 0.96)), model: model,
                            to: dir.appendingPathComponent(dark ? "character-poses-dark.png" : "character-poses.png"))
        }
    }

    /// ScrollView content isn't captured from layers; render the view offscreen instead.
    static func renderOffscreen<V: View>(_ view: V, model: AppModel, to url: URL) {
        let r = ImageRenderer(content: view.frame(width: 1000)
            .environmentObject(model).environmentObject(model.settings).environmentObject(model.monitor)
            .environmentObject(model.history).environmentObject(model.ports).environmentObject(model.artifacts).environmentObject(model.sleep).environmentObject(model.updates).environmentObject(model.services).environmentObject(model.water)
            .background(Color.white))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    static func capture(_ url: URL) {
        guard let w = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("main") }) else { return }
        capture(w, to: url)
    }

    static func capture(_ w: NSWindow, to url: URL) {
        guard let v = w.contentView?.superview ?? w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        if let layer = v.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            layer.render(in: ctx.cgContext) // renders SwiftUI/layer-backed content that cacheDisplay misses
        } else {
            v.cacheDisplay(in: v.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}

/// Every pose of the mascot, for checking the drawing without putting it on screen.
struct CharacterPoseSheet: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(CharacterAlertKind.allCases, id: \.self) { k in
                    MascotImage(pose: MascotPose(kind: k, subject: k == .runaway ? "node" : nil))
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<6, id: \.self) { i in
                    MascotImage(pose: MascotPose(kind: .water, phase: Double(i) * .pi / 3, walking: true)) // walk cycle
                }
            }
            HStack(spacing: 4) {
                MascotImage(pose: MascotPose(kind: .water, blinking: true))
                MascotImage(pose: MascotPose(kind: .batteryLow, phase: 1, walking: true))
                ForEach(0..<3, id: \.self) { i in // walking off, empty-handed and facing right
                    MascotImage(pose: MascotPose(kind: .water, phase: Double(i) * .pi / 2, walking: true, carrying: false), mirrored: true)
                }
            }
        }
    }
}
