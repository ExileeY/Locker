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
    /// An empty `branch` starts every repo detached at its base (default) branch, so no branch is claimed.
    /// Otherwise, if the branch already exists in a repo it is checked out as is; else it is created from the base.
    func create(name: String, branch: String, selections: [RepoSelection], existingNames: [String],
                progress: (String) -> Void = { _ in }) throws -> Workspace {
        guard !selections.isEmpty else { throw GitError(command: "", output: "Select at least one repository.", status: 1) }
        let detached = branch.isEmpty
        guard detached || git.isValidBranchName(branch) else {
            throw GitError(command: "", output: "“\(branch)” is not a valid branch name.", status: 1)
        }
        let root = lockerRoot + "/" + Self.slug(name)
        if FileManager.default.fileExists(atPath: root) || existingNames.contains(name) {
            throw GitError(command: "", output: "A workspace folder named “\(Self.slug(name))” already exists.", status: 1)
        }
        // Preflight: decide per repo whether to attach an existing branch or create a new one.
        enum Plan { case new, existing, tracking, detached }
        var plans: [Plan] = []
        for s in selections {
            if detached {
                let base = s.base.trimmingCharacters(in: .whitespaces)
                if base.isEmpty {
                    throw GitError(command: "", output: "\(s.repo.name): enter a base branch to start from.", status: 1)
                }
                if !git.refExists(base, in: s.repo.path) {
                    throw GitError(command: "", output: "\(s.repo.name): base “\(base)” does not exist.", status: 1)
                }
                plans.append(.detached)
            } else if git.branchExists(branch, in: s.repo.path) {
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
                    case .detached: try git.worktreeAddDetached(repo: s.repo.path, path: path, base: s.base)
                    }
                } catch {
                    throw GitError(command: "", output: "\(s.repo.name): \(error.localizedDescription)", status: 1)
                }
                let pre = plan == .existing
                let owns = plan == .new || plan == .tracking
                created.append((s.repo, path, owns))
                links.append(WorkspaceRepo(repoID: s.repo.id, repoName: s.repo.name, worktreePath: path,
                                           baseBranch: s.base, branchPreexisting: pre,
                                           ownedBranches: owns ? [branch] : [],
                                           lastBranch: detached ? nil : branch))
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
        return Workspace(name: name, branch: detached ? nil : branch, repos: links, terminals: terms,
                         activeTerminal: terms.first?.id, root: root)
    }

    /// Renames a workspace. Only the display name changes: the folder, worktrees and branches stay where they are,
    /// so running terminals and git's worktree links keep working.
    func rename(_ ws: Workspace, to newName: String, existingNames: [String]) throws -> Workspace {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { throw GitError(command: "", output: "Enter a workspace name.", status: 1) }
        if name != ws.name, existingNames.contains(where: { $0 != ws.name && $0.caseInsensitiveCompare(name) == .orderedSame }) {
            throw GitError(command: "", output: "A workspace named “\(name)” already exists.", status: 1)
        }
        var out = ws
        out.name = name
        return out
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

    /// Removes worktrees. Branches Locker created are deleted only if they carry no commits beyond base.
    func delete(_ ws: Workspace, repos: [Repo]) {
        for r in ws.repos {
            guard let repo = repos.first(where: { $0.id == r.repoID }) else { continue }
            try? git.worktreeRemove(repo: repo.path, path: r.worktreePath, force: true)
            git.prune(repo: repo.path)
            for b in r.ownedBranches where git.aheadCount(repo.path, base: r.baseBranch, head: b) == 0 {
                git.deleteBranch(repo: repo.path, branch: b)
            }
        }
        try? FileManager.default.removeItem(atPath: ws.root)
    }

    // MARK: Per-repo branch switching

    private func requireClean(_ r: WorkspaceRepo) throws {
        if (try git.status(r.worktreePath)).dirty {
            throw GitError(command: "", output: "\(r.repoName) has uncommitted changes. Commit or stash them before switching.", status: 1)
        }
    }

    /// Commits that would become unreachable if this repo's HEAD moved away (detached work with no branch).
    func unbranchedCommits(_ r: WorkspaceRepo) -> Int { git.unbranchedCommits(r.worktreePath) }

    struct BranchChoice: Equatable, Identifiable {
        var name: String
        var remoteOnly: Bool
        /// Path of the worktree already using this branch, if any (other than this repo's own).
        var occupiedAt: String?
        var id: String { name }
    }

    func branchChoices(for r: WorkspaceRepo) -> [BranchChoice] {
        let list = git.listBranches(r.worktreePath)
        let used = git.checkedOutBranches(repo: r.worktreePath)
        let mine = URL(fileURLWithPath: r.worktreePath).resolvingSymlinksInPath().path
        func occ(_ b: String) -> String? {
            guard let p = used[b], URL(fileURLWithPath: p).resolvingSymlinksInPath().path != mine else { return nil }
            return p
        }
        return list.local.map { BranchChoice(name: $0, remoteOnly: false, occupiedAt: occ($0)) }
             + list.remoteOnly.map { BranchChoice(name: $0, remoteOnly: true, occupiedAt: nil) }
    }

    func switchBranch(_ choice: BranchChoice, in r: WorkspaceRepo) throws {
        try requireClean(r)
        if let at = choice.occupiedAt {
            throw GitError(command: "", output: "“\(choice.name)” is already checked out at \(at).", status: 1)
        }
        if choice.remoteOnly { try git.switchTracking(choice.name, in: r.worktreePath) }
        else { try git.switchBranch(choice.name, in: r.worktreePath) }
    }

    /// Moves this repo back to a detached HEAD at `ref` (normally its base branch).
    func detach(_ r: WorkspaceRepo, at ref: String) throws {
        try requireClean(r)
        try git.switchDetach(ref, in: r.worktreePath)
    }

    /// Creates `name` at the current commit in one repo and switches to it. Returns nothing; caller records ownership.
    func createBranch(_ name: String, in r: WorkspaceRepo) throws {
        guard git.isValidBranchName(name) else {
            throw GitError(command: "", output: "“\(name)” is not a valid branch name.", status: 1)
        }
        if git.branchExists(name, in: r.worktreePath) {
            throw GitError(command: "", output: "Branch “\(name)” already exists in \(r.repoName).", status: 1)
        }
        try git.switchCreate(name, in: r.worktreePath)
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
