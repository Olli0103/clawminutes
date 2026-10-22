import XCTest
@testable import quill

final class NativeNotificationTests: XCTestCase {
    @MainActor func testNotesAndCallEndHaveExplicitActionsAndScopedContext() {
        let notes = NativeNotifications.content(title: "Notes ready", body: "Planning", category: .notesReady, context: ["meetingID": "fixture"])
        XCTAssertEqual(notes.categoryIdentifier, "notes_ready")
        XCTAssertEqual(notes.userInfo["meetingID"] as? String, "fixture")
        let stop = NativeNotifications.content(title: "Call ended?", body: "Stopping in 30 seconds", category: .callEnd, context: ["recordingToken": "fixture-token"])
        XCTAssertEqual(stop.categoryIdentifier, "call_end")
        XCTAssertEqual(stop.userInfo["recordingToken"] as? String, "fixture-token")
    }
    @MainActor
    func testNativeContentKeepsLiteralBodyAndUsesAppNameOnlyOnce() async {
        let body = "Quotes \" and $() stay literal\nnext line"
        let content = NativeNotifications.content(title: "ocmh: Recording started", body: body)
        XCTAssertEqual(content.title, "Recording started")
        XCTAssertEqual(content.body, body)
        XCTAssertNil(content.sound)
    }
}
