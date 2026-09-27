import AppKit
import SwiftUI
import MacLensCore

extension Artifact {
    var kindName: String { kind.displayName }
    var lastActivitySort: Date { lastActivity ?? .distantPast }
}

struct ArtifactsView: View {
    @EnvironmentObject var store: ArtifactStore
    @State private var selection = Set<Artifact.ID>()
    @State private var sortOrder = [KeyPathComparator(\Artifact.allocSize, order: .reverse)]
    @State private var confirm: DeleteMode?
    @State private var outcome: String?

    var rows: [Artifact] { store.filtered.sorted(using: sortOrder) }
    var selected: [Artifact] { rows.filter { selection.contains($0.id) } }

    var body: some View {
        let rows = self.rows
        VStack(spacing: 0) {
            header
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Type", value: \.kindName) { a in
                    HStack(spacing: 4) {
                        if let r = store.verdict(a).reason { Image(systemName: "lock.fill").foregroundStyle(.orange).help("Can't delete: \(r)") }
                        Text(a.kind.displayName)
                        if a.kind.isGlobalCache { Image(systemName: "globe").foregroundStyle(.secondary).help("Shared cache: " + (a.kind.redownloadWarning ?? "")) }
                    }.help("Detected as " + a.kind.detectionRule)
                }.width(min: 120, ideal: 150)
                TableColumn("Size", value: \.allocSize) { Text(Fmt.bytes($0.allocSize)).monospacedDigit() }.width(80)
                TableColumn("Reclaimable", value: \.reclaimable) { a in
                    Text(Fmt.bytes(a.reclaimable)).monospacedDigit()
                        .help("Estimated space freed by deleting it. Excludes hard-linked files (e.g. pnpm store links) and blocks shared with APFS clones. Local snapshots can delay the space being freed.")
                }.width(90)
                TableColumn("Project", value: \.projectName) { a in Text(a.projectName).help(a.projectPath ?? "") }.width(min: 100, ideal: 150)
                TableColumn("Last activity", value: \.lastActivitySort) { a in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(Fmt.relative(a.lastActivity))
                        Text(a.lastActivitySource).font(.caption2).foregroundStyle(.secondary)
                    }
                    .help(activityHelp(a))
                }.width(min: 110, ideal: 140)
                TableColumn("Path", value: \.path) { a in
                    Text(PathUtil.abbreviate(a.path)).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle).help(a.path)
                }
            }
            .contextMenu(forSelectionType: Artifact.ID.self) { ids in
                Button("Reveal in Finder") { reveal(ids) }
            } primaryAction: { ids in reveal(ids) }
            footer(rows)
        }
        .sheet(item: Binding(get: { confirm.map(ModeBox.init) }, set: { confirm = $0?.mode })) { box in
            DeleteConfirmSheet(items: selected, mode: box.mode, verdict: store.verdict) { mode in
                let targets = selected.filter { store.verdict($0).isAllowed }
                confirm = nil
                store.delete(targets, mode: mode) { results in
                    let failed = results.filter { $0.error != nil }
                    selection.subtract(results.filter { $0.error == nil }.map(\.path))
                    outcome = failed.isEmpty ? nil : failed.map { "\(PathUtil.abbreviate($0.path)): \($0.error!)" }.joined(separator: "\n")
                }
            } onCancel: { confirm = nil }
        }
        .alert("Some items couldn't be deleted", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK") { outcome = nil }
        } message: { Text(outcome ?? "") }
    }

    /// Two left-aligned rows: what to scan (+ scan status), then how to filter the results.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Menu {
                    ForEach(store.roots, id: \.self) { r in
                        Button("Remove \(PathUtil.abbreviate(r))") { store.roots.removeAll { $0 == r } }.disabled(store.roots.count == 1)
                    }
                    Divider()
                    Button("Add Folder…") { addRoot() }
                } label: {
                    Label("Search in: " + store.roots.map(PathUtil.abbreviate).joined(separator: ", "), systemImage: "folder")
                }
                .fixedSize()
                .disabled(store.scanning)
                if store.scanning {
                    Button("Cancel") { store.cancel() }
                    ProgressView().controlSize(.small)
                    Text("\(store.progress.dirs) folders · \(Fmt.bytes(store.progress.bytes))").monospacedDigit()
                    Text(PathUtil.abbreviate(store.progress.current)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                } else {
                    Button(store.result == nil ? "Scan" : "Rescan") { store.scan() }.buttonStyle(.borderedProminent).keyboardShortcut("r")
                    Text(store.status).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 10) {
                Menu("Types (\(store.kinds.count)/\(ArtifactKind.allCases.count))") {
                    Button("All") { store.kinds = Set(ArtifactKind.allCases) }
                    Button("None") { store.kinds = [] }
                    Divider()
                    ForEach(ArtifactKind.allCases, id: \.self) { k in
                        Toggle(k.displayName, isOn: Binding(get: { store.kinds.contains(k) }, set: { on in if on { store.kinds.insert(k) } else { store.kinds.remove(k) } }))
                    }
                }
                .fixedSize()
                Divider().frame(height: 18)
                Toggle("Not used in", isOn: $store.olderThanEnabled).toggleStyle(.checkbox)
                TextField("", value: $store.olderThanDays, format: .number)
                    .frame(width: 56).textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                    .disabled(!store.olderThanEnabled)
                Stepper("", value: $store.olderThanDays, in: 1...3650, step: 7).labelsHidden().disabled(!store.olderThanEnabled)
                Text("days").foregroundStyle(store.olderThanEnabled ? .primary : .secondary)
                Spacer(minLength: 12)
                TextField("Filter by path or project", text: $store.search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func footer(_ rows: [Artifact]) -> some View {
        let sel = selected
        let blocked = sel.filter { !store.verdict($0).isAllowed }
        let reason = sel.isEmpty ? "Select one or more items" :
            (blocked.count == sel.count ? "Can't delete: " + (store.verdict(blocked[0]).reason ?? "") : nil)
        return HStack {
            Text("\(rows.count) items · \(Fmt.bytes(rows.reduce(0) { $0 + $1.allocSize })) · reclaimable \(Fmt.bytes(rows.reduce(0) { $0 + $1.reclaimable }))")
            if !sel.isEmpty {
                Text("· selected \(sel.count): \(Fmt.bytes(sel.reduce(0) { $0 + $1.reclaimable })) reclaimable").bold()
            }
            Spacer()
            if store.deleting { ProgressView().controlSize(.small); Text("Deleting…") }
            Button("Reveal in Finder") { reveal(Set(sel.map(\.id))) }.disabled(sel.isEmpty)
            HStack {
                Button("Move to Trash…") { confirm = .trash }.disabled(reason != nil || store.deleting)
                Button("Delete Permanently…", role: .destructive) { confirm = .permanent }.disabled(reason != nil || store.deleting)
            }
            .contentShape(Rectangle())
            .help(reason ?? "Trash is recoverable; Delete Permanently is not.")
        }
        .font(.callout)
        .padding(10)
        .background(.bar)
    }

    private func activityHelp(_ a: Artifact) -> String {
        var lines = ["Most recent of the dates below. macOS doesn't reliably record when a folder was last opened (APFS rarely updates access times), so this is based on modifications."]
        if let d = a.projectActivity { lines.append("Project files modified: \(Fmt.date(d))") }
        if let d = a.gitActivity { lines.append("Git activity (commit/checkout/index): \(Fmt.date(d))") }
        if let d = a.newestInside { lines.append("Newest item inside: \(Fmt.date(d))") }
        return lines.joined(separator: "\n")
    }

    private func reveal(_ ids: Set<Artifact.ID>) {
        NSWorkspace.shared.activateFileViewerSelecting(ids.map { URL(fileURLWithPath: $0) })
    }

    private func addRoot() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            for u in p.urls where !store.roots.contains(u.path) { store.roots.append(u.path) }
        }
    }
}

