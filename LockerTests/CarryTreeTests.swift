import XCTest

/// The lazily loaded folder tree the composer draws for "Local files to copy", and its tri-state selection.
final class CarryTreeTests: XCTestCase {
    private func cand(_ p: String, _ size: Int64? = nil, _ source: CarryOver.Source = .detected) -> CarryOver.Candidate {
        CarryOver.Candidate(path: p, size: p.hasSuffix("/") ? nil : (size ?? 1), source: source, heavy: CarryOver.isHeavy(p))
    }
    private func entry(_ p: String, _ size: Int64 = 1) -> CarryOver.Entry {
        CarryOver.Entry(path: p, isDir: p.hasSuffix("/"), size: p.hasSuffix("/") ? 0 : size)
    }
    private func names(_ rows: [CarryTree.Row]) -> [String] {
        rows.map { String(repeating: "  ", count: $0.depth) + ($0.node == nil ? "<\($0.note!)>" : $0.name) }
    }

    func testGroupsFromGitPathsAndSingleChildGroupsAreFlattened() {
        let t = CarryTree(candidates: [
            cand(".env"), cand(".claude/settings.local.json"),
            cand("Config/a.plist"), cand("Config/b.plist"), cand("node_modules/"),
        ])
        XCTAssertEqual(names(t.visibleRows(open: [])), [".claude/settings.local.json", ".env", "Config/", "node_modules/"])
        XCTAssertEqual(t.nodes["Config/"]?.kind, .group)
        XCTAssertNil(t.nodes[".claude/"], "a group holding one entry is dropped")
        XCTAssertEqual(names(t.visibleRows(open: ["Config/"])),
                       [".claude/settings.local.json", ".env", "Config/", "  a.plist", "  b.plist", "node_modules/"])
    }

    func testFolderLoadsLazilyWithPlaceholders() {
        var t = CarryTree(candidates: [cand("secrets/")])
        XCTAssertEqual(t.unloaded(in: ["secrets/"]), ["secrets/"])
        XCTAssertEqual(names(t.visibleRows(open: ["secrets/"])), ["secrets/", "  <loading>"])
        t.setChildren(of: "secrets/", [entry("secrets/b.txt", 5), entry("secrets/a.txt", 3), entry("secrets/sub/")])
        XCTAssertEqual(names(t.visibleRows(open: ["secrets/"])), ["secrets/", "  a.txt", "  b.txt", "  sub/"])
        XCTAssertEqual(t.unloaded(in: ["secrets/", "secrets/sub/"]), ["secrets/sub/"])
        t.setChildren(of: "secrets/sub/", [])
        XCTAssertEqual(names(t.visibleRows(open: ["secrets/", "secrets/sub/"])).last, "    <empty>")
        t.setChildren(of: "secrets/sub/", nil)
        XCTAssertEqual(names(t.visibleRows(open: ["secrets/", "secrets/sub/"])).last, "    <unreadable>")
    }

    func testSizesAndSizingOrder() {
        var t = CarryTree(candidates: [cand("node_modules/"), cand("Config/a.plist", 10), cand("Config/b/"), cand("data/")])
        XCTAssertNil(t.size(of: "Config/"), "a group's size waits for its folders")
        XCTAssertEqual(t.nextUnsized(excluding: [])?.path, "data/", "top level first")
        XCTAssertEqual(t.nextUnsized(excluding: ["data/"])?.path, "Config/b/")
        XCTAssertEqual(t.nextUnsized(excluding: ["Config/b/", "data/"])?.path, "node_modules/", "build output goes last")
        XCTAssertEqual(t.nextUnsized(excluding: ["Config/b/", "data/"])?.heavy, true)
        t.setSize("Config/b/", 5, capped: true)
        XCTAssertEqual(t.size(of: "Config/")?.0, 15)
        XCTAssertEqual(t.size(of: "Config/")?.capped, true)
        t.setChildren(of: "data/", [entry("data/x/")])
        t.setSize("data/", 1, capped: false)
        t.setSize("node_modules/", 1, capped: false)
        XCTAssertEqual(t.nextUnsized(excluding: [])?.path, "data/x/", "loaded folders are sized too")

        var reloaded = CarryTree(candidates: [cand("node_modules/"), cand("data/")])
        reloaded.adoptSizes(from: t)
        XCTAssertEqual(reloaded.size(of: "data/")?.0, 1)
    }

    func testTickingAFolderReplacesPicksInsideIt() {
        var t = CarryTree(candidates: [cand("secrets/")])
        t.setChildren(of: "secrets/", [entry("secrets/a.txt"), entry("secrets/b.txt")])
        var picked = t.toggle("secrets/a.txt", [])
        XCTAssertEqual(picked, ["secrets/a.txt"])
        XCTAssertEqual(t.checkState("secrets/", picked), .mixed)
        picked = t.toggle("secrets/", picked)
        XCTAssertEqual(picked, ["secrets/"])
        XCTAssertEqual(t.checkState("secrets/b.txt", picked), .on, "a ticked folder covers its contents")
        XCTAssertEqual(t.toggle("secrets/", picked), [])
    }

