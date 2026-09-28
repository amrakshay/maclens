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
            // About panel (#20): open the standard panel and capture its window.
            AboutPanel.show()
            try? await Task.sleep(for: .seconds(1))
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue != "main" && !($0.identifier?.rawValue ?? "").hasPrefix("main") && $0.className.contains("Panel") }),
               let v = w.contentView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("about.png"))
            }
            let credits = AboutPanel.credits(installKind: .homebrew(brew: "/opt/homebrew/bin/brew"))
            renderOffscreen(Text(AttributedString(credits)).frame(width: 420).padding(), model: model, to: dir.appendingPathComponent("about-credits.png"))
            NSApp.terminate(nil)
        }
    }

    /// ScrollView content isn't captured from layers; render the view offscreen instead.
    static func renderOffscreen<V: View>(_ view: V, model: AppModel, to url: URL) {
        let r = ImageRenderer(content: view.frame(width: 1000)
            .environmentObject(model).environmentObject(model.settings).environmentObject(model.monitor)
            .environmentObject(model.history).environmentObject(model.ports).environmentObject(model.artifacts).environmentObject(model.sleep).environmentObject(model.updates).environmentObject(model.water)
            .background(Color.white))
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
    }

    static func capture(_ url: URL) {
        guard let w = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("main") }),
              let v = w.contentView?.superview ?? w.contentView,
              let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
        if let layer = v.layer, let ctx = NSGraphicsContext(bitmapImageRep: rep) {
            layer.render(in: ctx.cgContext) // renders SwiftUI/layer-backed content that cacheDisplay misses
        } else {
            v.cacheDisplay(in: v.bounds, to: rep)
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }
}
