import Foundation

struct Repo: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var defaultBranch: String
    /// Git-ignored paths (relative to `path`, folders end in "/") last chosen to copy into new workspaces.
    var carryOver: [String] = []

    init(id: UUID = UUID(), name: String, path: String, defaultBranch: String, carryOver: [String] = []) {
        self.id = id; self.name = name; self.path = path; self.defaultBranch = defaultBranch; self.carryOver = carryOver
    }

    /// Lenient for `carryOver` only (added in schema 4): a bad value there must not drop the repo.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        path = try c.decode(String.self, forKey: .path)
        defaultBranch = try c.decode(String.self, forKey: .defaultBranch)
        carryOver = (try? c.decodeIfPresent([String].self, forKey: .carryOver)) ?? []
    }
}

/// A named group of repos. Only a selection shortcut: workspaces do not remember the project they were created from.
struct Project: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var repoIDs: [UUID] = []
    /// When on, workspaces containing one of this project's repos get Claude Code hooks for exact highlighting.
    var exactHighlight = false

    init(id: UUID = UUID(), name: String, repoIDs: [UUID] = [], exactHighlight: Bool = false) {
        self.id = id; self.name = name; self.repoIDs = repoIDs; self.exactHighlight = exactHighlight
    }

    /// Lenient: a malformed project must never make `Store.load()` fall back to an empty state.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = (try? c.decodeIfPresent(UUID.self, forKey: .id)) ?? UUID()
        name = (try? c.decodeIfPresent(String.self, forKey: .name)) ?? "Untitled project"
        repoIDs = (try? c.decodeIfPresent([UUID].self, forKey: .repoIDs)) ?? []
        exactHighlight = (try? c.decodeIfPresent(Bool.self, forKey: .exactHighlight)) ?? false
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
    /// True when the branch existed before Locker used it; Locker must never delete it.
    var branchPreexisting = false
    /// Branches Locker created in this repo. They are deleted with the workspace unless they carry unmerged commits.
    var ownedBranches: [String] = []
    /// Last branch seen checked out in this worktree; nil while HEAD is detached. Used by repair and summaries.
    var lastBranch: String?

    init(repoID: UUID, repoName: String, worktreePath: String, baseBranch: String, branchPreexisting: Bool = false,
         ownedBranches: [String] = [], lastBranch: String? = nil) {
        self.repoID = repoID; self.repoName = repoName; self.worktreePath = worktreePath
        self.baseBranch = baseBranch; self.branchPreexisting = branchPreexisting
        self.ownedBranches = ownedBranches; self.lastBranch = lastBranch
    }

    /// What this repo is on, for display: the branch, or "<base> (detached)".
    var summary: String { lastBranch ?? "\(baseBranch) (detached)" }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        repoID = try c.decode(UUID.self, forKey: .repoID)
        repoName = try c.decode(String.self, forKey: .repoName)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        branchPreexisting = try c.decodeIfPresent(Bool.self, forKey: .branchPreexisting) ?? false
        ownedBranches = try c.decodeIfPresent([String].self, forKey: .ownedBranches) ?? []
        lastBranch = try c.decodeIfPresent(String.self, forKey: .lastBranch)
    }
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
    /// Branch requested at creation; nil when the workspace started detached at the default branch. Informational only.
    var branch: String?
    var repos: [WorkspaceRepo]
    var terminals: [TerminalSpec]
    var activeTerminal: UUID?
    var root: String

    /// One branch name when every repo agrees, otherwise "mixed".
    var branchSummary: String {
        let all = Set(repos.map(\.summary))
        return all.count == 1 ? all.first! : (all.isEmpty ? "no repos" : "mixed")
    }
}

/// Where a new workspace's repos start: the local branch as it is, or `origin/<branch>` after a fetch.
enum BaseSource: String, Codable, CaseIterable {
    case origin, local
}

/// User choices Locker remembers between sessions. Every field is optional on disk so older files still load.
struct Preferences: Codable, Equatable {
    var baseSource: BaseSource = .origin
    /// Post a notification when a workspace's Claude session starts waiting for the user.
    var notifyOnNeedsInput = true

    init() {}

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        baseSource = (try? c.decodeIfPresent(BaseSource.self, forKey: .baseSource)) ?? .origin
        notifyOnNeedsInput = (try? c.decodeIfPresent(Bool.self, forKey: .notifyOnNeedsInput)) ?? true
    }
}

struct AppState: Codable {
    static let currentSchema = 4
    var schemaVersion = AppState.currentSchema
    var repos: [Repo] = []
    var projects: [Project] = []
    var workspaces: [Workspace] = []
    var preferences = Preferences()

    init() {}

    /// Drops a repo from every project. Called when the repo is unregistered.
    mutating func removeRepoFromProjects(_ repoID: UUID) {
        for i in projects.indices { projects[i].repoIDs.removeAll { $0 == repoID } }
    }

    /// Schema 1 workspaces had one mandatory branch per workspace. Migrate it to per-repo ownership.
    /// Schema 3 added projects; older files simply have none. Schema 4 added `Repo.carryOver` (empty when absent).
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        repos = try c.decodeIfPresent([Repo].self, forKey: .repos) ?? []
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
        projects = (try? c.decodeIfPresent([Project].self, forKey: .projects)) ?? []
        preferences = (try? c.decodeIfPresent(Preferences.self, forKey: .preferences)) ?? Preferences()
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
}
