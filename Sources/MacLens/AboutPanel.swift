import AppKit
import SwiftUI
import MacLensCore

/// "About MacLens" (#20, redesigned in #46): a small native window with the icon, name, version (click to copy),
/// what MacLens is, the author, link buttons, and a footer with how it was installed, privacy and license.
enum AboutPanel {
    static let repo = URL(string: "https://github.com/amrakshay/maclens")!
    static let author = URL(string: "https://github.com/amrakshay")!
    static let license = URL(string: "https://github.com/amrakshay/maclens/blob/main/LICENSE")!
    static let links: [(String, URL)] = [
        ("GitHub", repo),
        ("What’s New", URL(string: "https://github.com/amrakshay/maclens/releases")!),
        ("Report an Issue", URL(string: "https://github.com/amrakshay/maclens/issues/new/choose")!),
        ("License", license),
    ]
    static let tagline = "A lightweight Mac monitor for developers: heat, battery drain, ports and build-artifact cleanup."
    static let privacy = "No telemetry: the only network request is the daily update check to GitHub."

    @MainActor private static var window: NSWindow?

    @MainActor static func show() {
        let w = window ?? makeWindow()
        if window == nil { w.center() }
        window = w
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    @MainActor private static func makeWindow() -> NSWindow {
        let host = NSHostingView(rootView: AboutView())
        let w = AboutWindow(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        w.identifier = NSUserInterfaceItemIdentifier("about")
        w.title = "About MacLens"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.isReleasedWhenClosed = false
        w.contentView = host
        w.setContentSize(host.fittingSize)
        return w
    }

    static func installLine(_ kind: Updater.InstallKind) -> String {
        switch kind {
        case .homebrew: return "Installed with Homebrew · Checks GitHub for updates daily"
        case .direct: return "Downloaded from GitHub · Checks for updates daily"
        case .unsupported: return "Development build · Automatic updates off"
        }
    }
}

/// Closes on Escape, like the standard About panel.
private final class AboutWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) { close() }
}

struct AboutView: View {
    var installKind = Updater.installKind(bundlePath: Bundle.main.bundlePath)
    @State private var copied = false
    @State private var resetCopied: Task<Void, Never>?

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info?["CFBundleVersion"] as? String
        return build.map { "\(short) (\($0))" } ?? short
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
                Text("MacLens").font(.system(size: 22, weight: .bold)).kerning(-0.2).padding(.top, 14)
                Text(copied ? "Copied to Clipboard" : "Version \(version)")
                    .font(.system(size: 12)).monospacedDigit().foregroundStyle(.secondary).padding(.top, 4)
                    .contentShape(Rectangle())
                    .onTapGesture(perform: copyVersion)
                    .help("Click to copy")
                Text(AboutPanel.tagline)
                    .font(.system(size: 13)).lineSpacing(2).foregroundStyle(.primary.opacity(0.85))
                    .fixedSize(horizontal: false, vertical: true).padding(.top, 14)
                HStack(spacing: 3) {
                    Text("by").foregroundStyle(.secondary)
                    Link("Akshay Rahatwal", destination: AboutPanel.author)
                }
                .font(.system(size: 12)).padding(.top, 10)
                HStack(spacing: 6) {
                    ForEach(AboutPanel.links.prefix(3), id: \.0) { name, url in
                        Link(name, destination: url).buttonStyle(AboutLinkButtonStyle())
                    }
                }
                .padding(.top, 16)
            }
            .padding(.horizontal, 28).padding(.top, 4).padding(.bottom, 22)

            Divider()
            VStack(spacing: 4) {
                Text(AboutPanel.installLine(installKind) + ". No telemetry.").foregroundStyle(.secondary).help(AboutPanel.privacy)
                HStack(spacing: 0) {
                    Text("© 2026 Akshay Rahatwal · ").foregroundStyle(.secondary)
                    Link("MIT License", destination: AboutPanel.license)
                }
            }
            .font(.system(size: 11))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 14)
        }
        .multilineTextAlignment(.center)
        .frame(width: 340)
    }

    private func copyVersion() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(version, forType: .string)
        copied = true
        resetCopied?.cancel()
        resetCopied = Task {
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled { copied = false }
        }
    }
}

/// The design's small white link buttons: drawn in SwiftUI so they match in both appearances and show up in snapshots.
private struct AboutLinkButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12)).foregroundStyle(.primary)
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(scheme == .dark ? Color.white.opacity(configuration.isPressed ? 0.2 : 0.12)
                                                                                 : Color.white.opacity(configuration.isPressed ? 0.7 : 1)))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.18), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 0.5, y: 1)
    }
}

/// Settings → About row: the same information inline, with a button for the window.
struct AboutSettingsSection: View {
    @EnvironmentObject var updates: UpdateStore

    var body: some View {
        Section("About") {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 40, height: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text("MacLens \(updates.currentVersionString)").font(.headline)
                    Text(AboutPanel.tagline).font(.caption).foregroundStyle(.secondary)
                    Text("Made by Akshay Rahatwal (@amrakshay) · MIT License").font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 12) {
                        ForEach(AboutPanel.links, id: \.0) { Link($0.0, destination: $0.1).font(.caption) }
                    }
                }
                Spacer()
                Button("About MacLens…") { AboutPanel.show() }
            }
        }
    }
}
