import Foundation

struct RepoSelection {
    var repo: Repo
    var base: String
}

struct DeleteWarning: Equatable {
    var repoName: String
    var dirty: Bool
    var ahead: Int
}

struct WorkspaceService {
    var git = GitClient()
    var lockerRoot: String

    init(git: GitClient = GitClient(), lockerRoot: String = NSHomeDirectory() + "/Locker") {
        self.git = git
        self.lockerRoot = lockerRoot
    }

    static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var out = ""
        for u in s.unicodeScalars { out += allowed.contains(u) ? String(u) : "-" }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        out = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return out.isEmpty ? "workspace" : out
    }

    /// Creates the workspace directory and one worktree per repo. Rolls back on any failure.
    func create(name: String, branch: String, selections: [RepoSelection], existingNames: [String]) throws -> Workspace {
        guard !selections.isEmpty else { throw GitError(command: "", output: "Select at least one repository.", status: 1) }
        guard git.isValidBranchName(branch) else {
            throw GitError(command: "", output: "“\(branch)” is not a valid branch name.", status: 1)
        }
        let root = lockerRoot + "/" + Self.slug(name)
        if FileManager.default.fileExists(atPath: root) || existingNames.contains(name) {
            throw GitError(command: "", output: "A workspace folder named “\(Self.slug(name))” already exists.", status: 1)
        }
        // Preflight: branch must not exist yet (git refuses one branch in two worktrees).
        for s in selections where git.branchExists(branch, in: s.repo.path) {
            throw GitError(command: "", output: "Branch “\(branch)” already exists in \(s.repo.name) (it may be checked out in another worktree). Choose a different branch name.", status: 1)
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        var created: [(Repo, String)] = []
        var links: [WorkspaceRepo] = []
        do {
            for s in selections {
                let path = root + "/" + s.repo.name
                try git.worktreeAdd(repo: s.repo.path, path: path, branch: branch, base: s.base)
                created.append((s.repo, path))
                links.append(WorkspaceRepo(repoID: s.repo.id, repoName: s.repo.name, worktreePath: path, baseBranch: s.base))
            }
        } catch {
            for (repo, path) in created {
                try? git.worktreeRemove(repo: repo.path, path: path, force: true)
                git.deleteBranch(repo: repo.path, branch: branch)
            }
            try? fm.removeItem(atPath: root)
            throw error
        }
        let terms = links.map { TerminalSpec(title: $0.repoName, cwd: $0.worktreePath, repoLabel: $0.repoName) }
        return Workspace(name: name, branch: branch, repos: links, terminals: terms,
                         activeTerminal: terms.first?.id, root: root)
    }

    func deleteWarnings(_ ws: Workspace) -> [DeleteWarning] {
        ws.repos.compactMap { r in
            guard FileManager.default.fileExists(atPath: r.worktreePath) else { return nil }
            let dirty = (try? git.status(r.worktreePath).dirty) ?? false
            let ahead = git.aheadCount(r.worktreePath, base: r.baseBranch)
            return (dirty || ahead > 0) ? DeleteWarning(repoName: r.repoName, dirty: dirty, ahead: ahead) : nil
        }
    }

    /// Removes worktrees. Branches that carry commits not on base are kept so no work is lost.
    func delete(_ ws: Workspace, repos: [Repo]) {
        for r in ws.repos {
            guard let repo = repos.first(where: { $0.id == r.repoID }) else { continue }
            let ahead = git.aheadCount(r.worktreePath, base: r.baseBranch)
            try? git.worktreeRemove(repo: repo.path, path: r.worktreePath, force: true)
            git.prune(repo: repo.path)
            if ahead == 0 { git.deleteBranch(repo: repo.path, branch: ws.branch) }
        }
        try? FileManager.default.removeItem(atPath: ws.root)
    }

    /// Runs `git switch -c` in every worktree of the workspace.
    func createBranch(_ name: String, in ws: Workspace) throws {
        guard git.isValidBranchName(name) else {
            throw GitError(command: "", output: "“\(name)” is not a valid branch name.", status: 1)
        }
        for r in ws.repos where git.branchExists(name, in: r.worktreePath) {
            throw GitError(command: "", output: "Branch “\(name)” already exists in \(r.repoName).", status: 1)
        }
        var done: [WorkspaceRepo] = []
        do {
            for r in ws.repos {
                try git.switchCreate(name, in: r.worktreePath)
                done.append(r)
            }
        } catch {
            for r in done {
                _ = try? git.run(["switch", "-"], in: r.worktreePath)
                git.deleteBranch(repo: r.worktreePath, branch: name)
            }
            throw error
        }
    }

    /// Worktrees whose directory is gone or no longer registered with git.
    func missingWorktrees(_ ws: Workspace, repos: [Repo]) -> [WorkspaceRepo] {
        ws.repos.filter { r in
            guard FileManager.default.fileExists(atPath: r.worktreePath) else { return true }
            guard let repo = repos.first(where: { $0.id == r.repoID }),
                  let list = try? git.worktreeList(repo: repo.path) else { return false }
            let real = URL(fileURLWithPath: r.worktreePath).resolvingSymlinksInPath().path
            return !list.contains { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path == real }
        }
    }
}
