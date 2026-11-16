import Foundation

/// Pure repo/project bookkeeping, kept out of `AppModel` so it is unit-testable without the UI.
extension AppState {
    /// Registered repos that no project contains.
    var unassignedRepos: [Repo] {
        let linked = Set(projects.flatMap(\.repoIDs))
        return repos.filter { !linked.contains($0.id) }
    }

    /// Adds the repo to the project. False if the project is missing or already has it.
    @discardableResult
    mutating func link(_ repoID: UUID, to projectID: UUID) -> Bool {
        guard let i = projects.firstIndex(where: { $0.id == projectID }),
              !projects[i].repoIDs.contains(repoID) else { return false }
        projects[i].repoIDs.append(repoID)
        return true
    }

    /// Removes the repo from the project and returns the position it held (for undo), or nil if it wasn't a member.
    @discardableResult
    mutating func unlink(_ repoID: UUID, from projectID: UUID) -> Int? {
        guard let i = projects.firstIndex(where: { $0.id == projectID }),
              let pos = projects[i].repoIDs.firstIndex(of: repoID) else { return nil }
        projects[i].repoIDs.remove(at: pos)
        return pos
    }

    /// Undo for `unlink`: puts the repo back at `position` (clamped).
    mutating func relink(_ repoID: UUID, to projectID: UUID, at position: Int) {
        guard let i = projects.firstIndex(where: { $0.id == projectID }),
              !projects[i].repoIDs.contains(repoID) else { return }
        projects[i].repoIDs.insert(repoID, at: min(position, projects[i].repoIDs.count))
    }

    /// False if the repo is unknown, the branch is blank, or nothing changes.
    @discardableResult
    mutating func setDefaultBranch(_ repoID: UUID, to branch: String) -> Bool {
        let b = branch.trimmingCharacters(in: .whitespaces)
        guard let i = repos.firstIndex(where: { $0.id == repoID }), !b.isEmpty, repos[i].defaultBranch != b else { return false }
        repos[i].defaultBranch = b
        return true
    }

    /// Replaces the repo's remembered carry-over paths. False if the repo is missing or nothing changed.
    @discardableResult
    mutating func setCarryOver(_ repoID: UUID, to paths: [String]) -> Bool {
        guard let i = repos.firstIndex(where: { $0.id == repoID }), repos[i].carryOver != paths else { return false }
        repos[i].carryOver = paths
        return true
    }

    /// "New project", "New project 2", ... the first name no project uses (case-insensitive).
    func newProjectName() -> String {
        var name = "New project", n = 2
        while projects.contains(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            name = "New project \(n)"; n += 1
        }
        return name
    }
}
