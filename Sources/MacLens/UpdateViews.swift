import AppKit
import SwiftUI
import MacLensCore

/// Keeps track of the latest GitHub release and drives "Update and restart".
@MainActor final class UpdateStore: ObservableObject {
    enum Phase: Equatable { case idle, checking, installing(String), failed(String) }

    @Published private(set) var latest: ReleaseInfo?
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var lastChecked: Date? = UserDefaults.standard.object(forKey: "updateLastChecked") as? Date
    @Published private(set) var lastError: String?
    @Published var autoCheck: Bool = UserDefaults.standard.object(forKey: "updateAutoCheck") as? Bool ?? true {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updateAutoCheck"); schedule() }
    }

    let currentVersionString = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    let buildNumber = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "–"
    var currentVersion: SemVer { SemVer(currentVersionString) ?? SemVer("0.0.0")! }
    var installKind: Updater.InstallKind { Updater.installKind(bundlePath: Bundle.main.bundlePath) }

    /// A newer release that the user hasn't skipped.
    var available: ReleaseInfo? {
        guard let l = latest, l.version > currentVersion, l.tag != skippedTag else { return nil }
        return l
    }

    private var skippedTag: String? {
        get { UserDefaults.standard.string(forKey: "updateSkippedTag") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSkippedTag"); objectWillChange.send() }
    }
    private var notifiedTag: String? {
        get { UserDefaults.standard.string(forKey: "updateNotifiedTag") }
        set { UserDefaults.standard.set(newValue, forKey: "updateNotifiedTag") }
    }
    private var timer: Timer?
    private let checkEvery: TimeInterval = 24 * 3600
    var notify: ((ReleaseInfo) -> Void)?

    /// Starts the daily schedule: first check shortly after launch if the last one is older than a day.
    func start() { schedule() }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard autoCheck, Bundle.main.bundleURL.pathExtension == "app" else { return }
        let since = lastChecked.map { Date().timeIntervalSince($0) } ?? .infinity
        let firstDelay = since >= checkEvery ? 30 : checkEvery - since
        timer = Timer.scheduledTimer(withTimeInterval: firstDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.check(userInitiated: false)
                self?.timer = Timer.scheduledTimer(withTimeInterval: self?.checkEvery ?? 86400, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.check(userInitiated: false) }
                }
            }
        }
    }

    func check(userInitiated: Bool) {
        guard phase != .checking else { return }
        if case .installing = phase { return }
        phase = .checking
        lastError = nil
        let current = currentVersionString
        Task {
            do {
                let r = try await Updater.fetchLatest(currentVersion: current)
                latest = r
                lastChecked = Date()
                UserDefaults.standard.set(lastChecked, forKey: "updateLastChecked")
                phase = .idle
                if userInitiated, r.tag == skippedTag { skippedTag = nil } // asking explicitly un-skips
                if let a = available, a.tag != notifiedTag {
                    notifiedTag = a.tag
                    notify?(a)
                }
            } catch {
                lastError = error.localizedDescription
                phase = userInitiated ? .failed(error.localizedDescription) : .idle
            }
        }
    }

    func skip(_ r: ReleaseInfo) { skippedTag = r.tag }

    /// Snapshot/preview only: pretend `r` is the latest release.
    func preview(_ r: ReleaseInfo) { latest = r }

    func installAndRelaunch(_ r: ReleaseInfo) {
        let appPath = Bundle.main.bundlePath
        let kind = installKind
        let current = currentVersion
        let report: @Sendable (String) -> Void = { msg in Task { @MainActor in self.phase = .installing(msg) } }
        phase = .installing("Preparing…")
        Task {
            do {
                switch kind {
                case .homebrew(let brew): try await Updater.installHomebrew(brew: brew, progress: report)
                case .direct: try await Updater.installDirect(r, replacing: URL(fileURLWithPath: appPath), currentVersion: current, progress: report)
                case .unsupported(let why): throw UpdateError.install("Can't update in place: \(why). Download it from the release page.")
                }
                phase = .installing("Restarting…")
                Updater.relaunch(appPath: appPath)
                NSApp.terminate(nil)
            } catch {
                phase = .failed(error.localizedDescription)
            }
        }
    }
}

