import SwiftUI

/// A table row identified by its position in the sorted list, not by the item's own ID.
///
/// With item IDs, every re-sort (or reshuffle between refreshes) became one NSTableView move per row, and moving a
/// row makes AppKit build its cells even off screen: sorting ~700 processes froze the UI and left ~400 MB of cells
/// behind (#32). By position, a re-sort is an in-place update that only refreshes the visible rows.
/// Selections keep the item's own ID (see the `selection` adapters), so they stay on the same item as rows move.
struct PositionRow<Item: Identifiable>: Identifiable {
    let id: Int
    let item: Item

    static func sorted(_ items: [Item], by order: [KeyPathComparator<PositionRow>]) -> [PositionRow] {
        numbered(items.map { PositionRow(id: 0, item: $0) }.sorted(using: order).map(\.item))
    }

    static func numbered(_ items: [Item]) -> [PositionRow] {
        items.enumerated().map { PositionRow(id: $0.offset, item: $0.element) }
    }
}

extension Array {
    /// The items at these row positions (e.g. from a context menu), in row order.
    func items<Item>(at positions: Set<Int>) -> [Item] where Element == PositionRow<Item> {
        positions.sorted().compactMap { indices.contains($0) ? self[$0].item : nil }
    }

    /// Adapts a single selection stored as the item's ID to the table's row positions.
    func selection<Item>(_ id: Binding<Item.ID?>) -> Binding<Int?> where Element == PositionRow<Item> {
        Binding(get: { id.wrappedValue.flatMap { sel in firstIndex { $0.item.id == sel } } },
                set: { p in id.wrappedValue = p.flatMap { indices.contains($0) ? self[$0].item.id : nil } })
    }

    /// Adapts a multiple selection stored as item IDs to the table's row positions.
    func selection<Item>(_ ids: Binding<Set<Item.ID>>) -> Binding<Set<Int>> where Element == PositionRow<Item> {
        Binding(get: { Set(indices.filter { ids.wrappedValue.contains(self[$0].item.id) }) },
                set: { ps in
                    // Keep selected items that aren't in the current rows (e.g. hidden by a filter), like an ID-based table.
                    let visible = Set(map(\.item.id))
                    ids.wrappedValue = ids.wrappedValue.subtracting(visible).union(items(at: ps).map(\.id))
                })
    }
}
