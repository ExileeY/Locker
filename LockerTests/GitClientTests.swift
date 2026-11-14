import XCTest

final class GitClientTests: XCTestCase {
    let git = GitClient()

    func testDetectsRepoAndDefaultBranch() {
        let d = TestSupport.tempDir()
        let r = TestSupport.makeRepo(named: "r", in: d)
        XCTAssertTrue(git.isRepo(r.path))
        XCTAssertFalse(git.isRepo(d))
        XCTAssertEqual(git.detectDefaultBranch(r.path), "main")
    }

    func testWorktreeAddListRemove() throws {
        let d = TestSupport.tempDir()
        let r = TestSupport.makeRepo(named: "r", in: d)
        let wt = d + "/wt"
        try git.worktreeAdd(repo: r.path, path: wt, branch: "t1", base: "main")
        XCTAssertEqual(try git.currentBranch(wt), "t1")
        XCTAssertEqual(try git.currentBranch(r.path), "main")
        XCTAssertTrue(try git.worktreeList(repo: r.path).contains(wt))
        try git.worktreeRemove(repo: r.path, path: wt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: wt))
    }

    func testStatusDetectsDirty() throws {
        let d = TestSupport.tempDir()
        let r = TestSupport.makeRepo(named: "r", in: d)
        XCTAssertEqual(try git.status(r.path), GitStatus(branch: "main", dirty: false))
        try "x".write(toFile: r.path + "/b.txt", atomically: true, encoding: .utf8)
        XCTAssertTrue(try git.status(r.path).dirty)
    }

    func testBranchCollisionErrors() throws {
        let d = TestSupport.tempDir()
        let r = TestSupport.makeRepo(named: "r", in: d)
        XCTAssertThrowsError(try git.worktreeAdd(repo: r.path, path: d + "/wt", branch: "main", base: "main"))
    }

    func testBranchNameValidation() {
        XCTAssertTrue(git.isValidBranchName("feature/x"))
        XCTAssertFalse(git.isValidBranchName("bad name"))
        XCTAssertFalse(git.isValidBranchName(""))
    }

    func testCheckedOutBranchesAndAddExisting() throws {
        let dir = TestSupport.tempDir()
        let r = TestSupport.makeRepo(named: "r", in: dir)
        let g = GitClient()
        try g.run(["branch", "feat"], in: r.path)
        XCTAssertEqual(g.checkedOutBranches(repo: r.path)["main"], r.path)
        XCTAssertNil(g.checkedOutBranches(repo: r.path)["feat"])
        try g.worktreeAddExisting(repo: r.path, path: dir + "/wt", branch: "feat")
        XCTAssertEqual(g.checkedOutBranches(repo: r.path)["feat"], dir + "/wt")
    }
}