    func testUntickingInsideATickedFolderKeepsTheSiblings() {
        var t = CarryTree(candidates: [cand("secrets/")])
        t.setChildren(of: "secrets/", [entry("secrets/a.txt"), entry("secrets/sub/")])
        t.setChildren(of: "secrets/sub/", [entry("secrets/sub/c.txt"), entry("secrets/sub/d.txt")])
        let picked = t.toggle("secrets/sub/c.txt", ["secrets/"])
        XCTAssertEqual(picked, ["secrets/a.txt", "secrets/sub/d.txt"])
        XCTAssertEqual(t.checkState("secrets/", picked), .mixed)
        XCTAssertEqual(t.checkState("secrets/sub/", picked), .mixed)
    }

    func testGroupTicksWhatItHolds() {
        let t = CarryTree(candidates: [cand("Config/a.plist"), cand("Config/b/")])
        var picked: Set<String> = ["Config/a.plist"]
        XCTAssertEqual(t.checkState("Config/", picked), .mixed)
        picked = t.toggle("Config/", picked)
        XCTAssertEqual(picked, ["Config/a.plist", "Config/b/"])
        XCTAssertEqual(t.checkState("Config/", picked), .on)
        XCTAssertEqual(t.toggle("Config/", picked), [])
    }

    func testPreselectedEntryInsideAFolderOpensItAndKeepsItsSource() {
        var t = CarryTree(candidates: [cand("secrets/"), cand("secrets/sub/a.txt", 1, .worktreeinclude), cand(".env", 1, .remembered)])
        XCTAssertEqual(t.preselected, ["secrets/sub/a.txt", ".env"])
        XCTAssertEqual(t.initialOpen, ["secrets/", "secrets/sub/"])
        XCTAssertNil(t.nodes["secrets/sub/a.txt"], "shown once its folder loads")
        t.setChildren(of: "secrets/", [entry("secrets/sub/")])
        t.setChildren(of: "secrets/sub/", [entry("secrets/sub/a.txt")])
        XCTAssertEqual(t.nodes["secrets/sub/a.txt"]?.source, .worktreeinclude)
        XCTAssertEqual(t.checkState("secrets/", t.preselected), .mixed)
        XCTAssertEqual(names(t.visibleRows(open: [])).first, ".env", "remembered entries come first")
    }

    func testFilterShowsMatchesAndTheFoldersLeadingToThem() {
        var t = CarryTree(candidates: [cand(".env"), cand("secrets/"), cand("node_modules/")])
        t.setChildren(of: "secrets/", [entry("secrets/api.key"), entry("secrets/other.txt")])
        XCTAssertEqual(names(t.visibleRows(open: [], filter: "API")), ["secrets/", "  api.key"], "case-insensitive, opens the way")
        XCTAssertEqual(names(t.visibleRows(open: [], filter: "secrets")), ["secrets/"], "a matching folder isn't opened for you")
        XCTAssertEqual(names(t.visibleRows(open: ["secrets/"], filter: "secrets")), ["secrets/", "  api.key", "  other.txt"])
        XCTAssertEqual(t.visibleRows(open: [], filter: "zzz"), [])
    }

    func testPickedSize() {
        var t = CarryTree(candidates: [cand(".env", 3), cand("secrets/")])
        XCTAssertNil(t.pickedSize([".env", "secrets/"]))
        t.setSize("secrets/", 7, capped: false)
        XCTAssertEqual(t.pickedSize([".env", "secrets/"])?.0, 10)
    }

    /// Picks made in the tree are paths `CarryOver.copy` accepts as they are.
    func testPicksRoundTripThroughCopy() throws {
        let dir = TestSupport.tempDir()
        let svc = WorkspaceService(lockerRoot: dir + "/Locker")
        let repo = TestSupport.makeRepo(named: "app", in: dir)
        try "secrets/\n".write(toFile: repo.path + "/.gitignore", atomically: true, encoding: .utf8)
        try svc.git.run(["add", "."], in: repo.path)
        try svc.git.run(["commit", "-q", "-m", "ignore"], in: repo.path)
        try FileManager.default.createDirectory(atPath: repo.path + "/secrets/sub", withIntermediateDirectories: true)
        for f in ["a.txt", "sub/c.txt", "sub/d.txt"] { try f.write(toFile: repo.path + "/secrets/" + f, atomically: true, encoding: .utf8) }

        var t = CarryTree(candidates: CarryOver().candidates(for: repo))
        t.setChildren(of: "secrets/", CarryOver.entries(in: "secrets/", root: repo.path))
        t.setChildren(of: "secrets/sub/", CarryOver.entries(in: "secrets/sub/", root: repo.path))
        let picked = t.toggle("secrets/sub/c.txt", t.toggle("secrets/", []))

        let dst = dir + "/wt"
        try svc.git.worktreeAddDetached(repo: repo.path, path: dst, base: "main")
        XCTAssertEqual(CarryOver().copy(paths: picked.sorted(), from: repo.path, to: dst), [])
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: dst + "/secrets/a.txt"))
        XCTAssertTrue(fm.fileExists(atPath: dst + "/secrets/sub/d.txt"))
        XCTAssertFalse(fm.fileExists(atPath: dst + "/secrets/sub/c.txt"))
    }
}
