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

    /// Repos the grid offers: the selected project's members, or every repo when no project is selected.
    static func visibleRepos(project: UUID?, projects: [Project], repos: [Repo]) -> [Repo] {
        guard let project else { return repos }
        return projects.first { $0.id == project }?.members(in: repos) ?? repos
    }

    /// Selection after choosing a project: every usable member ticked. No project selected starts empty.
    static func selection(for project: UUID?, projects: [Project], repos: [Repo], isUsable: (Repo) -> Bool = { _ in true }) -> Set<UUID> {
        guard let project, let p = projects.first(where: { $0.id == project }) else { return [] }
        return p.selectableRepoIDs(in: repos, isUsable: isUsable)
    }

    /// The first thing blocking creation, or nil when the composer can create.
    static func validate(name: String, chosen: [Repo], branch: String, branchStates: [UUID: BranchState],
                         bases: [UUID: String]) -> ComposerIssue? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return .missingName }
        if chosen.isEmpty { return .noRepos }
        for r in chosen {
            if branch.isEmpty || branchStates[r.id] == .new, (bases[r.id] ?? r.defaultBranch).trimmingCharacters(in: .whitespaces).isEmpty {
                return .missingBase(repoName: r.name)
            }
        }
        return nil
    }
}

/// Why the composer can't create yet. Each case is shown next to the field it concerns.
enum ComposerIssue: Equatable {
    case missingName, noRepos, missingBase(repoName: String)

    var message: String {
        switch self {
        case .missingName: return "Enter a workspace name."
        case .noRepos: return "Select at least one repository."
        case .missingBase(let r): return "Enter a base branch for \(r) under Advanced."
        }
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
