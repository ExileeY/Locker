import XCTest

final class ProjectTests: XCTestCase {
    private func repo(_ name: String) -> Repo { Repo(name: name, path: "/tmp/\(name)", defaultBranch: "main") }

    func testSchema2StateWithoutProjectsDecodesAndUpgrades() throws {
        let rid = UUID().uuidString
        let json = #"{"schemaVersion":2,"repos":[{"id":"\#(rid)","name":"a","path":"/a","defaultBranch":"main"}],"workspaces":[]}"#
        let st = try JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        XCTAssertEqual(st.schemaVersion, 3)
        XCTAssertEqual(st.repos.count, 1)
        XCTAssertTrue(st.projects.isEmpty)
    }

    func testProjectRoundTrips() throws {
        var st = AppState()
        let a = repo("a"), b = repo("b")
        st.repos = [a, b]
        st.projects = [Project(name: "Storefront", repoIDs: [a.id, b.id])]
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(back.projects, st.projects)
    }

    func testMalformedProjectDoesNotWipeState() throws {
        let rid = UUID().uuidString
        // projects has the wrong shape entirely, and one project has a bad repoIDs value.
        let bad1 = #"{"schemaVersion":3,"repos":[{"id":"\#(rid)","name":"a","path":"/a","defaultBranch":"main"}],"workspaces":[],"projects":"oops"}"#
        let s1 = try JSONDecoder().decode(AppState.self, from: Data(bad1.utf8))
        XCTAssertEqual(s1.repos.count, 1)
        XCTAssertTrue(s1.projects.isEmpty)

        let bad2 = #"{"schemaVersion":3,"repos":[{"id":"\#(rid)","name":"a","path":"/a","defaultBranch":"main"}],"workspaces":[],"projects":[{"name":"P","repoIDs":"nope"}]}"#
        let s2 = try JSONDecoder().decode(AppState.self, from: Data(bad2.utf8))
        XCTAssertEqual(s2.repos.count, 1)
        XCTAssertEqual(s2.projects.first?.name, "P")
        XCTAssertEqual(s2.projects.first?.repoIDs, [])
    }

    func testSelectableRepoIDsIgnoresDeletedAndUnusableRepos() {
        let a = repo("a"), b = repo("b"), gone = repo("gone")
        let p = Project(name: "P", repoIDs: [a.id, b.id, gone.id, UUID()])   // `gone` is no longer registered, plus a dangling id
        let registered = [a, b, repo("other")]
        XCTAssertEqual(p.selectableRepoIDs(in: registered), [a.id, b.id])
        XCTAssertEqual(p.selectableRepoIDs(in: registered) { $0.id != b.id }, [a.id])   // b's folder is missing
        XCTAssertEqual(p.members(in: registered).map(\.name), ["a", "b"])
    }

    func testRepoCanBelongToManyProjects() {
        var st = AppState()
        let a = repo("a")
        st.repos = [a]
        st.projects = [Project(name: "One", repoIDs: [a.id]), Project(name: "Two", repoIDs: [a.id])]
        XCTAssertEqual(st.projects.filter { $0.repoIDs.contains(a.id) }.count, 2)
    }

    func testRemovingRepoStripsItFromEveryProject() {
        var st = AppState()
        let a = repo("a"), b = repo("b")
        st.repos = [a, b]
        st.projects = [Project(name: "One", repoIDs: [a.id, b.id]), Project(name: "Two", repoIDs: [a.id])]
        st.removeRepoFromProjects(a.id)
        XCTAssertEqual(st.projects.map(\.repoIDs), [[b.id], []])
        XCTAssertEqual(st.projects.count, 2)   // projects themselves survive
    }
}
