import XCTest
@testable import quill

final class RecordingActionTokenTests: XCTestCase {
    func testAnOldNotificationCannotKeepAnotherRecordingRunning() {
        var current = RecordingActionToken()
        XCTAssertFalse(current.accepts(nil))
        current.begin(); let first = current.value
        XCTAssertTrue(current.accepts(first))
        current.finish(); XCTAssertFalse(current.accepts(first))
        current.begin(); XCTAssertFalse(current.accepts(first))
        XCTAssertTrue(current.accepts(current.value))
        var relaunched = RecordingActionToken(); relaunched.begin()
        XCTAssertFalse(relaunched.accepts(current.value))
    }
}
