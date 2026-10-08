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

    func testConfirmedEndAfterRelaunchClearsSavedConsentBeforeWindowReuse() throws {
        var original = ConsentPromptState()
        _ = original.observe(call(50))
        var restored = ConsentPromptState(saved: try original.savedData())
        XCTAssertTrue(restored.update([:], now: 1, confirmedEndedCalls: [try XCTUnwrap(call(50).consentIdentity)]))
        XCTAssertFalse(restored.update([:], now: 2, confirmedEndedCalls: [try XCTUnwrap(call(50).consentIdentity)]))
        // Persist the removal even though this helper has not prompted anyone yet.
        var relaunchedAgain = ConsentPromptState(saved: try restored.savedData())
        XCTAssertTrue(relaunchedAgain.observe(call(50)))
        XCTAssertFalse(relaunchedAgain.observe(call(50)))
    }

    func testUnknownOrDifferentEndEvidenceCannotClearRestoredConsent() throws {
        var original = ConsentPromptState()
        _ = original.observe(call(50))
        for identity in [call(51).consentIdentity, call(50, title: "Other call").consentIdentity,
                         call(50, launch: 200).consentIdentity, nil] {
            var restored = ConsentPromptState(saved: try original.savedData())
            XCTAssertFalse(restored.update([:], now: 1, confirmedEndedCalls: identity.map { [$0] } ?? []))
            XCTAssertFalse(restored.observe(call(50)))
        }
    }

    func testRestoredOngoingCallAndOpenPromptIgnoreStaleEndScreens() throws {
        var original = ConsentPromptState()
        _ = original.observe(call(50))
        let saved = try original.savedData()
        let identity = try XCTUnwrap(call(50).consentIdentity)
        var ongoing = ConsentPromptState(saved: saved)
        XCTAssertFalse(ongoing.observe(call(50)))
        XCTAssertFalse(ongoing.update(["123:50": .present(call(50))], now: 1, confirmedEndedCalls: [identity]))
        XCTAssertFalse(ongoing.observe(call(50)))
        var prompting = ConsentPromptState(saved: saved)
        XCTAssertFalse(prompting.update([:], now: 1, promptInProgress: true, confirmedEndedCalls: [identity]))
        XCTAssertFalse(prompting.observe(call(50)))
    }

    func testEndInventoryRequiresExplicitCompleteUnminimizedAndInactiveWindows() throws {
        let identity = try XCTUnwrap(call(50).consentIdentity)
        let ended = ConsentEndWindow(identity: identity, complete: true, minimized: false, inCall: false, endScreen: true)
        XCTAssertEqual(MeetingEvidence.confirmedConsentEnds([ended]), [identity])
        XCTAssertTrue(MeetingEvidence.confirmedConsentEnds([]).isEmpty)
        for other in [
            ConsentEndWindow(identity: nil, complete: false, minimized: false, inCall: false, endScreen: false),
            ConsentEndWindow(identity: nil, complete: true, minimized: true, inCall: false, endScreen: false),
            ConsentEndWindow(identity: nil, complete: true, minimized: false, inCall: true, endScreen: false)
        ] {
            XCTAssertTrue(MeetingEvidence.confirmedConsentEnds([ended, other]).isEmpty)
        }
        XCTAssertTrue(MeetingEvidence.confirmedConsentEnds([
            ConsentEndWindow(identity: identity, complete: true, minimized: false, inCall: false, endScreen: false)
        ]).isEmpty)
        XCTAssertTrue(MeetingEvidence.confirmedConsentEnds([
            ConsentEndWindow(identity: nil, complete: true, minimized: false, inCall: false, endScreen: true)
        ]).isEmpty)
    }
}
