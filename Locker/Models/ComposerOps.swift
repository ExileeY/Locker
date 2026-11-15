import Foundation

/// Pure selection logic for the new-workspace composer, kept out of the view so it is unit-testable.
enum ComposerOps {
    /// Repos whose name or path contains `query` (case-insensitive). An empty query returns all.
    static func filter(_ repos: [Repo], query: String) -> [Repo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return repos }
        return repos.filter { $0.name.localizedCaseInsensitiveContains(q) || $0.path.localizedCaseInsensitiveContains(q) }
    }

    /// All/None: ticks or clears only the `shown` repos that pass `isUsable`. Hidden repos keep their state.
    static func setAll(_ chosen: Set<UUID>, shown: [Repo], on: Bool, isUsable: (Repo) -> Bool = { _ in true }) -> Set<UUID> {
        let ids = shown.filter(isUsable).map(\.id)
        return on ? chosen.union(ids) : chosen.subtracting(ids)
    }

    /// A project chip is "on" when every usable member is ticked (and it has at least one).
    static func isProjectOn(_ p: Project, chosen: Set<UUID>, repos: [Repo], isUsable: (Repo) -> Bool = { _ in true }) -> Bool {
        let ids = p.selectableRepoIDs(in: repos, isUsable: isUsable)
        return !ids.isEmpty && ids.isSubset(of: chosen)
    }

    /// Clicking a chip ticks the project's usable repos; clicking it again (when on) clears them.
    static func toggleProject(_ p: Project, chosen: Set<UUID>, repos: [Repo], isUsable: (Repo) -> Bool = { _ in true }) -> Set<UUID> {
        let ids = p.selectableRepoIDs(in: repos, isUsable: isUsable)
        return isProjectOn(p, chosen: chosen, repos: repos, isUsable: isUsable) ? chosen.subtracting(ids) : chosen.union(ids)
    }
}

extension Workspace {
    /// Sidebar search: name, branch summary, or any repo name (case-insensitive). Empty query matches.
    func matches(_ query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return true }
        return name.localizedCaseInsensitiveContains(q)
            || repos.contains { $0.repoName.localizedCaseInsensitiveContains(q) || $0.summary.localizedCaseInsensitiveContains(q) }
    }
}
