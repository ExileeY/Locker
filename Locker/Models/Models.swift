import Foundation

struct Repo: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var defaultBranch: String
}

/// A named group of repos. Only a selection shortcut: workspaces do not remember the project they were created from.
struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var repoIDs: [UUID] = []

    init(id: UUID = UUID(), name: String, repoIDs: [UUID] = []) {
        self.id = id; self.name = name; self.repoIDs = repoIDs
    }

    /// Lenient: a malformed project must never make `Store.load()` fall back to an empty state.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled project"
        repoIDs = (try? c.decodeIfPresent([UUID].self, forKey: .repoIDs)) ?? []
    }

    /// Member repos that still exist, in the project's order, as `all` registers them.
    func members(in all: [Repo]) -> [Repo] {
        let ids = Set(repoIDs)
        return all.filter { ids.contains($0.id) }
    }

    /// IDs of members that exist and pass `isUsable` (e.g. the folder is still on disk).
    func selectableRepoIDs(in all: [Repo], isUsable: (Repo) -> Bool = { _ in true }) -> Set<UUID> {
        Set(members(in: all).filter(isUsable).map(\.id))
    }
}

struct WorkspaceRepo: Codable, Identifiable, Hashable {
    var id = UUID()
    var repoID: UUID
    var repoName: String
    var worktreePath: String
    var baseBranch: String
}

struct TerminalSpec: Codable, Identifiable, Hashable {
    var id = UUID()
    var title: String
    var cwd: String
    var repoLabel: String?
}

struct Workspace: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var branch: String
    var repos: [WorkspaceRepo]
    var terminals: [TerminalSpec]
    var activeTerminal: UUID?
    var root: String
}

struct AppState: Codable {
<<<<<<< Updated upstream
    var schemaVersion = 1
=======
    static let currentSchema = 3
    var schemaVersion = AppState.currentSchema
>>>>>>> Stashed changes
    var repos: [Repo] = []
    var projects: [Project] = []
    var workspaces: [Workspace] = []
<<<<<<< Updated upstream
=======

    init() {}

    /// Drops a repo from every project. Called when the repo is unregistered.
    mutating func removeRepoFromProjects(_ repoID: UUID) {
        for i in projects.indices { projects[i].repoIDs.removeAll { $0 == repoID } }
    }

    /// Schema 1 workspaces had one mandatory branch per workspace. Migrate it to per-repo ownership.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        repos = try c.decodeIfPresent([Repo].self, forKey: .repos) ?? []
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        projects = (try? c.decodeIfPresent([Project].self, forKey: .projects)) ?? []
        if v < 2 {
            for i in workspaces.indices {
                guard let b = workspaces[i].branch else { continue }
                for j in workspaces[i].repos.indices {
                    workspaces[i].repos[j].lastBranch = b
                    if !workspaces[i].repos[j].branchPreexisting { workspaces[i].repos[j].ownedBranches = [b] }
                }
            }
        }
        schemaVersion = AppState.currentSchema
    }
>>>>>>> Stashed changes
}
