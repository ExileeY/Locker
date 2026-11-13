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

    init(repoID: UUID, repoName: String, worktreePath: String, baseBranch: String, branchPreexisting: Bool = false) {
        self.repoID = repoID; self.repoName = repoName; self.worktreePath = worktreePath
        self.baseBranch = baseBranch; self.branchPreexisting = branchPreexisting
    }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        repoID = try c.decode(UUID.self, forKey: .repoID)
        repoName = try c.decode(String.self, forKey: .repoName)
        worktreePath = try c.decode(String.self, forKey: .worktreePath)
        baseBranch = try c.decode(String.self, forKey: .baseBranch)
        branchPreexisting = try c.decodeIfPresent(Bool.self, forKey: .branchPreexisting) ?? false
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
    var branch: String
    var repos: [WorkspaceRepo]
    var terminals: [TerminalSpec]
    var activeTerminal: UUID?
    var root: String
}

struct AppState: Codable {
    var schemaVersion = 1
    var repos: [Repo] = []
    var workspaces: [Workspace] = []
}
