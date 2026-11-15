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

    func testVisibleReposNarrowToProject() {
        let shop = Project(name: "Shop", repoIDs: [web.id, api.id])
        let projects = [shop]
        XCTAssertEqual(ComposerOps.visibleRepos(project: nil, projects: projects, repos: all).map(\.name), ["api", "web", "docs"])
        XCTAssertEqual(ComposerOps.visibleRepos(project: shop.id, projects: projects, repos: all).map(\.name), ["api", "web"])
        // A project id that no longer exists falls back to every repo rather than an empty grid.
        XCTAssertEqual(ComposerOps.visibleRepos(project: UUID(), projects: projects, repos: all).count, 3)
    }

    func testSelectionTicksUsableMembersOnly() {
        let shop = Project(name: "Shop", repoIDs: [api.id, web.id])
        let webID = web.id
        let usable: (Repo) -> Bool = { $0.id != webID }
        XCTAssertEqual(ComposerOps.selection(for: shop.id, projects: [shop], repos: all, isUsable: usable), [api.id])
        XCTAssertEqual(ComposerOps.selection(for: shop.id, projects: [shop], repos: all), [api.id, web.id])
        XCTAssertTrue(ComposerOps.selection(for: nil, projects: [shop], repos: all).isEmpty)
    }

    func testValidateReportsFirstIssue() {
        XCTAssertEqual(ComposerOps.validate(name: "  ", chosen: [api], branch: "", branchStates: [:], bases: [:]), .missingName)
        XCTAssertEqual(ComposerOps.validate(name: "Pay", chosen: [], branch: "", branchStates: [:], bases: [:]), .noRepos)
        XCTAssertEqual(ComposerOps.validate(name: "Pay", chosen: [api], branch: "", branchStates: [:], bases: [api.id: " "]),
                       .missingBase(repoName: "api"))
        // With a branch that already exists, the base is irrelevant.
        XCTAssertNil(ComposerOps.validate(name: "Pay", chosen: [api], branch: "feat", branchStates: [api.id: .existing], bases: [api.id: ""]))
        XCTAssertNil(ComposerOps.validate(name: "Pay", chosen: [api, web], branch: "", branchStates: [:], bases: [:]))
        XCTAssertEqual(ComposerIssue.missingName.message, "Enter a workspace name.")
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
