import XCTest

final class RepoProjectOpsTests: XCTestCase {
    private func repo(_ n: String) -> Repo { Repo(name: n, path: "/tmp/\(n)", defaultBranch: "main") }

    private func state() -> (AppState, [Repo], Project) {
        var st = AppState()
        let rs = [repo("a"), repo("b"), repo("c")]
        st.repos = rs
        let p = Project(name: "Shop", repoIDs: rs.map(\.id))
        st.projects = [p]
        return (st, rs, p)
    }

    func testLinkAddsOnceAndRejectsDuplicatesAndUnknownProject() {
        var (st, rs, p) = state()
        st.unlink(rs[0].id, from: p.id)
        XCTAssertTrue(st.link(rs[0].id, to: p.id))
        XCTAssertFalse(st.link(rs[0].id, to: p.id))
        XCTAssertFalse(st.link(rs[0].id, to: UUID()))
        XCTAssertEqual(st.projects[0].repoIDs.filter { $0 == rs[0].id }.count, 1)
    }

    func testUnlinkKeepsRepoRegisteredAndReportsPosition() {
        var (st, rs, p) = state()
        XCTAssertEqual(st.unlink(rs[1].id, from: p.id), 1)
        XCTAssertEqual(st.repos.count, 3)
        XCTAssertNil(st.unlink(rs[1].id, from: p.id), "already removed")
    }

    func testRelinkRestoresOriginalPosition() {
        var (st, rs, p) = state()
        let before = st.projects[0].repoIDs
        let pos = st.unlink(rs[1].id, from: p.id)!
        st.relink(rs[1].id, to: p.id, at: pos)
        XCTAssertEqual(st.projects[0].repoIDs, before)
        st.relink(rs[1].id, to: p.id, at: 0)
        XCTAssertEqual(st.projects[0].repoIDs, before, "no duplicate on a second undo")
    }

    func testUnassignedReposOnlyWhenInNoProject() {
        var (st, rs, p) = state()
        XCTAssertTrue(st.unassignedRepos.isEmpty)
        let other = Project(name: "Infra", repoIDs: [rs[0].id])
        st.projects.append(other)
        st.unlink(rs[0].id, from: p.id)
        XCTAssertTrue(st.unassignedRepos.isEmpty, "still in Infra")
        st.unlink(rs[0].id, from: other.id)
        XCTAssertEqual(st.unassignedRepos.map { $0.id }, [rs[0].id])
    }

    func testSetDefaultBranch() {
        var (st, rs, _) = state()
        XCTAssertTrue(st.setDefaultBranch(rs[0].id, to: " develop "))
        XCTAssertEqual(st.repos[0].defaultBranch, "develop")
        XCTAssertFalse(st.setDefaultBranch(rs[0].id, to: "develop"), "unchanged")
        XCTAssertFalse(st.setDefaultBranch(rs[0].id, to: "  "))
        XCTAssertFalse(st.setDefaultBranch(UUID(), to: "x"))
    }

    func testDefaultBranchChangeSurvivesSaveAndLoad() throws {
        var (st, rs, _) = state()
        st.setDefaultBranch(rs[0].id, to: "develop")
        let back = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(st))
        XCTAssertEqual(back.repos[0].defaultBranch, "develop")
    }

    func testNewProjectNamesAreUnique() {
        var st = AppState()
        XCTAssertEqual(st.newProjectName(), "New project")
        st.projects.append(Project(name: "new project"))
        XCTAssertEqual(st.newProjectName(), "New project 2")
        st.projects.append(Project(name: "New project 2"))
        XCTAssertEqual(st.newProjectName(), "New project 3")
    }
}
