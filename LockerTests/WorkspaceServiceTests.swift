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
        try svc.createBranch("extra", in: b)
        XCTAssertEqual(try svc.git.currentBranch(b.repos[0].worktreePath), "extra")
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
}
