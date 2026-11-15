import XCTest

final class ComposerOpsTests: XCTestCase {
    let api = Repo(name: "api", path: "/code/shop/api", defaultBranch: "main")
    let web = Repo(name: "web", path: "/code/shop/web", defaultBranch: "main")
    let docs = Repo(name: "docs", path: "/code/other/docs", defaultBranch: "main")
    var all: [Repo] { [api, web, docs] }

    func testFilterByNameOrPath() {
        XCTAssertEqual(ComposerOps.filter(all, query: "").map(\.name), ["api", "web", "docs"])
        XCTAssertEqual(ComposerOps.filter(all, query: " WEB ").map(\.name), ["web"])
        XCTAssertEqual(ComposerOps.filter(all, query: "shop").map(\.name), ["api", "web"])
        XCTAssertTrue(ComposerOps.filter(all, query: "zzz").isEmpty)
    }

    func testAllNoneActOnShownOnly() {
        let shown = [api, web]
        var chosen: Set<UUID> = [docs.id]
        chosen = ComposerOps.setAll(chosen, shown: shown, on: true)
        XCTAssertEqual(chosen, [api.id, web.id, docs.id])
        chosen = ComposerOps.setAll(chosen, shown: shown, on: false)
        XCTAssertEqual(chosen, [docs.id])
        chosen = ComposerOps.setAll([], shown: shown, on: true) { [web] in $0.id != web.id }
        XCTAssertEqual(chosen, [api.id])
    }

    func testProjectChipTicksThenClears() {
        let p = Project(name: "Shop", repoIDs: [api.id, web.id])
        var chosen: Set<UUID> = [docs.id, api.id]
        XCTAssertFalse(ComposerOps.isProjectOn(p, chosen: chosen, repos: all))
        chosen = ComposerOps.toggleProject(p, chosen: chosen, repos: all)
        XCTAssertEqual(chosen, [api.id, web.id, docs.id])
        XCTAssertTrue(ComposerOps.isProjectOn(p, chosen: chosen, repos: all))
        chosen = ComposerOps.toggleProject(p, chosen: chosen, repos: all)
        XCTAssertEqual(chosen, [docs.id])
    }

    func testProjectChipSkipsUnusableAndEmpty() {
        let p = Project(name: "Shop", repoIDs: [api.id, web.id])
        let webID = web.id
        let usable: (Repo) -> Bool = { $0.id != webID }
        let chosen = ComposerOps.toggleProject(p, chosen: [], repos: all, isUsable: usable)
        XCTAssertEqual(chosen, [api.id])
        XCTAssertTrue(ComposerOps.isProjectOn(p, chosen: chosen, repos: all, isUsable: usable))
        XCTAssertFalse(ComposerOps.isProjectOn(Project(name: "Empty"), chosen: chosen, repos: all))
    }

    func testWorkspaceSearch() {
        let ws = Workspace(name: "Apple Pay", branch: "feat/pay",
                           repos: [WorkspaceRepo(repoID: api.id, repoName: "api", worktreePath: "/x/api", baseBranch: "main", lastBranch: "feat/pay")],
                           terminals: [], activeTerminal: nil, root: "/x")
        XCTAssertTrue(ws.matches(""))
        XCTAssertTrue(ws.matches("apple"))
        XCTAssertTrue(ws.matches("API"))
        XCTAssertTrue(ws.matches("feat/"))
        XCTAssertFalse(ws.matches("web"))
    }
}

final class ClaudeActivityTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(ClaudeActivity.classify(claudeInForeground: false, screen: ["esc to interrupt"]), .none)
        XCTAssertEqual(ClaudeActivity.classify(claudeInForeground: true, screen: ["✻ Thinking… (12s · esc to interrupt)"]), .running)
        XCTAssertEqual(ClaudeActivity.classify(claudeInForeground: true, screen: ["Do you want to proceed?", "❯ 1. Yes"]), .waiting)
        XCTAssertEqual(ClaudeActivity.classify(claudeInForeground: true, screen: []), .waiting)
    }

    func testPriority() {
        XCTAssertEqual(ClaudeActivity.combined([]), .none)
        XCTAssertEqual(ClaudeActivity.combined([.none, .running]), .running)
        XCTAssertEqual(ClaudeActivity.combined([.running, .waiting, .none]), .waiting)
    }

    func testProcessMatching() {
        XCTAssertTrue(ClaudeActivity.isClaudeProcess(executablePath: "/Users/a/.local/share/claude/versions/2.1.3", arguments: ["claude"]))
        XCTAssertTrue(ClaudeActivity.isClaudeProcess(executablePath: "/opt/bin/claude", arguments: []))
        XCTAssertTrue(ClaudeActivity.isClaudeProcess(executablePath: "/usr/local/bin/node",
                                                     arguments: ["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"]))
        XCTAssertFalse(ClaudeActivity.isClaudeProcess(executablePath: "/bin/zsh", arguments: ["-zsh"]))
        XCTAssertFalse(ClaudeActivity.isClaudeProcess(executablePath: "/usr/bin/vim", arguments: ["vim", "claude-notes.md"]))
    }

    func testProcessInspectorReadsOwnArguments() {
        let me = ProcessInspector.arguments(of: getpid())
        XCTAssertNotNil(me)
        XCTAssertFalse(me?.path.isEmpty ?? true)
        XCTAssertTrue(ProcessInspector.pids(inGroup: getpgrp()).contains(getpid()))
        XCTAssertTrue(ProcessInspector.foregroundProcesses(ptyFD: -1).isEmpty)
    }
}
