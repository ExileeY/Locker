import XCTest

final class WorkspaceOrderTests: XCTestCase {
    let a = WorkspaceOrderTests.make("a"), b = WorkspaceOrderTests.make("b")
    let c = WorkspaceOrderTests.make("c"), d = WorkspaceOrderTests.make("d")
    var all: [Workspace] { [a, b, c, d] }

    static func make(_ n: String) -> Workspace {
        Workspace(name: n, branch: nil, repos: [], terminals: [], activeTerminal: nil, root: "/tmp/\(n)")
    }

    func names(_ l: [Workspace]) -> [String] { l.map(\.name) }

    func testLastToFirst() {
        XCTAssertEqual(names(WorkspaceOrder.move(all, id: d.id, before: a.id)), ["d", "a", "b", "c"])
    }

    func testFirstToEnd() {
        XCTAssertEqual(names(WorkspaceOrder.move(all, id: a.id, before: nil)), ["b", "c", "d", "a"])
    }

    func testMiddleMoves() {
        XCTAssertEqual(names(WorkspaceOrder.move(all, id: b.id, before: d.id)), ["a", "c", "b", "d"])
        XCTAssertEqual(names(WorkspaceOrder.move(all, id: c.id, before: a.id)), ["c", "a", "b", "d"])
    }

    func testDropOnSelfOrUnknownIsNoOp() {
        XCTAssertEqual(names(WorkspaceOrder.move(all, id: b.id, before: b.id)), ["a", "b", "c", "d"])
        XCTAssertEqual(names(WorkspaceOrder.move(all, id: UUID(), before: a.id)), ["a", "b", "c", "d"])
    }

    func testDropBeforeNextRowKeepsOrder() {
        XCTAssertEqual(names(WorkspaceOrder.move(all, id: a.id, before: b.id)), ["a", "b", "c", "d"])
    }

    func testShift() {
        XCTAssertEqual(names(WorkspaceOrder.shift(all, id: c.id, by: -1)), ["a", "c", "b", "d"])
        XCTAssertEqual(names(WorkspaceOrder.shift(all, id: c.id, by: 1)), ["a", "b", "d", "c"])
        XCTAssertEqual(names(WorkspaceOrder.shift(all, id: a.id, by: -1)), ["a", "b", "c", "d"])
        XCTAssertEqual(names(WorkspaceOrder.shift(all, id: d.id, by: 1)), ["a", "b", "c", "d"])
    }

    func testOrderSurvivesJSONRoundTrip() throws {
        var s = AppState()
        s.workspaces = WorkspaceOrder.move(all, id: d.id, before: a.id)
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppState.self, from: data)
        XCTAssertEqual(names(back.workspaces), ["d", "a", "b", "c"])
    }
}
