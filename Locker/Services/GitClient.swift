import Foundation

struct GitError: Error, LocalizedError {
    let command: String
    let output: String
    let status: Int32
    var errorDescription: String? {
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        return o.isEmpty ? "git \(command) failed (\(status))" : o
    }
}

struct GitStatus: Equatable {
    var branch: String
    var dirty: Bool
    /// `rev-parse --abbrev-ref HEAD` prints "HEAD" when no branch is checked out.
    var detached: Bool { branch == "HEAD" }
}

struct GitClient {
    var gitPath = "/usr/bin/git"

    /// Runs git and returns its combined output. With a `timeout` (seconds) the process is terminated when it
    /// runs longer, and a `GitError` saying so is thrown. Use it for network commands that could hang.
    @discardableResult
    func run(_ args: [String], in dir: String, timeout: TimeInterval? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: gitPath)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["LC_ALL"] = "C"
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        guard let timeout else {
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return try finish(args, p.terminationStatus, data)
        }
        // Read on another thread so the wait below can give up. A helper git spawned (ssh) may keep the pipe
        // open after git is terminated, so the read is abandoned after a short grace period instead of joined.
        let exited = DispatchSemaphore(value: 0), drained = DispatchSemaphore(value: 0)
        let box = OutputBox()
        p.terminationHandler = { _ in exited.signal() }
        try p.run()
        DispatchQueue.global(qos: .userInitiated).async {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            drained.signal()
        }
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw GitError(command: args.joined(separator: " "),
                           output: "git \(args.first ?? "") timed out after \(Int(timeout)) s.", status: -1)
        }
        _ = drained.wait(timeout: .now() + 2)
        return try finish(args, p.terminationStatus, box.get())
    }

    private func finish(_ args: [String], _ status: Int32, _ data: Data) throws -> String {
        let out = String(decoding: data, as: UTF8.self)
        guard status == 0 else { throw GitError(command: args.joined(separator: " "), output: out, status: status) }
        return out
    }

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ d: Data) { lock.lock(); data = d; lock.unlock() }
        func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
    }

    var isInstalled: Bool { FileManager.default.isExecutableFile(atPath: gitPath) }

    func isRepo(_ path: String) -> Bool {
        (try? run(["rev-parse", "--is-inside-work-tree"], in: path))?.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    func currentBranch(_ dir: String) throws -> String {
        try run(["rev-parse", "--abbrev-ref", "HEAD"], in: dir).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func detectDefaultBranch(_ dir: String) -> String {
        if let ref = try? run(["symbolic-ref", "--short", "refs/remotes/origin/HEAD"], in: dir) {
            let b = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            if b.hasPrefix("origin/") { return String(b.dropFirst(7)) }
        }
        for c in ["main", "master"] where branchExists(c, in: dir) { return c }
        return (try? currentBranch(dir)) ?? "main"
    }

    func branchExists(_ branch: String, in dir: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/heads/\(branch)"], in: dir)) != nil
    }

    func isValidBranchName(_ name: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-") else { return false }
        return (try? run(["check-ref-format", "--branch", name], in: NSTemporaryDirectory())) != nil
    }

    /// Creates a new branch `branch` from `base` in a new worktree at `path`.
    /// `noTrack` stops git from making `base` the upstream when it is a remote-tracking ref like `origin/main`.
    func worktreeAdd(repo: String, path: String, branch: String, base: String, noTrack: Bool = false) throws {
        try run(["worktree", "add"] + (noTrack ? ["--no-track"] : []) + ["-b", branch, path, base], in: repo)
    }

    /// Checks out an existing local branch into a new worktree at `path`.
    func worktreeAddExisting(repo: String, path: String, branch: String) throws {
        try run(["worktree", "add", path, branch], in: repo)
    }

    /// Creates a local branch tracking `origin/<branch>` in a new worktree.
    func worktreeAddTracking(repo: String, path: String, branch: String) throws {
        try run(["worktree", "add", "--track", "-b", branch, path, "origin/\(branch)"], in: repo)
    }

    /// Checks out `base`'s commit with no branch, so it never conflicts with another worktree.
    func worktreeAddDetached(repo: String, path: String, base: String) throws {
        try run(["worktree", "add", "--detach", path, base], in: repo)
    }

    func refExists(_ ref: String, in dir: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], in: dir)) != nil
    }

    func remoteBranchExists(_ branch: String, in dir: String) -> Bool {
        (try? run(["rev-parse", "--verify", "--quiet", "refs/remotes/origin/\(branch)"], in: dir)) != nil
    }

    func hasOrigin(_ dir: String) -> Bool {
        ((try? run(["remote"], in: dir)) ?? "").split(separator: "\n").contains("origin")
    }

    /// Updates every `origin/*` remote-tracking ref. Never touches local branches or the working tree.
    func fetchOrigin(in dir: String, timeout: TimeInterval = 30) throws {
        try run(["fetch", "--no-tags", "origin"], in: dir, timeout: timeout)
    }

    /// Untracked paths ignored by the repo's ignore rules (or, with `excludeFrom`, matched by that pattern file
    /// instead), relative to `dir`, which must be the repo's top level. With `collapse`, a folder whose whole
    /// content is ignored is listed once with a trailing "/" (and git doesn't look inside untracked folders);
    /// without it every file is listed. `within` limits the listing to those literal paths.
    func ignoredEntries(in dir: String, excludeFrom: String? = nil, collapse: Bool = true, within: [String] = []) -> [String] {
        let rules = excludeFrom.map { ["--exclude-from=" + $0] } ?? ["--exclude-standard"]
        let shape = collapse ? ["--directory", "--no-empty-directory"] : []
        let args = ["--literal-pathspecs", "ls-files", "--others", "--ignored"] + rules + shape + ["-z", "--"] + within
        let out = (try? run(args, in: dir)) ?? ""
        return out.split(separator: "\0").map(String.init)
    }

    /// Commits local `branch` has that `origin/<branch>` lacks, and the reverse, from refs already on disk.
    /// Nil when either side doesn't exist.
    func aheadBehindOrigin(_ branch: String, in dir: String) -> (ahead: Int, behind: Int)? {
        guard let out = try? run(["rev-list", "--left-right", "--count", "refs/heads/\(branch)...refs/remotes/origin/\(branch)"], in: dir)
        else { return nil }
        let n = out.split(whereSeparator: { $0 == "\t" || $0 == " " || $0 == "\n" }).compactMap { Int($0) }
        return n.count == 2 ? (n[0], n[1]) : nil
    }

    /// Maps branch name -> worktree path for every worktree (including the main one) that has a branch checked out.
    func checkedOutBranches(repo: String) -> [String: String] {
        guard let out = try? run(["worktree", "list", "--porcelain"], in: repo) else { return [:] }
        var result: [String: String] = [:]
        var current = ""
        for line in out.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("worktree ") { current = String(line.dropFirst(9)) }
            else if line.hasPrefix("branch refs/heads/") { result[String(line.dropFirst(18))] = current }
        }
        return result
    }

    func worktreeRemove(repo: String, path: String, force: Bool = false) throws {
        try run(["worktree", "remove"] + (force ? ["--force"] : []) + [path], in: repo)
    }

    func deleteBranch(repo: String, branch: String) {
        _ = try? run(["branch", "-D", branch], in: repo)
    }

    func worktreeList(repo: String) throws -> [String] {
        try run(["worktree", "list", "--porcelain"], in: repo)
            .split(separator: "\n")
            .compactMap { $0.hasPrefix("worktree ") ? String($0.dropFirst(9)) : nil }
    }

    func prune(repo: String) { _ = try? run(["worktree", "prune"], in: repo) }

    func status(_ dir: String) throws -> GitStatus {
        let b = try currentBranch(dir)
        let s = try run(["status", "--porcelain"], in: dir)
        return GitStatus(branch: b, dirty: !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Commits on HEAD that are not on `base` (work that exists only on this branch).
    func aheadCount(_ dir: String, base: String, head: String = "HEAD") -> Int {
        guard let out = try? run(["rev-list", "--count", "\(base)..\(head)"], in: dir) else { return 0 }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    /// Commits reachable from HEAD but from no local or remote branch (lost if HEAD moves away).
    func unbranchedCommits(_ dir: String) -> Int {
        guard let out = try? run(["rev-list", "--count", "HEAD", "--not", "--branches", "--remotes"], in: dir) else { return 0 }
        return Int(out.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    struct BranchList: Equatable { var local: [String]; var remoteOnly: [String] }

    func listBranches(_ dir: String) -> BranchList {
        let fmt = ["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes/origin"]
        guard let out = try? run(fmt, in: dir) else { return BranchList(local: [], remoteOnly: []) }
        var local: [String] = [], remote: [String] = []
        for l in out.split(separator: "\n") {
            if l.hasPrefix("refs/heads/") { local.append(String(l.dropFirst(11))) }
            else if l.hasPrefix("refs/remotes/origin/") {
                let n = String(l.dropFirst(20))
                if n != "HEAD" { remote.append(n) }
            }
        }
        return BranchList(local: local.sorted(), remoteOnly: remote.filter { !local.contains($0) }.sorted())
    }

    func switchBranch(_ branch: String, in dir: String) throws { try run(["switch", branch], in: dir) }

    func switchTracking(_ branch: String, in dir: String) throws {
        try run(["switch", "--track", "origin/\(branch)"], in: dir)
    }

    func switchDetach(_ ref: String, in dir: String) throws { try run(["switch", "--detach", ref], in: dir) }

    func switchCreate(_ branch: String, in dir: String) throws {
        try run(["switch", "-c", branch], in: dir)
    }
}

extension GitClient {
    /// Re-attaches an existing branch as a worktree (repair of a deleted worktree directory).
    func worktreeAttach(repo: String, path: String, branch: String) throws {
        prune(repo: repo)
        try run(["worktree", "add", path, branch], in: repo)
    }

    func worktreeAttachDetached(repo: String, path: String, base: String) throws {
        prune(repo: repo)
        try worktreeAddDetached(repo: repo, path: path, base: base)
    }
}
