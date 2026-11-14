import XCTest

final class WorkspaceServiceTests: XCTestCase {
    var dir = ""
    var svc: WorkspaceService!
    var backend: Repo!
    var frontend: Repo!

    override func setUp() {
        dir = TestSupport.tempDir()
        svc = WorkspaceService(lockerRoot: dir + "/Locker")
        backend = TestSupport.makeRepo(named: "backend", in: dir)
        frontend = TestSupport.makeRepo(named: "frontend", in: dir)
    }

    func sel() -> [RepoSelection] { [RepoSelection(repo: backend, base: "main"), RepoSelection(repo: frontend, base: "main")] }

    func testCreateMakesWorktreesAndTerminals() throws {
        let ws = try svc.create(name: "Task 1", branch: "task-1", selections: sel(), existingNames: [])
        XCTAssertEqual(ws.repos.count, 2)
        XCTAssertEqual(ws.terminals.count, 2)
        for r in ws.repos { XCTAssertEqual(try svc.git.currentBranch(r.worktreePath), "task-1") }
        XCTAssertEqual(try svc.git.currentBranch(backend.path), "main")
    }

    func testIsolationBetweenWorkspaces() throws {
        let a = try svc.create(name: "Task 1", branch: "task-1", selections: sel(), existingNames: [])
        let b = try svc.create(name: "Task 2", branch: "task-2", selections: sel(), existingNames: ["Task 1"])
        try svc.createBranch("extra", in: b.repos[0])
        XCTAssertEqual(try svc.git.currentBranch(b.repos[0].worktreePath), "extra")
        XCTAssertEqual(try svc.git.currentBranch(b.repos[1].worktreePath), "task-2")
        XCTAssertEqual(try svc.git.currentBranch(a.repos[0].worktreePath), "task-1")
        XCTAssertEqual(try svc.git.currentBranch(backend.path), "main")
    }

