import XCTest
@testable import quill
final class ConsentPromptTests: XCTestCase {
    func testDetectAndDismissPromptOnceAndNewCallCanPrompt() {
        var state = ConsentPromptState()
        let meeting = DetectedMeeting(id: "teams-window", app: "Teams", service: "Microsoft Teams")
        XCTAssertTrue(state.observe(meeting))
        XCTAssertFalse(state.observe(meeting))
        // Dismiss leaves the prompt identity persisted; only an evidenced end clears it.
        var restored = ConsentPromptState(prompted: state.prompted)
        XCTAssertFalse(restored.observe(meeting))
        restored.ended(meeting.id)
        XCTAssertTrue(restored.observe(meeting))
    }
}
