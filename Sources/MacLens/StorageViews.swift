import AppKit
import SwiftUI
import MacLensCore

struct StorageView: View {
    @EnvironmentObject var disk: DiskStore
    @State private var selection: DiskItem.ID?
    @State private var sortOrder = [KeyPathComparator(\DiskItem.alloc, order: .reverse)]
    @State private var confirmTrash: DiskItem?
    @State private var error: String?

    var rows: [DiskItem] {
        let base = disk.items
        if sortOrder.first?.keyPath == \DiskItem.alloc && disk.showLogical {
            return base.sorted { sortOrder.first?.order == .reverse ? $0.logical > $1.logical : $0.logical < $1.logical }
        }
        return base.sorted(using: sortOrder)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("Scan", selection: Binding(get: { disk.target }, set: { disk.setTarget($0) })) {
                    Text("Home (~)").tag(DiskStore.Target.home)
                    Text("Macintosh HD (Data volume)").tag(DiskStore.Target.dataVolume)
                    if case .folder(let p) = disk.target { Text(PathUtil.abbreviate(p)).tag(disk.target) }
                }
                .frame(width: 280)
                .disabled(disk.scanning)
                Button("Choose Folder…") { chooseFolder() }.disabled(disk.scanning)
                if disk.scanning {
                    Button("Cancel") { disk.cancel() }
                } else {
                    Button(disk.tree == nil ? "Scan" : "Rescan") { disk.scan() }.keyboardShortcut("r").buttonStyle(.borderedProminent)
                }
                Spacer()
                Picker("", selection: $disk.showLogical) {
                    Text("On disk").tag(false)
                    Text("Logical").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 150)
                .help("On disk = allocated blocks (hard links counted once). Logical = file lengths.")
            }
            .padding(10)

            if disk.scanning {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("\(disk.progress.dirs) folders · \(disk.progress.files) files · \(Fmt.bytes(disk.progress.bytes))" +
                         (disk.progress.reused > 0 ? " · \(disk.progress.reused) unchanged folders reused" : ""))
                        .monospacedDigit()
                    Text(PathUtil.abbreviate(disk.progress.current)).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                    Spacer()
                }.padding(.horizontal, 10).padding(.bottom, 6)
            } else if !disk.status.isEmpty {
                HStack { Text(disk.status).foregroundStyle(.secondary); Spacer() }.font(.caption).padding(.horizontal, 10).padding(.bottom, 6)
            }

            if disk.tree != nil {
                HStack(spacing: 2) {
                    Button { disk.up() } label: { Image(systemName: "chevron.up") }.disabled(disk.current == 0).buttonStyle(.borderless)
                    ForEach(Array(disk.breadcrumbs.enumerated()), id: \.offset) { i, c in
                        if i > 0 { Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary) }
                        Button(c.0) { disk.open(c.1) }.buttonStyle(.borderless)
                    }
                    Spacer()
                    Text(Fmt.bytes(disk.currentTotal)).monospacedDigit().foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10).padding(.bottom, 6)
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
                    TableColumn("Name", value: \.name) { item in
                        HStack(spacing: 6) {
                            Image(systemName: item.isDirectory ? "folder.fill" : "doc").foregroundStyle(item.isDirectory ? .blue : .secondary)
                            Text(item.name).lineLimit(1)
                            if item.unreadable { Image(systemName: "lock.fill").foregroundStyle(.orange).help("Couldn't read this folder (permission / Full Disk Access)") }
                            if item.hardlinked { Image(systemName: "link").foregroundStyle(.secondary).help("Hard link — its bytes are shared with another path") }
                        }
                    }.width(min: 220, ideal: 340)
                    TableColumn("Size", value: \.alloc) { item in
                        Text(Fmt.bytes(disk.showLogical ? item.logical : item.alloc)).monospacedDigit()
                    }.width(90)
                    TableColumn("") { item in
                        let total = max(1, disk.currentTotal)
                        let frac = Double(disk.showLogical ? item.logical : item.alloc) / Double(total)
                        ProgressView(value: min(1, max(0, frac))).help(String(format: "%.1f%% of this folder", frac * 100))
                    }.width(90)
                    TableColumn("Items", value: \.items) { Text($0.isDirectory ? String($0.items) : "").monospacedDigit() }.width(70)
                    TableColumn("Modified", value: \.modified) { Text($0.modified.formatted(date: .abbreviated, time: .shortened)) }.width(140)
                }
                .contextMenu(forSelectionType: DiskItem.ID.self) { ids in
                    if let id = ids.first, let item = disk.items.first(where: { $0.id == id }) {
                        Button("Reveal in Finder") { reveal(item) }
                        if item.isDirectory { Button("Open") { disk.open(item.treeIndex) } }
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let item = disk.items.first(where: { $0.id == id }), item.isDirectory { disk.open(item.treeIndex) }
                }
                if let id = selection, let item = disk.items.first(where: { $0.id == id }) {
                    StorageDetail(item: item, onReveal: { reveal(item) }, onTrash: { confirmTrash = item })
                }
            } else if !disk.scanning {
                ContentUnavailableView("No scan yet", systemImage: "internaldrive",
                                       description: Text("Choose what to scan and press Scan. Results are cached, so a rescan only re-reads folders that changed."))
            } else {
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear { disk.loadCachedIfNeeded() }
        .alert("Move to Trash?", isPresented: Binding(get: { confirmTrash != nil }, set: { if !$0 { confirmTrash = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let i = confirmTrash { error = disk.trash(i); selection = nil }
                confirmTrash = nil
            }
            Button("Cancel", role: .cancel) { confirmTrash = nil }
        } message: {
            if let i = confirmTrash { Text("\(i.path)\n\(Fmt.bytes(i.alloc)) on disk\(i.isDirectory ? ", \(i.items) items" : "")") }
        }
        .alert("Couldn't move to Trash", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func reveal(_ item: DiskItem) { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)]) }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { disk.setTarget(.folder(url.path)) }
    }
}

struct StorageDetail: View {
    let item: DiskItem
    let onReveal: () -> Void
    let onTrash: () -> Void

    var body: some View {
        let verdict = DeletionGuard.check(item.path)
        HStack(alignment: .top, spacing: 20) {
            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 3) {
                GridRow { Text("Path").foregroundStyle(.secondary); Text(item.path).textSelection(.enabled).lineLimit(2) }
                GridRow { Text("Size").foregroundStyle(.secondary); Text("\(Fmt.bytes(item.alloc)) on disk · \(Fmt.bytes(item.logical)) logical") }
                if item.isDirectory { GridRow { Text("Items").foregroundStyle(.secondary); Text("\(item.items) (files and folders, recursive)") } }
                GridRow { Text("Modified").foregroundStyle(.secondary); Text(Fmt.date(item.modified)) }
            }
            .font(.callout)
            Spacer()
            VStack(alignment: .trailing) {
                Button("Reveal in Finder", action: onReveal)
                GuardedButton(title: "Move to Trash…", verdict: verdict, action: onTrash)
            }
        }
        .padding(10)
        .background(.bar)
    }
}

/// A delete button that is disabled — with the reason on hover — when the deletion guard blocks the path.
struct GuardedButton: View {
    let title: String
    let verdict: DeletionVerdict
    var role: ButtonRole? = .destructive
    let action: () -> Void

    var body: some View {
        // Wrapped so the tooltip still shows while the button itself is disabled.
        HStack {
            Button(title, role: role, action: action).disabled(!verdict.isAllowed)
        }
        .contentShape(Rectangle())
        .help(verdict.reason.map { "Can't delete: \($0)" } ?? "Moves the item to the Trash (recoverable).")
    }
}