    func testBranchCollisionFailsWithoutSideEffects() throws {
        _ = try svc.create(name: "Task 1", branch: "task-1", selections: sel(), existingNames: [])
        XCTAssertThrowsError(try svc.create(name: "Task 2", branch: "task-1", selections: sel(), existingNames: ["Task 1"]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/Locker/Task-2"))
        XCTAssertThrowsError(try svc.create(name: "Main", branch: "main", selections: sel(), existingNames: []))
    }

    func testRollbackOnPartialFailure() throws {
        // Second repo has an invalid base, so its worktree creation fails after the first succeeded.
        let bad = [RepoSelection(repo: backend, base: "main"), RepoSelection(repo: frontend, base: "nope")]
        XCTAssertThrowsError(try svc.create(name: "T", branch: "t", selections: bad, existingNames: []))
        XCTAssertFalse(svc.git.branchExists("t", in: backend.path))
        XCTAssertEqual(try svc.git.worktreeList(repo: backend.path).count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/Locker/T"))
    }

    func testDeleteDetectsDirtyAndCleansUp() throws {
        let ws = try svc.create(name: "Task 1", branch: "task-1", selections: sel(), existingNames: [])
        XCTAssertTrue(svc.deleteWarnings(ws).isEmpty)
        try "x".write(toFile: ws.repos[0].worktreePath + "/new.txt", atomically: true, encoding: .utf8)
        let w = svc.deleteWarnings(ws)
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].dirty)
        svc.delete(ws, repos: [backend, frontend])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ws.root))
        XCTAssertEqual(try svc.git.worktreeList(repo: backend.path).count, 1)
        XCTAssertFalse(svc.git.branchExists("task-1", in: backend.path))
    }

    func testMissingWorktreeDetected() throws {
        let ws = try svc.create(name: "Task 1", branch: "task-1", selections: sel(), existingNames: [])
        try FileManager.default.removeItem(atPath: ws.repos[1].worktreePath)
        XCTAssertEqual(svc.missingWorktrees(ws, repos: [backend, frontend]).map(\.repoName), ["frontend"])
    }

    // MARK: existing branches

    func testCreateOnExistingBranchInAllRepos() throws {
        for r in [backend!, frontend!] { try svc.git.run(["branch", "feat"], in: r.path) }
        let ws = try svc.create(name: "T", branch: "feat", selections: sel(), existingNames: [])
        XCTAssertTrue(ws.repos.allSatisfy(\.branchPreexisting))
        for r in ws.repos { XCTAssertEqual(try svc.git.currentBranch(r.worktreePath), "feat") }
    }

    func testMixedExistingAndNew() throws {
        try svc.git.run(["branch", "feat"], in: backend.path)
        let ws = try svc.create(name: "T", branch: "feat", selections: sel(), existingNames: [])
        XCTAssertEqual(ws.repos.map(\.branchPreexisting), [true, false])
        XCTAssertTrue(svc.git.branchExists("feat", in: frontend.path))
    }

    func testBranchCheckedOutElsewhereGivesClearErrorWithoutSideEffects() throws {
        try svc.git.run(["checkout", "-q", "-b", "wip"], in: backend.path)
        do {
            _ = try svc.create(name: "T", branch: "wip", selections: sel(), existingNames: [])
            XCTFail("expected error")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("backend"))
            XCTAssertTrue(error.localizedDescription.contains("already checked out"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/Locker/T"))
        XCTAssertFalse(svc.git.branchExists("wip", in: frontend.path))
    }

    func testRollbackKeepsPreexistingBranchAndNamesFailingRepo() throws {
        try svc.git.run(["branch", "feat"], in: backend.path)
        let bad = [RepoSelection(repo: backend, base: "main"), RepoSelection(repo: frontend, base: "nope")]
        do { _ = try svc.create(name: "T", branch: "feat", selections: bad, existingNames: []); XCTFail() }
        catch { XCTAssertTrue(error.localizedDescription.hasPrefix("frontend:")) }
        XCTAssertTrue(svc.git.branchExists("feat", in: backend.path))
        XCTAssertFalse(svc.git.branchExists("feat", in: frontend.path))
        XCTAssertEqual(try svc.git.worktreeList(repo: backend.path).count, 1)
    }

    func testDeleteKeepsPreexistingBranch() throws {
        try svc.git.run(["branch", "feat"], in: backend.path)
        let ws = try svc.create(name: "T", branch: "feat", selections: sel(), existingNames: [])
        svc.delete(ws, repos: [backend, frontend])
        XCTAssertTrue(svc.git.branchExists("feat", in: backend.path))
        XCTAssertFalse(svc.git.branchExists("feat", in: frontend.path))
    }

    func testEmptyBaseForNewBranchFailsEarly() {
        let s = [RepoSelection(repo: backend, base: " ")]
        XCTAssertThrowsError(try svc.create(name: "T", branch: "new-b", selections: s, existingNames: [])) {
            XCTAssertTrue($0.localizedDescription.contains("base branch"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/Locker/T"))
    }

    func testProgressReportsEachRepo() throws {
        var msgs: [String] = []
        _ = try svc.create(name: "T", branch: "p", selections: sel(), existingNames: []) { msgs.append($0) }
        XCTAssertEqual(msgs.count, 2)
    }

    func testOldStateWithoutBranchPreexistingDecodes() throws {
        let json = #"{"id":"\#(UUID().uuidString)","repoID":"\#(UUID().uuidString)","repoName":"a","worktreePath":"/x","baseBranch":"main"}"#
        let r = try JSONDecoder().decode(WorkspaceRepo.self, from: Data(json.utf8))
        XCTAssertFalse(r.branchPreexisting)
    }

    // MARK: start detached at main

    func testEmptyBranchStartsDetachedAtBaseInEveryRepo() throws {
        let ws = try svc.create(name: "D", branch: "", selections: sel(), existingNames: [])
        XCTAssertNil(ws.branch)
        for r in ws.repos {
            XCTAssertTrue(try svc.git.status(r.worktreePath).detached)
            XCTAssertTrue(r.ownedBranches.isEmpty)
            XCTAssertNil(r.lastBranch)
        }
        XCTAssertEqual(ws.branchSummary, "main (detached)")
    }

    func testThreeDetachedWorkspacesCoexistWithMainCheckedOut() throws {
        let a = try svc.create(name: "A", branch: "", selections: sel(), existingNames: [])
        let b = try svc.create(name: "B", branch: "", selections: sel(), existingNames: ["A"])
        let c = try svc.create(name: "C", branch: "", selections: sel(), existingNames: ["A", "B"])
        XCTAssertEqual(try svc.git.worktreeList(repo: backend.path).count, 4)
        for w in [a, b, c] { XCTAssertTrue(try svc.git.status(w.repos[0].worktreePath).detached) }
    }

    func testDetachedCreateFailsEarlyForBadBase() {
        let bad = [RepoSelection(repo: backend, base: "nope")]
        XCTAssertThrowsError(try svc.create(name: "D", branch: "", selections: bad, existingNames: []))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir + "/Locker/D"))
    }

    func testSwitchOneWorkspaceLeavesOthersUntouched() throws {
        try svc.git.run(["branch", "feat"], in: backend.path)
        let a = try svc.create(name: "A", branch: "", selections: sel(), existingNames: [])
        let b = try svc.create(name: "B", branch: "", selections: sel(), existingNames: ["A"])
        let choice = try XCTUnwrap(svc.branchChoices(for: a.repos[0]).first { $0.name == "feat" })
        try svc.switchBranch(choice, in: a.repos[0])
        XCTAssertEqual(try svc.git.currentBranch(a.repos[0].worktreePath), "feat")
        XCTAssertTrue(try svc.git.status(b.repos[0].worktreePath).detached)
        XCTAssertTrue(try svc.git.status(a.repos[1].worktreePath).detached)
    }

    func testSwitchToBranchInUseElsewhereIsRefused() throws {
        try svc.git.run(["branch", "feat"], in: backend.path)
        let a = try svc.create(name: "A", branch: "", selections: sel(), existingNames: [])
        let b = try svc.create(name: "B", branch: "", selections: sel(), existingNames: ["A"])
        try svc.switchBranch(try XCTUnwrap(svc.branchChoices(for: a.repos[0]).first { $0.name == "feat" }), in: a.repos[0])
        let inB = try XCTUnwrap(svc.branchChoices(for: b.repos[0]).first { $0.name == "feat" })
        XCTAssertNotNil(inB.occupiedAt)
        XCTAssertThrowsError(try svc.switchBranch(inB, in: b.repos[0])) { XCTAssertTrue($0.localizedDescription.contains("already checked out")) }
        // main is held by the source checkout, so it is occupied too
        XCTAssertNotNil(svc.branchChoices(for: b.repos[0]).first { $0.name == "main" }?.occupiedAt)
    }

    func testSwitchRefusesDirtyTree() throws {
        try svc.git.run(["branch", "feat"], in: backend.path)
        let a = try svc.create(name: "A", branch: "", selections: sel(), existingNames: [])
        try "x".write(toFile: a.repos[0].worktreePath + "/new.txt", atomically: true, encoding: .utf8)
        let c = try XCTUnwrap(svc.branchChoices(for: a.repos[0]).first { $0.name == "feat" })
        XCTAssertThrowsError(try svc.switchBranch(c, in: a.repos[0])) { XCTAssertTrue($0.localizedDescription.contains("uncommitted")) }
    }

    func testCreateBranchPerRepoAndDetachBack() throws {
        let a = try svc.create(name: "A", branch: "", selections: sel(), existingNames: [])
        try svc.createBranch("work", in: a.repos[0])
        XCTAssertEqual(try svc.git.currentBranch(a.repos[0].worktreePath), "work")
        XCTAssertTrue(try svc.git.status(a.repos[1].worktreePath).detached)
        XCTAssertThrowsError(try svc.createBranch("work", in: a.repos[0]))
        try svc.detach(a.repos[0], at: "main")
        XCTAssertTrue(try svc.git.status(a.repos[0].worktreePath).detached)
    }

    func testUnbranchedCommitsCountedOnDetachedHead() throws {
        let a = try svc.create(name: "A", branch: "", selections: sel(), existingNames: [])
        let wt = a.repos[0].worktreePath
        XCTAssertEqual(svc.unbranchedCommits(a.repos[0]), 0)
        try svc.git.run(["config", "user.email", "t@t.t"], in: wt)
        try svc.git.run(["config", "user.name", "t"], in: wt)
        try svc.git.run(["commit", "-q", "--allow-empty", "-m", "wip"], in: wt)
        XCTAssertEqual(svc.unbranchedCommits(a.repos[0]), 1)
        XCTAssertEqual(svc.deleteWarnings(a).first?.ahead, 1)
        try svc.createBranch("keep", in: a.repos[0])
        XCTAssertEqual(svc.unbranchedCommits(a.repos[0]), 0)
    }

    func testDeleteRemovesOwnedBranchesButKeepsOnesWithCommits() throws {
        var a = try svc.create(name: "A", branch: "", selections: sel(), existingNames: [])
        try svc.createBranch("empty-b", in: a.repos[0]); a.repos[0].ownedBranches.append("empty-b")
        let wt = a.repos[0].worktreePath
        try svc.createBranch("with-commits", in: a.repos[0]); a.repos[0].ownedBranches.append("with-commits")
        try svc.git.run(["config", "user.email", "t@t.t"], in: wt)
        try svc.git.run(["config", "user.name", "t"], in: wt)
        try svc.git.run(["commit", "-q", "--allow-empty", "-m", "work"], in: wt)
        svc.delete(a, repos: [backend, frontend])
        XCTAssertTrue(svc.git.branchExists("with-commits", in: backend.path))
        XCTAssertFalse(svc.git.branchExists("empty-b", in: backend.path))
        XCTAssertEqual(try svc.git.worktreeList(repo: backend.path).count, 1)
    }

    func testSchema1StateMigratesToPerRepoOwnership() throws {
        let rid = UUID().uuidString
        func repo(pre: Bool) -> String {
            #"{"id":"\#(UUID().uuidString)","repoID":"\#(rid)","repoName":"a","worktreePath":"/x","baseBranch":"main","branchPreexisting":\#(pre)}"#
        }
        let json = #"{"schemaVersion":1,"repos":[],"workspaces":[{"id":"\#(UUID().uuidString)","name":"w","branch":"feat","repos":[\#(repo(pre: false)),\#(repo(pre: true))],"terminals":[],"root":"/r"}]}"#
        let st = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(st.schemaVersion, 3)
        let r = st.workspaces[0].repos
        XCTAssertEqual(r[0].ownedBranches, ["feat"]); XCTAssertEqual(r[1].ownedBranches, [])
        XCTAssertEqual(r.map(\.lastBranch), ["feat", "feat"])
    }
}
