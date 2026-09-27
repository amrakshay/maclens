import AppKit
import SwiftUI
import MacLensCore

/// "About MacLens" (#20): the standard macOS About panel (icon, name, version, copyright from
/// NSHumanReadableCopyright) plus a credits block with what MacLens is, the author, links and privacy.
enum AboutPanel {
    static let repo = URL(string: "https://github.com/amrakshay/maclens")!
    static let links: [(String, URL)] = [
        ("GitHub", repo),
        ("What's new", URL(string: "https://github.com/amrakshay/maclens/releases")!),
        ("Report an issue", URL(string: "https://github.com/amrakshay/maclens/issues/new/choose")!),
        ("License", URL(string: "https://github.com/amrakshay/maclens/blob/main/LICENSE")!),
    ]
    static let tagline = "A lightweight Mac monitor for developers: heat, battery drain, ports and build-artifact cleanup."

    @MainActor static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    static func installLine(_ kind: Updater.InstallKind) -> String {
        switch kind {
        case .homebrew: return "Installed with Homebrew · checks GitHub for updates daily"
        case .direct: return "Downloaded from GitHub · checks for updates daily"
        case .unsupported: return "Development build · automatic updates off"
        }
    }

    static func credits(installKind: Updater.InstallKind = Updater.installKind(bundlePath: Bundle.main.bundlePath)) -> NSAttributedString {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 6
        let body = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func text(_ s: String, color: NSColor = .labelColor, font: NSFont = body) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: center])
        }
        func link(_ s: String, _ url: URL) -> NSAttributedString {
            NSAttributedString(string: s, attributes: [.font: body, .link: url, .paragraphStyle: center])
        }

        let out = NSMutableAttributedString()
        out.append(text(tagline + "\n"))
        out.append(text("Made by "))
        out.append(link("Akshay Rahatwal (@amrakshay)", URL(string: "https://github.com/amrakshay")!))
        out.append(text("\n"))
        for (i, (name, url)) in links.enumerated() {
            if i > 0 { out.append(text("  │  ", color: .tertiaryLabelColor)) }
            out.append(link(name, url))
        }
        out.append(text("\n"))
        out.append(text(installLine(installKind) + "\n", color: .secondaryLabelColor))
        out.append(text("No telemetry: the only network request is the daily update check to GitHub.", color: .secondaryLabelColor))
        return out
    }
}

/// Settings → About row: the same information inline, with a button for the panel.
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
