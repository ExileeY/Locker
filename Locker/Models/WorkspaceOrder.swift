import Foundation

/// Pure reordering logic for the sidebar's workspace list, kept out of the view so it is unit-testable.
/// The display order is simply the array order of `AppState.workspaces`.
enum WorkspaceOrder {
    /// Moves `id` so it sits just before `target`. A nil or unknown `target` moves it to the end.
    /// An unknown `id`, or dropping a workspace onto itself, returns the list unchanged.
    static func move(_ list: [Workspace], id: UUID, before target: UUID?) -> [Workspace] {
        guard id != target, let from = list.firstIndex(where: { $0.id == id }) else { return list }
        var out = list
        let item = out.remove(at: from)
        let to = target.flatMap { t in out.firstIndex { $0.id == t } } ?? out.endIndex
        out.insert(item, at: to)
        return out
    }

    /// Moves `id` one place up (`-1`) or down (`+1`). At the edge the list is unchanged.
    static func shift(_ list: [Workspace], id: UUID, by delta: Int) -> [Workspace] {
        guard let i = list.firstIndex(where: { $0.id == id }) else { return list }
        let j = i + delta
        guard list.indices.contains(j) else { return list }
        // Moving up goes before the previous row; moving down goes before the row two places on (nil = end).
        let target: UUID? = delta < 0 ? list[j].id : (j + 1 < list.count ? list[j + 1].id : nil)
        return move(list, id: id, before: target)
    }
}
