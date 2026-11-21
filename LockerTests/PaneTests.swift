import XCTest

final class PaneTests: XCTestCase {
    // MARK: PaneLayout

    func testPaneWidthFollowsFraction() {
        // usable = 1006 - 6 = 1000; 0.4 -> 400, inside [280, 640]
        XCTAssertEqual(PaneLayout.paneWidth(fraction: 0.4, total: 1006), 400, accuracy: 0.001)
    }

    func testPaneWidthKeepsMinimums() {
        XCTAssertEqual(PaneLayout.paneWidth(fraction: 0.01, total: 1006), PaneLayout.minPane)
        XCTAssertEqual(PaneLayout.paneWidth(fraction: 0.99, total: 1006), 1000 - PaneLayout.minTerminal)
    }

    func testPaneWidthInNarrowWindowNeverNegative() {
        for total in [0.0, 100, 400, 600, 640] {
            let w = PaneLayout.paneWidth(fraction: 0.5, total: total)
            XCTAssertGreaterThanOrEqual(w, 0)
            XCTAssertLessThanOrEqual(w + PaneLayout.dividerWidth, max(total, PaneLayout.dividerWidth) + 0.001)
        }
    }

    func testPaneWidthIgnoresNonFiniteFraction() {
        let w = PaneLayout.paneWidth(fraction: .nan, total: 1006)
        XCTAssertEqual(w, PaneState.defaultFraction * 1000, accuracy: 0.001)
    }

    func testFractionIsInverseOfWidth() {
        let f = PaneLayout.fraction(forPaneWidth: 400, total: 1006)
        XCTAssertEqual(f, 0.4, accuracy: 0.0001)
        XCTAssertEqual(PaneLayout.fraction(forPaneWidth: -50, total: 1006), 0)
        XCTAssertEqual(PaneLayout.fraction(forPaneWidth: 5000, total: 1006), 1)
        XCTAssertEqual(PaneLayout.fraction(forPaneWidth: 100, total: 0), PaneState.defaultFraction)
    }

    // MARK: PaneState decoding

    func testStateDecodesWithDefaults() throws {
        let s = try JSONDecoder().decode(PaneState.self, from: Data("{}".utf8))
        XCTAssertEqual(s, PaneState())
    }

    func testBadFieldKeepsTheOthers() throws {
        let json = #"{"open": true, "widthFraction": "wide", "url": "http://localhost:3000"}"#
        let s = try JSONDecoder().decode(PaneState.self, from: Data(json.utf8))
        XCTAssertTrue(s.open)
        XCTAssertEqual(s.widthFraction, PaneState.defaultFraction)
        XCTAssertEqual(s.url, "http://localhost:3000")
    }

    // MARK: PaneStore

    private func tempStore() -> PaneStore {
        PaneStore(url: URL(fileURLWithPath: TestSupport.tempDir()).appendingPathComponent("panes.json"))
    }

    func testRoundTrip() {
        let store = tempStore()
        let a = UUID(), b = UUID()
        store.save([a: PaneState(open: true, widthFraction: 0.3, url: "http://localhost:5173"), b: PaneState()])
        let back = store.load()
        XCTAssertEqual(back[a], PaneState(open: true, widthFraction: 0.3, url: "http://localhost:5173"))
        XCTAssertEqual(back[b], PaneState())
    }

    func testMissingFileLoadsEmpty() {
        XCTAssertTrue(tempStore().load().isEmpty)
    }

    func testGarbageFileLoadsEmpty() throws {
        let store = tempStore()
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.url)
        XCTAssertTrue(store.load().isEmpty)
    }

    func testBadEntryAndBadKeyAreSkippedOthersSurvive() throws {
        let store = tempStore()
        let good = UUID(), bad = UUID()
        let json = """
        {"panes": {"\(good.uuidString)": {"open": true}, "\(bad.uuidString)": 7, "not-a-uuid": {"open": true}}}
        """
        try FileManager.default.createDirectory(at: store.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: store.url)
        let back = store.load()
        XCTAssertEqual(Set(back.keys), [good])
        XCTAssertTrue(back[good]?.open == true)
    }
}
