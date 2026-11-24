import XCTest

final class ActivityNotificationTests: XCTestCase {
    private func should(_ old: ClaudeActivity, _ new: ClaudeActivity, active: Bool = false, visible: Bool = false, enabled: Bool = true) -> Bool {
        ActivityNotification.shouldNotify(old: old, new: new, appActive: active, isVisibleWorkspace: visible, enabled: enabled)
    }

    func testOnlyRunningToWaitingNotifies() {
        XCTAssertTrue(should(.running, .waiting))
        XCTAssertFalse(should(.none, .waiting))      // a fresh session landing on its prompt
        XCTAssertFalse(should(.waiting, .waiting))
        XCTAssertFalse(should(.waiting, .running))
        XCTAssertFalse(should(.running, .none))
    }

    func testSuppressedOnlyWhenUserIsLooking() {
        XCTAssertFalse(should(.running, .waiting, active: true, visible: true))
        XCTAssertTrue(should(.running, .waiting, active: true, visible: false))   // app active, other workspace
        XCTAssertTrue(should(.running, .waiting, active: false, visible: true))   // app in background
    }

    func testDisabledNeverNotifies() {
        XCTAssertFalse(should(.running, .waiting, enabled: false))
    }

    func testChangesDiffTreatsMissingAsNone() {
        let a = UUID(), b = UUID(), c = UUID()
        let old: [UUID: ClaudeActivity] = [a: .running, b: .waiting, c: .running]
        let new: [UUID: ClaudeActivity] = [a: .waiting, b: .running]   // c's terminals closed
        let ch = ActivityNotification.changes(old: old, new: new, appActive: false, visibleWorkspace: nil, enabled: true)
        XCTAssertEqual(ch.notify, [a])
        XCTAssertEqual(ch.clear, [b])
    }

    func testChangesSkipVisibleWorkspace() {
        let a = UUID(), b = UUID()
        let ch = ActivityNotification.changes(old: [a: .running, b: .running], new: [a: .waiting, b: .waiting],
                                              appActive: true, visibleWorkspace: a, enabled: true)
        XCTAssertEqual(ch.notify, [b])
    }

    func testPreferencesDecodeDefaultsNotifyOn() throws {
        let old = try JSONDecoder().decode(Preferences.self, from: Data(#"{"baseSource":"local"}"#.utf8))
        XCTAssertTrue(old.notifyOnNeedsInput)
        var p = Preferences(); p.notifyOnNeedsInput = false
        let back = try JSONDecoder().decode(Preferences.self, from: JSONEncoder().encode(p))
        XCTAssertFalse(back.notifyOnNeedsInput)
    }
}
