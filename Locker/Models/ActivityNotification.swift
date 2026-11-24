import Foundation

/// Decides when a workspace's Claude state change deserves a user notification. Pure, so it is unit-tested.
enum ActivityNotification {
    /// True only for `running → waiting`, with the toggle on, unless the user is already looking at that workspace.
    static func shouldNotify(old: ClaudeActivity, new: ClaudeActivity,
                             appActive: Bool, isVisibleWorkspace: Bool, enabled: Bool) -> Bool {
        enabled && old == .running && new == .waiting && !(appActive && isVisibleWorkspace)
    }

    struct Changes: Equatable {
        /// Workspaces that just started waiting for input and should be announced.
        var notify: [UUID] = []
        /// Workspaces that left `.waiting`; any delivered banner for them is stale.
        var clear: [UUID] = []
    }

    /// Diffs two activity maps. A workspace missing from a map counts as `.none`.
    static func changes(old: [UUID: ClaudeActivity], new: [UUID: ClaudeActivity],
                        appActive: Bool, visibleWorkspace: UUID?, enabled: Bool) -> Changes {
        var result = Changes()
        for id in Set(old.keys).union(new.keys) {
            let o = old[id] ?? .none, n = new[id] ?? .none
            if shouldNotify(old: o, new: n, appActive: appActive, isVisibleWorkspace: id == visibleWorkspace, enabled: enabled) {
                result.notify.append(id)
            }
            if o == .waiting && n != .waiting { result.clear.append(id) }
        }
        return result
    }
}
