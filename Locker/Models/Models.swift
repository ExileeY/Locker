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
