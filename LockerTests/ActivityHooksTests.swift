import XCTest

final class ActivityHooksTests: XCTestCase {
    private let script = "/Users/me/Library/Application Support/Locker/hooks/locker-hook.sh"

    private func json(_ d: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] ?? [:] }

    func testMergeIntoEmptyAddsEveryEvent() throws {
        let out = json(try ActivityHooks.merge(into: nil, scriptPath: script))
        let hooks = try XCTUnwrap(out["hooks"] as? [String: Any])
        XCTAssertEqual(Set(hooks.keys), Set(ActivityHooks.events.map(\.event)))
        let stop = try XCTUnwrap((hooks["Stop"] as? [[String: Any]])?.first?["hooks"] as? [[String: Any]])
        XCTAssertEqual(stop.first?["command"] as? String, "\"\(script)\" stop")
    }

    func testMergeKeepsOtherSettingsAndHooksAndIsIdempotent() throws {
        let existing = #"{"permissions":{"allow":["Bash(ls)"]},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let once = try ActivityHooks.merge(into: Data(existing.utf8), scriptPath: script)
        let twice = try ActivityHooks.merge(into: once, scriptPath: script)
        let out = json(twice)
        XCTAssertNotNil(out["permissions"])
        let stop = try XCTUnwrap((out["hooks"] as? [String: Any])?["Stop"] as? [Any])
        XCTAssertEqual(stop.count, 2)   // the user's own hook + exactly one Locker hook
    }

    func testRemovingKeepsUserContent() throws {
        let existing = #"{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]}}"#
        let merged = try ActivityHooks.merge(into: Data(existing.utf8), scriptPath: script)
        XCTAssertTrue(ActivityHooks.isInstalled(in: merged))
        let rest = try XCTUnwrap(try ActivityHooks.removing(from: merged))
        XCTAssertFalse(ActivityHooks.isInstalled(in: rest))
        let out = json(rest)
        XCTAssertEqual(out["model"] as? String, "opus")
        XCTAssertEqual(((out["hooks"] as? [String: Any])?["Stop"] as? [Any])?.count, 1)
    }

    func testRemovingFromLockerOnlyFileLeavesNothing() throws {
        let merged = try ActivityHooks.merge(into: nil, scriptPath: script)
        XCTAssertNil(try ActivityHooks.removing(from: merged))
    }

    func testInvalidJSONIsNeverOverwritten() {
        XCTAssertThrowsError(try ActivityHooks.merge(into: Data("{not json".utf8), scriptPath: script))
    }

    func testCombine() {
        typealias C = ClaudeActivity
        XCTAssertEqual(C.combine(screen: .busy, hook: .stop), .busy)       // subagents still running after the main Stop
        XCTAssertEqual(C.combine(screen: .idle, hook: .stop), .prompt)     // immediate, no debounce
        XCTAssertEqual(C.combine(screen: .unknown, hook: .prompt), .prompt)
        XCTAssertEqual(C.combine(screen: .unknown, hook: .busy), .busy)
        XCTAssertEqual(C.combine(screen: .idle, hook: .busy), .idle)       // interrupted turn sends no Stop
        XCTAssertEqual(C.combine(screen: .idle, hook: nil), .idle)
    }

    func testStoreInstallsScriptSignalsAndSettings() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("locker-hooks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let store = ActivityHookStore(base: base)
        try store.prepare()
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: store.scriptURL.path))

        let id = UUID()
        XCTAssertNil(store.signal(for: id))
        // Run the real script the way Claude Code would.
        let p = Process()
        p.executableURL = store.scriptURL
        p.arguments = ["stop"]
        p.environment = Dictionary(uniqueKeysWithValues: store.environment(for: id).map {
            let kv = $0.split(separator: "=", maxSplits: 1); return (String(kv[0]), String(kv[1])) })
        try p.run(); p.waitUntilExit()
        XCTAssertEqual(store.signal(for: id), .stop)
        store.clear(id)
        XCTAssertNil(store.signal(for: id))

        // Outside Locker (no env) the script does nothing and succeeds.
        let q = Process(); q.executableURL = store.scriptURL; q.arguments = ["busy"]; q.environment = [:]
        try q.run(); q.waitUntilExit()
        XCTAssertEqual(q.terminationStatus, 0)

        let dir = base.appendingPathComponent("ws").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertFalse(store.isInstalled(in: dir))
        try store.install(in: dir)
        XCTAssertTrue(store.isInstalled(in: dir))
        try store.uninstall(from: dir)
        XCTAssertFalse(store.isInstalled(in: dir))
    }

    func testProjectFlagDecodesLeniently() throws {
        let old = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"A","repoIDs":[]}"#.utf8))
        XCTAssertFalse(old.exactHighlight)
        let bad = try JSONDecoder().decode(Project.self, from: Data(#"{"name":"A","exactHighlight":"yes"}"#.utf8))
        XCTAssertFalse(bad.exactHighlight)
    }
}
