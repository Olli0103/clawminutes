import XCTest
@testable import quill

final class ConsentPromptTests: XCTestCase {
    private let full = DetectedMeeting(id: "123:1", app: "Teams", service: "Microsoft Teams")
    private let compact = DetectedMeeting(id: "123:2", app: "Teams", service: "Microsoft Teams")

    func testWindowReplacementInSameTeamsCallDoesNotPromptAgain() {
        var state = ConsentPromptState()
        XCTAssertTrue(state.observe(full))
        state.update([full.id: .ended, compact.id: .present(compact)], now: 2)
        XCTAssertFalse(state.observe(compact), "A replacement Teams window must not ask again for the ongoing call")
        state.update([full.id: .ended, compact.id: .present(compact)], now: 90)
        XCTAssertFalse(state.observe(full))
    }

    func testTransientEndDoesNotForgetConsent() {
        var state = ConsentPromptState()
        XCTAssertTrue(state.observe(full))
        state.update([full.id: .ended], now: 2)
        state.update([full.id: .present(full)], now: 4)
        XCTAssertFalse(state.observe(full), "One end observation must not re-arm the prompt")
    }

    func testDetectAndDismissPromptOnceAndNewCallCanPrompt() {
        var state = ConsentPromptState()
        XCTAssertTrue(state.observe(full))
        XCTAssertFalse(state.observe(full))
        var restored = ConsentPromptState(prompted: state.prompted)
        XCTAssertFalse(restored.observe(compact), "Saved consent covers replacement windows in the same Teams process")
        restored.update([compact.id: .ended], now: 10)
        restored.update([compact.id: .ended], now: 39)
        XCTAssertEqual(restored.prompted, [full.id, compact.id])
        restored.update([compact.id: .ended], now: 40)
        XCTAssertTrue(restored.observe(full), "A confirmed end permits the next call to ask once")
    }

    func testUnknownAndMissingObservationsCancelEndConfirmation() {
        for uncertain: [String: MeetingObservation] in [[full.id: .unknown], [:]] {
            var state = ConsentPromptState()
            _ = state.observe(full)
            state.update([full.id: .ended], now: 0)
            state.update(uncertain, now: 25)
            state.update([full.id: .ended], now: 50)
            state.update([full.id: .ended], now: 79)
            XCTAssertTrue(state.prompted.contains(full.id))
            state.update([full.id: .ended], now: 80)
            XCTAssertTrue(state.prompted.isEmpty)
        }
    }

    func testOneMissingWindowCannotClearTheOtherWindowsConsent() {
        var state = ConsentPromptState()
        _ = state.observe(full)
        _ = state.observe(compact)
        state.update([full.id: .ended], now: 0)
        state.update([full.id: .ended], now: 60)
        XCTAssertFalse(state.observe(compact))
    }

    func testOpenDialogCannotRearmDuringNestedScans() {
        var state = ConsentPromptState()
        _ = state.observe(full)
        state.update([full.id: .ended], now: 0, promptInProgress: true)
        state.update([full.id: .ended], now: 60, promptInProgress: true)
        XCTAssertFalse(state.observe(compact))
        state.update([full.id: .ended, compact.id: .ended], now: 70)
        state.update([full.id: .ended, compact.id: .ended], now: 100)
        XCTAssertTrue(state.observe(full))
    }

    func testIndependentTeamsProcessCanPrompt() {
        var state = ConsentPromptState()
        _ = state.observe(full)
        let other = DetectedMeeting(id: "456:1", app: "Teams", service: "Microsoft Teams")
        XCTAssertTrue(state.observe(other))
    }

    func testRetiredWindowsDoNotPreventLaterCallsFromEnding() {
        var state = ConsentPromptState()
        _ = state.observe(full)
        state.update([full.id: .ended], now: 0)
        state.update([full.id: .ended], now: 30)
        state.update([full.id: .ended], now: 90)
        state.update([compact.id: .present(compact)], now: 200)
        XCTAssertTrue(state.observe(compact))
        state.update([compact.id: .ended], now: 210)
        state.update([compact.id: .ended], now: 240)
        XCTAssertTrue(state.prompted.isEmpty)
        XCTAssertTrue(state.observe(full))
    }

    func testPolicyRearmingDoesNotRepeatPromptDuringWindowChurn() {
        var policy = MeetingPolicy()
        var state = ConsentPromptState()
        var prompts = 0
        let scans: [(Double, [String: MeetingObservation])] = [
            (0, [full.id: .present(full)]),
            (2, [full.id: .ended]),
            (4, [full.id: .present(full)]),
            (6, [full.id: .ended, compact.id: .present(compact)]),
            (60, [full.id: .present(full), compact.id: .present(compact)])
        ]
        for (now, observations) in scans {
            state.update(observations, now: now)
            if case .start(let meeting) = policy.update(observations, now: now) {
                if state.observe(meeting) { prompts += 1 }
                policy.startFailed(for: meeting)
            }
        }
        XCTAssertEqual(prompts, 1, "Dismiss must mean once per ongoing call, even if policy re-arms a window")
    }

    func testManualRecordingHandledChoiceSurvivesStopAndWindowChange() {
        var state = ConsentPromptState()
        var policy = MeetingPolicy()
        policy.recordingStarted(for: full)
        _ = state.observe(full) // MeetingAssistant records a manual start as handled consent.
        policy.recordingStopped()
        let observations: [String: MeetingObservation] = [full.id: .ended, compact.id: .present(compact)]
        state.update(observations, now: 10)
        if case .start(let meeting) = policy.update(observations, now: 10) {
            XCTAssertFalse(state.observe(meeting))
        } else {
            XCTFail("The test must exercise the replacement-window prompt candidate")
        }
    }
}
