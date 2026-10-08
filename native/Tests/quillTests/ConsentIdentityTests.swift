import XCTest
@testable import quill

final class ConsentIdentityTests: XCTestCase {
    private func call(_ window: UInt32, title: String = "Weekly planning", launch: Double = 100) -> DetectedMeeting {
        DetectedMeeting(id: "123:\(window)", app: "Teams", service: "Microsoft Teams",
            consentIdentity: .init(processID: 123, processStartedAt: launch, windowID: window, title: title))
    }
    func testRelaunchKeepsSameCallButPromptsForNewWindowInSameProcess() throws {
        var original = ConsentPromptState()
        XCTAssertTrue(original.observe(call(50)))
        var restored = ConsentPromptState(saved: try original.savedData())
        XCTAssertFalse(restored.observe(call(50)))
        // An identical recurring title cannot establish that a different window
        // belongs to the call seen before the helper exited.
        var nextCall = ConsentPromptState(saved: try original.savedData())
        XCTAssertTrue(nextCall.observe(call(51)))
        XCTAssertFalse(nextCall.observe(call(51)))
    }
    func testDifferentTitleOrProcessIncarnationPrompts() throws {
        var original = ConsentPromptState()
        _ = original.observe(call(50))
        var restored = ConsentPromptState(saved: try original.savedData())
        XCTAssertTrue(restored.observe(call(50, title: "Design review")))
        XCTAssertFalse(restored.observe(call(50, title: "Design review")))
        var changedLive = ConsentPromptState()
        _ = changedLive.observe(call(50))
        XCTAssertTrue(changedLive.observe(call(50, title: "Design review")))
        var reusedPID = ConsentPromptState(saved: try original.savedData())
        XCTAssertTrue(reusedPID.observe(call(50, launch: 200)))
    }
    func testObservedCompactReplacementIsRememberedAcrossRelaunch() throws {
        var original = ConsentPromptState()
        _ = original.observe(call(50))
        XCTAssertFalse(original.observe(call(51)))
        var restored = ConsentPromptState(saved: try original.savedData())
        XCTAssertFalse(restored.observe(call(51)))
    }
    func testMissingIdentityNeverPersistsPIDOnlySuppression() throws {
        let unidentified = DetectedMeeting(id: "123:1", app: "Teams", service: "Microsoft Teams")
        var original = ConsentPromptState()
        _ = original.observe(unidentified)
        XCTAssertFalse(original.observe(unidentified))
        var restored = ConsentPromptState(saved: try original.savedData())
        XCTAssertTrue(restored.observe(unidentified))
        var malformed = ConsentPromptState(saved: Data("invalid".utf8))
        XCTAssertTrue(malformed.observe(call(50)))
    }
}
