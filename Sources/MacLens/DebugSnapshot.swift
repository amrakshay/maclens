import AppKit
import SwiftUI

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
            if let root = NSApp.windows.first(where: { ($0.identifier?.rawValue ?? "").hasPrefix("main") })?.contentView {
                func walk(_ v: NSView) { if let t = v as? NSTableView { print("table \(type(of: t)) rows=\(t.numberOfRows) cols=\(t.numberOfColumns)") }; v.subviews.forEach(walk) }
                walk(root)
            }
            NSApp.terminate(nil)
        }
    }

    /// ScrollView content isn't captured from layers; render the view offscreen instead.
    static func renderOffscreen<V: View>(_ view: V, model: AppModel, to url: URL) {
        let r = ImageRenderer(content: view.frame(width: 1000)
            .environmentObject(model).environmentObject(model.settings).environmentObject(model.monitor)
            .environmentObject(model.history).environmentObject(model.ports).environmentObject(model.artifacts).environmentObject(model.sleep)
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
