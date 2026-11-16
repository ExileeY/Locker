import XCTest

/// Copying git-ignored files from a repo's original checkout into a new workspace.
final class CarryOverTests: XCTestCase {
    var dir = ""
    var svc: WorkspaceService!
    var repo: Repo!
    let co = CarryOver()
    let fm = FileManager.default

    override func setUp() {
        dir = TestSupport.tempDir()
        svc = WorkspaceService(lockerRoot: dir + "/Locker")
        repo = TestSupport.makeRepo(named: "app", in: dir)
        // Ignore local config and build output, and commit one tracked file in .claude/.
        write(".gitignore", ".claude/settings.local.json\n.env*\n.mcp.json\nnode_modules/\nbuild/\nsecrets/\n")
        write(".claude/shared.md", "tracked")
        try! svc.git.run(["add", "."], in: repo.path)
        try! svc.git.run(["commit", "-q", "-m", "ignore"], in: repo.path)
        write(".claude/settings.local.json", "{\"local\":true}")
        write(".env.local", "TOKEN=1")
        write(".mcp.json", "{}")
        write("node_modules/x/index.js", "js")
        write("build/out.o", "obj")
        write("secrets/a.txt", "a")
        write("secrets/b.txt", "b")
    }

    private func write(_ rel: String, _ text: String, in root: String? = nil) {
        let p = (root ?? repo.path) + "/" + rel
        try! fm.createDirectory(atPath: (p as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try! text.write(toFile: p, atomically: true, encoding: .utf8)
    }
    private func read(_ path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    private func paths(_ c: [CarryOver.Candidate]) -> [String] { c.map(\.path) }

    // MARK: Candidates

    func testCandidatesListIgnoredEntriesAndFlagHeavyFolders() {
        let c = co.candidates(for: repo)
        XCTAssertEqual(Set(paths(c)), [".claude/settings.local.json", ".env.local", ".mcp.json", "node_modules/", "build/", "secrets/"])
        XCTAssertFalse(paths(c).contains(".claude/shared.md"), "tracked files are never offered")
        let byPath = Dictionary(uniqueKeysWithValues: c.map { ($0.path, $0) })
        XCTAssertTrue(byPath["node_modules/"]!.heavy)
        XCTAssertTrue(byPath["build/"]!.heavy)
        XCTAssertFalse(byPath[".env.local"]!.heavy)
        XCTAssertTrue(c.allSatisfy { !$0.preselected }, "nothing is preselected without a memory or .worktreeinclude")
        XCTAssertNil(byPath["secrets/"]!.size, "folders are sized later, not while listing")
        XCTAssertEqual(byPath[".env.local"]!.size, 7, "files get their size from one lstat")
        XCTAssertEqual(try CarryOver.size(of: repo.path + "/secrets").0, 2)
        XCTAssertEqual(paths(c).suffix(2).sorted(), ["build/", "node_modules/"], "heavy entries are listed last")
    }

    func testRememberedAndWorktreeincludeEntriesArePreselectedFirst() {
        write(".worktreeinclude", ".mcp.json\nnode_modules/\nsecrets/a.txt\nnot-ignored.txt\n")
        write("not-ignored.txt", "untracked but not ignored")
        repo.carryOver = [".env.local", "gone.txt"]
        let c = co.candidates(for: repo)
        let byPath = Dictionary(uniqueKeysWithValues: c.map { ($0.path, $0) })
        XCTAssertEqual(byPath[".env.local"]?.source, .remembered)
        XCTAssertEqual(byPath[".mcp.json"]?.source, .worktreeinclude)
        XCTAssertEqual(byPath["node_modules/"]?.source, .worktreeinclude, "an explicit include preselects even heavy folders")
        XCTAssertEqual(byPath["secrets/a.txt"]?.source, .worktreeinclude, "a file inside an ignored folder is offered on its own")
        XCTAssertEqual(byPath["secrets/"]?.source, .detected, "…without preselecting the whole folder")
        XCTAssertNil(byPath["not-ignored.txt"], "only ignored files are offered")
        XCTAssertNil(byPath["gone.txt"], "a remembered path that no longer exists is dropped")
        XCTAssertEqual(paths(c).first, ".env.local")
        XCTAssertEqual(Set(c.filter(\.preselected).map(\.path)), [".env.local", ".mcp.json", "node_modules/", "secrets/a.txt"])
    }

    func testDSStoreIsNotOffered() {
        write(".gitignore", ".DS_Store\n")   // overwrite in the working tree; .DS_Store itself stays ignored
        try! svc.git.run(["commit", "-qam", "ds"], in: repo.path)
        write(".DS_Store", "x")
        XCTAssertFalse(paths(co.candidates(for: repo)).contains(".DS_Store"))
    }

    func testSizeScanStopsAtFileCap() throws {
        let big = dir + "/big"
        try fm.createDirectory(atPath: big, withIntermediateDirectories: true)
        for i in 0..<5 { write("f\(i)", "12345", in: big) }
        XCTAssertEqual(try CarryOver.size(of: big).0, 25)
        XCTAssertFalse(try CarryOver.size(of: big).capped)
        let capped = try CarryOver.size(of: big, fileCap: 3)
        XCTAssertTrue(capped.capped)
        XCTAssertEqual(capped.0, 15)
    }

    func testSizeScanStopsWhenCancelled() async {
        let big = dir + "/big"
        for i in 0..<3 { write("f\(i)", "x", in: big) }
        let t = Task { () throws -> Int64 in
            while !Task.isCancelled { await Task.yield() }
            return try CarryOver.size(of: big).0
        }
        t.cancel()
        do { _ = try await t.value; XCTFail("a cancelled scan throws") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testEntriesListOneLevelWithoutFollowingSymlinks() throws {
        write("secrets/sub/c.txt", "ccc")
        write("secrets/.DS_Store", "x")
        try fm.createSymbolicLink(atPath: repo.path + "/secrets/link", withDestinationPath: "sub")
        let e = try XCTUnwrap(CarryOver.entries(in: "secrets/", root: repo.path))
        let byPath = Dictionary(uniqueKeysWithValues: e.map { ($0.path, $0) })
        XCTAssertEqual(Set(byPath.keys), ["secrets/a.txt", "secrets/b.txt", "secrets/sub/", "secrets/link"])
        XCTAssertEqual(byPath["secrets/a.txt"]?.size, 1)
        XCTAssertTrue(byPath["secrets/sub/"]!.isDir)
        XCTAssertFalse(byPath["secrets/link"]!.isDir, "a symlinked folder is a leaf")
        XCTAssertNil(CarryOver.entries(in: "missing/", root: repo.path))
    }

    func testAncestors() {
        XCTAssertEqual(CarryOver.ancestors(of: "a/b/c.txt"), ["a/", "a/b/"])
        XCTAssertEqual(CarryOver.ancestors(of: "a/b/"), ["a/"])
        XCTAssertEqual(CarryOver.ancestors(of: ".env"), [])
    }

    func testStampChangesWithIgnoreRulesAndMemory() throws {
        let before = CarryOver.stamp(for: repo)
        XCTAssertEqual(CarryOver.stamp(for: repo), before)
        var r = repo!
        r.carryOver = [".env.local"]
        XCTAssertNotEqual(CarryOver.stamp(for: r), before, "remembering choices invalidates the cached list")
        write(".worktreeinclude", ".mcp.json\n")
        XCTAssertNotEqual(CarryOver.stamp(for: repo), before)
    }

    // MARK: Copy

    func testCopiesChosenPathsAndKeepsSymlinksAsLinks() throws {
        try fm.createSymbolicLink(atPath: repo.path + "/secrets/link", withDestinationPath: "a.txt")
        let dst = dir + "/wt"
        try svc.git.worktreeAddDetached(repo: repo.path, path: dst, base: "main")
        let w = co.copy(paths: [".claude/settings.local.json", "secrets/", "secrets/a.txt"], from: repo.path, to: dst)
        XCTAssertEqual(w, [])
        XCTAssertEqual(read(dst + "/.claude/settings.local.json"), "{\"local\":true}")
        XCTAssertEqual(read(dst + "/secrets/b.txt"), "b")
        XCTAssertEqual(try fm.destinationOfSymbolicLink(atPath: dst + "/secrets/link"), "a.txt")
        XCTAssertEqual(read(dst + "/.claude/shared.md"), "tracked", "the tracked sibling is untouched")
    }

    func testNeverOverwritesTrackedFiles() throws {
        let dst = dir + "/wt"
        try svc.git.worktreeAddDetached(repo: repo.path, path: dst, base: "main")
        write(".claude/shared.md", "local edit")   // differs from the committed version
        let w = co.copy(paths: [".claude/shared.md"], from: repo.path, to: dst)
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("already has it"))
        XCTAssertEqual(read(dst + "/.claude/shared.md"), "tracked")
    }

    func testRejectsPathsOutsideTheRepository() throws {
        let dst = dir + "/wt"
        try svc.git.worktreeAddDetached(repo: repo.path, path: dst, base: "main")
        write("outside.txt", "nope", in: dir)
        let w = co.copy(paths: ["../outside.txt", "/etc/hosts", "secrets/../../outside.txt", "", "~/x"], from: repo.path, to: dst)
        XCTAssertEqual(w.count, 5)
        XCTAssertTrue(w.allSatisfy { $0.contains("only paths inside the repository") })
        XCTAssertNil(CarryOver.normalized("a/./b"))
        XCTAssertEqual(CarryOver.normalized("node_modules/"), "node_modules")
    }

    func testRejectsCopyThroughSymlinkedFolder() throws {
        let outside = dir + "/elsewhere"
        try fm.createDirectory(atPath: outside, withIntermediateDirectories: true)
        write("leak.txt", "secret", in: outside)
        try fm.createSymbolicLink(atPath: repo.path + "/linked", withDestinationPath: outside)
        let dst = dir + "/wt"
        try svc.git.worktreeAddDetached(repo: repo.path, path: dst, base: "main")
        let w = co.copy(paths: ["linked/leak.txt"], from: repo.path, to: dst)
        XCTAssertEqual(w.count, 1)
        XCTAssertFalse(fm.fileExists(atPath: dst + "/linked/leak.txt"))
    }

    func testMissingSourceIsAWarning() throws {
        let dst = dir + "/wt"
        try svc.git.worktreeAddDetached(repo: repo.path, path: dst, base: "main")
        let w = co.copy(paths: ["gone.txt", ".env.local"], from: repo.path, to: dst)
        XCTAssertEqual(w.count, 1)
        XCTAssertTrue(w[0].contains("gone.txt"))
        XCTAssertEqual(read(dst + "/.env.local"), "TOKEN=1")
    }

    // MARK: Workspace creation

    func testCreateCopiesCarryOverAndWarnsWithoutRollingBack() throws {
        var warnings: [String] = []
        let ws = try svc.create(name: "W", branch: "",
                                selections: [RepoSelection(repo: repo, base: "main", carryOver: [".env.local", "gone.txt"])],
                                existingNames: [], onWarning: { warnings.append($0) })
        XCTAssertEqual(read(ws.repos[0].worktreePath + "/.env.local"), "TOKEN=1")
        XCTAssertEqual(warnings.count, 1)
        XCTAssertTrue(warnings[0].hasPrefix("app: "))
        XCTAssertTrue(fm.fileExists(atPath: ws.root), "a failed copy keeps the workspace")
        XCTAssertFalse(try svc.git.status(ws.repos[0].worktreePath).dirty, "copied files are ignored, so the worktree stays clean")
    }

    func testCreateWithoutCarryOverCopiesNothing() throws {
        let ws = try svc.create(name: "W", branch: "", selections: [RepoSelection(repo: repo, base: "main")], existingNames: [])
        XCTAssertFalse(fm.fileExists(atPath: ws.repos[0].worktreePath + "/.env.local"))
    }

    // MARK: Persistence

    func testSchema3RepoDecodesWithEmptyCarryOver() throws {
        let json = """
        {"schemaVersion":3,"repos":[{"id":"\(UUID().uuidString)","name":"a","path":"/a","defaultBranch":"main"}],"workspaces":[]}
        """
        let s = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(s.repos.count, 1)
        XCTAssertEqual(s.repos[0].carryOver, [])
        XCTAssertEqual(s.schemaVersion, 4)
    }

    func testMalformedCarryOverKeepsTheRepo() throws {
        let json = """
        {"schemaVersion":4,"repos":[{"name":"a","path":"/a","defaultBranch":"main","carryOver":"oops"}]}
        """
        let s = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(s.repos.map(\.name), ["a"])
        XCTAssertEqual(s.repos[0].carryOver, [])
    }

    func testCarryOverRoundTripsAndSetCarryOver() throws {
        var s = AppState()
        s.repos = [repo]
        XCTAssertTrue(s.setCarryOver(repo.id, to: [".env.local"]))
        XCTAssertFalse(s.setCarryOver(repo.id, to: [".env.local"]), "no change")
        XCTAssertFalse(s.setCarryOver(UUID(), to: ["x"]), "unknown repo")
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(back.repos[0].carryOver, [".env.local"])
    }
}
