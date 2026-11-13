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

enum BranchState { case new, existing, remote }

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
    /// If the branch already exists in a repo it is checked out as is; otherwise it is created from the base.
    func create(name: String, branch: String, selections: [RepoSelection], existingNames: [String],
                progress: (String) -> Void = { _ in }) throws -> Workspace {
        guard !selections.isEmpty else { throw GitError(command: "", output: "Select at least one repository.", status: 1) }
        guard git.isValidBranchName(branch) else {
            throw GitError(command: "", output: "“\(branch)” is not a valid branch name.", status: 1)
        }
        let root = lockerRoot + "/" + Self.slug(name)
        if FileManager.default.fileExists(atPath: root) || existingNames.contains(name) {
            throw GitError(command: "", output: "A workspace folder named “\(Self.slug(name))” already exists.", status: 1)
        }
        // Preflight: decide per repo whether to attach an existing branch or create a new one.
        enum Plan { case new, existing, tracking }
        var plans: [Plan] = []
        for s in selections {
            if git.branchExists(branch, in: s.repo.path) {
                if let at = git.checkedOutBranches(repo: s.repo.path)[branch] {
                    throw GitError(command: "", output: "\(s.repo.name): branch “\(branch)” is already checked out at \(at). Check out a different branch there or choose another branch name.", status: 1)
                }
                plans.append(.existing)
            } else if git.remoteBranchExists(branch, in: s.repo.path) {
                plans.append(.tracking)
            } else {
                if s.base.trimmingCharacters(in: .whitespaces).isEmpty {
                    throw GitError(command: "", output: "\(s.repo.name): enter a base branch to create “\(branch)” from.", status: 1)
                }
                plans.append(.new)
            }
        }
        let fm = FileManager.default
        try fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        var created: [(repo: Repo, path: String, ownsBranch: Bool)] = []
        var links: [WorkspaceRepo] = []
        do {
            for (s, plan) in zip(selections, plans) {
                let path = root + "/" + s.repo.name
                progress("Creating worktree for \(s.repo.name)…")
                do {
                    switch plan {
                    case .new: try git.worktreeAdd(repo: s.repo.path, path: path, branch: branch, base: s.base)
                    case .existing: try git.worktreeAddExisting(repo: s.repo.path, path: path, branch: branch)
                    case .tracking: try git.worktreeAddTracking(repo: s.repo.path, path: path, branch: branch)
                    }
                } catch {
                    throw GitError(command: "", output: "\(s.repo.name): \(error.localizedDescription)", status: 1)
                }
                let pre = plan == .existing
                created.append((s.repo, path, !pre))
                links.append(WorkspaceRepo(repoID: s.repo.id, repoName: s.repo.name, worktreePath: path,
                                           baseBranch: s.base, branchPreexisting: pre))
            }
        } catch {
            var leftovers: [String] = []
            for c in created {
                do { try git.worktreeRemove(repo: c.repo.path, path: c.path, force: true) }
                catch { leftovers.append(c.path) }
                if c.ownsBranch { git.deleteBranch(repo: c.repo.path, branch: branch) }
            }
            do { try fm.removeItem(atPath: root) } catch { leftovers.append(root) }
            if !leftovers.isEmpty {
                throw GitError(command: "", output: error.localizedDescription + "\n\nCleanup incomplete, remove manually: " + leftovers.joined(separator: ", "), status: 1)
            }
            throw error
        }
        let terms = links.map { TerminalSpec(title: $0.repoName, cwd: $0.worktreePath, repoLabel: $0.repoName) }
        return Workspace(name: name, branch: branch, repos: links, terminals: terms,
                         activeTerminal: terms.first?.id, root: root)
    }

    /// Per-repo status of `branch` for UI badges.
    func branchState(_ branch: String, in repo: Repo) -> BranchState {
        if git.branchExists(branch, in: repo.path) { return .existing }
        if git.remoteBranchExists(branch, in: repo.path) { return .remote }
        return .new
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
            if ahead == 0 && !r.branchPreexisting { git.deleteBranch(repo: repo.path, branch: ws.branch) }
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
