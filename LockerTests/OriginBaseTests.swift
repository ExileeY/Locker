import XCTest

/// "Start from: Origin / Local" — fetching before creation and resolving bases to `origin/<base>`.
final class OriginBaseTests: XCTestCase {
    var dir = ""
    var svc: WorkspaceService!
    var upstream: Repo!
    var clone: Repo!

    override func setUp() {
        dir = TestSupport.tempDir()
        svc = WorkspaceService(lockerRoot: dir + "/Locker")
        upstream = TestSupport.makeRepo(named: "upstream", in: dir)
        clone = TestSupport.makeClone(of: upstream, named: "app", in: dir)
    }

    private var git: GitClient { svc.git }
    private func head(_ path: String) throws -> String {
        try git.run(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Adds a commit to upstream's main, so the clone's local main and cached origin/main fall behind.
    private func advanceUpstream() throws -> String {
        try "more".write(toFile: upstream.path + "/b.txt", atomically: true, encoding: .utf8)
        try git.run(["add", "."], in: upstream.path)
        try git.run(["commit", "-q", "-m", "more"], in: upstream.path)
        return try head(upstream.path)
    }

    func testOriginModeFetchesAndStartsAtRemoteCommit() throws {
        let tip = try advanceUpstream()
        var warnings: [String] = []
        let ws = try svc.create(name: "O", branch: "", selections: [RepoSelection(repo: clone, base: "main")],
                                existingNames: [], baseSource: .origin, onWarning: { warnings.append($0) })
        XCTAssertEqual(try head(ws.repos[0].worktreePath), tip)
        XCTAssertEqual(ws.repos[0].baseBranch, "origin/main")
        XCTAssertEqual(ws.repos[0].summary, "origin/main (detached)")
        XCTAssertTrue(warnings.isEmpty)
        XCTAssertNotEqual(try head(clone.path), tip, "the original checkout's local main is not moved")
    }

    func testLocalModeKeepsLocalCommit() throws {
        let before = try head(clone.path)
        _ = try advanceUpstream()
        let ws = try svc.create(name: "L", branch: "", selections: [RepoSelection(repo: clone, base: "main")],
                                existingNames: [], baseSource: .local)
        XCTAssertEqual(try head(ws.repos[0].worktreePath), before)
        XCTAssertEqual(ws.repos[0].baseBranch, "main")
    }

    func testNewBranchFromOriginHasNoUpstream() throws {
        let tip = try advanceUpstream()
        let ws = try svc.create(name: "N", branch: "feat", selections: [RepoSelection(repo: clone, base: "main")],
                                existingNames: [], baseSource: .origin)
        let wt = ws.repos[0].worktreePath
        XCTAssertEqual(try git.currentBranch(wt), "feat")
        XCTAssertEqual(try head(wt), tip)
        XCTAssertThrowsError(try git.run(["rev-parse", "--abbrev-ref", "feat@{upstream}"], in: wt))
        XCTAssertEqual(ws.repos[0].ownedBranches, ["feat"])
    }

    func testDeletingOriginWorkspaceRemovesUnusedOwnedBranch() throws {
        let ws = try svc.create(name: "N", branch: "feat", selections: [RepoSelection(repo: clone, base: "main")],
                                existingNames: [], baseSource: .origin)
        svc.delete(ws, repos: [clone])
        XCTAssertFalse(git.branchExists("feat", in: clone.path))
    }

    func testFetchFailureFallsBackToCachedRefWithWarning() throws {
        let cached = try head(clone.path)   // origin/main as of the clone
        try git.run(["remote", "set-url", "origin", dir + "/does-not-exist"], in: clone.path)
        var warnings: [String] = []
        let ws = try svc.create(name: "F", branch: "", selections: [RepoSelection(repo: clone, base: "main")],
                                existingNames: [], baseSource: .origin, onWarning: { warnings.append($0) })
        XCTAssertEqual(try head(ws.repos[0].worktreePath), cached)
        XCTAssertEqual(ws.repos[0].baseBranch, "origin/main")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("couldn't fetch"))
    }

    func testFetchFailureWithoutCachedRefFailsBeforeCreatingAnything() throws {
        try git.run(["remote", "set-url", "origin", dir + "/does-not-exist"], in: clone.path)
        try git.run(["update-ref", "-d", "refs/remotes/origin/main"], in: clone.path)
        XCTAssertThrowsError(try svc.create(name: "F", branch: "", selections: [RepoSelection(repo: clone, base: "main")],
                                            existingNames: [], baseSource: .origin)) {
            XCTAssertTrue($0.localizedDescription.contains("couldn't fetch"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/Locker/F"))
    }

    func testRepoWithoutOriginUsesLocalSilently() throws {
        let plain = TestSupport.makeRepo(named: "plain", in: dir)
        var warnings: [String] = []
        let ws = try svc.create(name: "P", branch: "", selections: [RepoSelection(repo: plain, base: "main")],
                                existingNames: [], baseSource: .origin, onWarning: { warnings.append($0) })
        XCTAssertEqual(ws.repos[0].baseBranch, "main")
        XCTAssertTrue(warnings.isEmpty)
    }

    func testLocalOnlyBranchInOriginModeUsesLocalWithWarning() throws {
        try git.run(["branch", "local-only"], in: clone.path)
        var warnings: [String] = []
        let ws = try svc.create(name: "LO", branch: "", selections: [RepoSelection(repo: clone, base: "local-only")],
                                existingNames: [], baseSource: .origin, onWarning: { warnings.append($0) })
        XCTAssertEqual(ws.repos[0].baseBranch, "local-only")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].contains("isn't on origin"))
    }

    func testTrackingBranchSeesBranchPushedSinceLastFetch() throws {
        try git.run(["branch", "pushed-later"], in: upstream.path)
        XCTAssertFalse(git.remoteBranchExists("pushed-later", in: clone.path))
        let ws = try svc.create(name: "T", branch: "pushed-later", selections: [RepoSelection(repo: clone, base: "main")],
                                existingNames: [], baseSource: .origin)
        XCTAssertEqual(try git.currentBranch(ws.repos[0].worktreePath), "pushed-later")
    }

    // MARK: hints

    func testOriginHints() throws {
        XCTAssertEqual(svc.originHint(base: "main", in: clone), .upToDate)
        _ = try advanceUpstream()
        try git.fetchOrigin(in: clone.path)
        XCTAssertEqual(svc.originHint(base: "main", in: clone), .diverged(ahead: 0, behind: 1))
        try git.run(["branch", "solo"], in: clone.path)
        XCTAssertEqual(svc.originHint(base: "solo", in: clone), .notOnOrigin)
        XCTAssertEqual(svc.originHint(base: "main", in: TestSupport.makeRepo(named: "plain", in: dir)), .noOrigin)
    }

    // MARK: GitClient timeout and preferences

    func testRunTimeoutTerminatesAndThrows() {
        let sleeper = GitClient(gitPath: "/bin/sleep")
        let start = Date()
        XCTAssertThrowsError(try sleeper.run(["10"], in: dir, timeout: 0.5)) {
            XCTAssertTrue($0.localizedDescription.contains("timed out"))
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testRunWithTimeoutReturnsOutput() throws {
        XCTAssertTrue(try git.run(["--version"], in: dir, timeout: 10).hasPrefix("git version"))
    }

    func testPreferencesDefaultToOriginAndRoundTrip() throws {
        let old = #"{"schemaVersion":3,"repos":[],"projects":[],"workspaces":[]}"#
        var s = try JSONDecoder().decode(AppState.self, from: Data(old.utf8))
        XCTAssertEqual(s.preferences.baseSource, .origin)
        s.preferences.baseSource = .local
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.preferences.baseSource, .local)
        let junk = #"{"schemaVersion":3,"preferences":{"baseSource":"sideways"}}"#
        XCTAssertEqual(try JSONDecoder().decode(AppState.self, from: Data(junk.utf8)).preferences.baseSource, .origin)
    }
}
