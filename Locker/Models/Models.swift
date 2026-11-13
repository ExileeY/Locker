import Foundation

struct Repo: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var path: String
    var defaultBranch: String
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

struct AppState: Codable {
    static let currentSchema = 2
    var schemaVersion = AppState.currentSchema
    var repos: [Repo] = []
    var workspaces: [Workspace] = []

    init() {}

    /// Schema 1 workspaces had one mandatory branch per workspace. Migrate it to per-repo ownership.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let v = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        repos = try c.decodeIfPresent([Repo].self, forKey: .repos) ?? []
        workspaces = try c.decodeIfPresent([Workspace].self, forKey: .workspaces) ?? []
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