private struct ModeBox: Identifiable {
    let mode: DeleteMode
    var id: String { mode == .trash ? "trash" : "permanent" }
}

struct DeleteConfirmSheet: View {
    let items: [Artifact]
    let mode: DeleteMode
    let verdict: (Artifact) -> DeletionVerdict
    let onConfirm: (DeleteMode) -> Void
    let onCancel: () -> Void

    var body: some View {
        let allowed = items.filter { verdict($0).isAllowed }
        let blocked = items.filter { !verdict($0).isAllowed }
        let warnings = Set(allowed.compactMap { $0.kind.redownloadWarning })
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .trash ? "Move \(allowed.count) items to the Trash?" : "Permanently delete \(allowed.count) items?")
                .font(.title3.bold())
            Text("Total \(Fmt.bytes(allowed.reduce(0) { $0 + $1.allocSize })) · about \(Fmt.bytes(allowed.reduce(0) { $0 + $1.reclaimable })) will be freed")
            if mode == .permanent {
                Label("This bypasses the Trash and cannot be undone.", systemImage: "exclamationmark.octagon.fill").foregroundStyle(.red)
            }
            ForEach(Array(warnings).sorted(), id: \.self) { w in
                Label(w, systemImage: "arrow.down.circle").foregroundStyle(.orange)
            }
            List {
                ForEach(allowed) { a in
                    HStack {
                        Text(a.path).font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Text(Fmt.bytes(a.allocSize)).monospacedDigit()
                    }
                }
                if !blocked.isEmpty {
                    Section("Skipped (protected)") {
                        ForEach(blocked) { a in
                            Text("\(a.path) — \(verdict(a).reason ?? "")").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .frame(minHeight: 180, maxHeight: 320)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel).keyboardShortcut(.cancelAction)
                Button(mode == .trash ? "Move to Trash" : "Delete Permanently", role: .destructive) { onConfirm(mode) }
                    .disabled(allowed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 640)
    }
}

struct SettingsView: View {
    @EnvironmentObject var settings: Settings
    @EnvironmentObject var model: AppModel
    @State private var hasFDA = FullDiskAccess.granted()

    var body: some View {
        Form {
            UpdateSettingsSection()
            Section("Refresh") {
                Picker("While the window is visible", selection: $settings.refreshInterval) {
                    ForEach([1.0, 2.0, 3.0, 5.0, 10.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Picker("In the background (menu bar only)", selection: $settings.backgroundInterval) {
                    ForEach([5.0, 10.0, 30.0, 60.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
                }
                Text("In the background MacLens reads only your own processes, battery and power assertions; other users' processes are refreshed every 30 s. Ports and temperatures are read only while their tab is open.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Notifications") {
                Toggle("Notify when thermal state becomes Serious or Critical", isOn: $settings.notifyThermal)
                Toggle("Notify about runaway processes", isOn: $settings.notifyRunaway)
                HStack {
                    Text("CPU above")
                    TextField("", value: $settings.runawayCPU, format: .number).frame(width: 60).textFieldStyle(.roundedBorder)
                    Text("% of one core for")
                    Picker("", selection: $settings.runawayMinutes) {
                        ForEach([1.0, 2.0, 3.0, 5.0], id: \.self) { Text("\(Int($0)) min").tag($0) }
                    }.frame(width: 90)
                }.disabled(!settings.notifyRunaway)
            }
            Section("Battery alerts") {
                Toggle("Notify when the battery reaches these levels", isOn: $settings.notifyBattery)
                HStack {
                    Text("Low — while on battery")
                    Spacer()
                    Text("\(settings.batteryLow)%").monospacedDigit()
                    Stepper("Low", value: $settings.batteryLow, in: 5...(settings.batteryHigh - 5), step: 5).labelsHidden()
                }
                .disabled(!settings.notifyBattery)
                HStack {
                    Text("High — while charging")
                    Spacer()
                    Text("\(settings.batteryHigh)%").monospacedDigit()
                    Stepper("High", value: $settings.batteryHigh, in: (settings.batteryLow + 5)...100, step: 5).labelsHidden()
                }
                .disabled(!settings.notifyBattery)
                Button("Send test alert") { model.notifier.sendTest() }
                    .help("If nothing appears, allow MacLens in System Settings → Notifications.")
                Text("Each alert fires once when the level is reached. It fires again only after the battery moves back past the level (e.g. charged above \(settings.batteryLow + 2)% before another low alert).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Permissions") {
                LabeledContent("Full Disk Access") {
                    Text(hasFDA ? "Granted" : "Not granted").foregroundStyle(hasFDA ? .green : .orange)
                }
                Text("Needed only to size protected folders (Mail, Safari, other apps' containers) in Storage scans. Everything else works without it. No feature needs root.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Open Full Disk Access settings") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                }
                Button("Re-check") { hasFDA = FullDiskAccess.granted() }
            }
            Section("Definitions") {
                Text(SystemClassifier.definition).font(.caption)
                Text(DeletionGuard.summary).font(.caption)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settings.refreshInterval) { model.settingsChanged() }
        .onChange(of: settings.backgroundInterval) { model.settingsChanged() }
        .onChange(of: settings.runawayCPU) { model.settingsChanged() }
        .onChange(of: settings.runawayMinutes) { model.settingsChanged() }
        .onChange(of: settings.notifyRunaway) { if settings.notifyRunaway { model.notifier.requestAuthorization() } }
        .onChange(of: settings.notifyThermal) { if settings.notifyThermal { model.notifier.requestAuthorization() } }
        .onChange(of: settings.notifyBattery) { if settings.notifyBattery { model.notifier.requestAuthorization() } }
    }
}

enum FullDiskAccess {
    /// ~/Library/Safari is TCC-protected; listing it succeeds only with Full Disk Access.
    static func granted() -> Bool {
        let fd = BulkDir.open(PathUtil.join(PathUtil.home, "Library/Safari"))
        if fd >= 0 { close(fd); return true }
        return false
    }
}