/// "MacLens X is available" window: version, changelog, Update and restart.
struct UpdateWindow: View {
    @EnvironmentObject var updates: UpdateStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let r = updates.latest, r.version > updates.currentVersion {
                content(r)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "checkmark.seal.fill").font(.largeTitle).foregroundStyle(VizColor.good)
                    Text("MacLens \(updates.currentVersionString) is up to date").font(.headline)
                    if let d = updates.lastChecked { Text("Last checked \(Fmt.relative(d))").foregroundStyle(.secondary) }
                    if case .checking = updates.phase { ProgressView().controlSize(.small) }
                    if let e = updates.lastError { Text(e).font(.caption).foregroundStyle(VizColor.critical) }
                    Button("Check again") { updates.check(userInitiated: true) }
                }
                .padding(30)
            }
        }
        .frame(width: 560)
    }

    @ViewBuilder private func content(_ r: ReleaseInfo) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 64, height: 64)
                VStack(alignment: .leading, spacing: 4) {
                    Text("MacLens \(r.version.description) is available").font(.title2.bold())
                    Text("You have \(updates.currentVersionString)" + (r.publishedAt.map { " · released \(Fmt.relative($0))" } ?? ""))
                        .foregroundStyle(.secondary)
                }
            }
            Text("What's new").font(.headline)
            ScrollView {
                ReleaseNotesView(markdown: r.notes).frame(maxWidth: .infinity, alignment: .leading).padding(10)
            }
            .frame(height: 220)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.08)))

            installNote
            HStack {
                Button("Skip this version") { updates.skip(r); dismiss() }
                Spacer()
                Link("Release page", destination: r.pageURL)
                Button("Later") { dismiss() }.keyboardShortcut(.cancelAction)
                if case .unsupported = updates.installKind {
                    Button("Download…") { NSWorkspace.shared.open(r.pageURL) }.buttonStyle(.borderedProminent)
                } else {
                    Button("Update and restart") { updates.installAndRelaunch(r) }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                        .disabled(isInstalling)
                }
            }
        }
        .padding(20)
    }

    private var isInstalling: Bool { if case .installing = updates.phase { return true }; return false }

    @ViewBuilder private var installNote: some View {
        switch updates.phase {
        case .installing(let msg):
            HStack { ProgressView().controlSize(.small); Text(msg) }
        case .failed(let msg):
            Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(VizColor.critical).font(.callout)
        default:
            switch updates.installKind {
            case .homebrew:
                Text("Installed with Homebrew — MacLens will run `brew upgrade --cask maclens`, then restart.").font(.caption).foregroundStyle(.secondary)
            case .direct:
                Text("MacLens downloads the release, checks its SHA-256 and code signature, replaces the app (the old copy goes to the Trash), then restarts. If you use Full Disk Access, re-enable it for the new version in System Settings.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .unsupported(let why):
                Text("Automatic install isn't available: \(why).").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Minimal renderer for release-please notes: headings, bullets, inline Markdown (links, code, bold).
struct ReleaseNotesView: View {
    let markdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            let lines = markdown.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if lines.isEmpty { Text("No release notes.").foregroundStyle(.secondary) }
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                if line.hasPrefix("## ") {
                    Text(inline(String(line.dropFirst(3)))).font(.headline)
                } else if line.hasPrefix("### ") {
                    Text(inline(String(line.dropFirst(4)))).font(.subheadline.weight(.semibold)).padding(.top, 4)
                } else if line.hasPrefix("* ") || line.hasPrefix("- ") {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•")
                        Text(inline(String(line.dropFirst(2))))
                    }
                } else {
                    Text(inline(line))
                }
            }
        }
        .textSelection(.enabled)
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

/// Dashboard banner shown while an update is available.
struct UpdateBanner: View {
    @EnvironmentObject var updates: UpdateStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let r = updates.available {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(VizColor.series1)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MacLens \(r.version.description) is available").font(.headline)
                    Text("You have \(updates.currentVersionString).").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("What's new…") { openWindow(id: "update") }
                Button("Update and restart") { updates.installAndRelaunch(r) }.buttonStyle(.borderedProminent)
                    .disabled({ if case .unsupported = updates.installKind { return true }; return false }())
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 8).fill(VizColor.series1.opacity(0.10)))
        }
    }
}

/// Settings → Updates.
struct UpdateSettingsSection: View {
    @EnvironmentObject var updates: UpdateStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Section("Updates") {
            LabeledContent("Version", value: "\(updates.currentVersionString) (build \(updates.buildNumber))")
            Toggle("Check for updates automatically (daily)", isOn: $updates.autoCheck)
            HStack {
                Button("Check now") { updates.check(userInitiated: true); openWindow(id: "update") }
                if case .checking = updates.phase { ProgressView().controlSize(.small) }
                Spacer()
                Text(updates.lastChecked.map { "Last checked \(Fmt.relative($0))" } ?? "Never checked").foregroundStyle(.secondary)
            }
            if let r = updates.available {
                Label("MacLens \(r.version.description) is available", systemImage: "arrow.down.circle.fill").foregroundStyle(VizColor.series1)
            }
            Text("Checks GitHub Releases once a day (one small request). " + installExplanation)
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var installExplanation: String {
        switch updates.installKind {
        case .homebrew: return "This copy was installed with Homebrew, so updates run `brew upgrade --cask maclens`."
        case .direct: return "Updates are downloaded, verified (SHA-256 + code signature) and installed in place."
        case .unsupported(let why): return "Automatic install is off: \(why)."
        }
    }
}
