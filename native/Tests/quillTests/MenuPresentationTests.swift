import XCTest
@testable import quill

final class MenuPresentationTests: XCTestCase {
    func testBoundaryReviewDoesNotClaimInterruptedCapture() throws {
        let metadata = Data("{\"capture_gaps\":[{\"source\":\"mic\",\"start_ms\":29000,\"end_ms\":31000,\"reason\":\"boundary_context_unverified\"}]}".utf8)
        let warning = try XCTUnwrap(MenuPresentation.restoredCaptureWarning(recording: false, current: nil, metadata: metadata))
        XCTAssertTrue(warning.contains("boundaries need review")); XCTAssertFalse(warning.contains("interrupted"))
        XCTAssertEqual(MenuPresentation.restoredCaptureWarning(recording: false, current: nil,
            metadata: Data("{\"capture_gaps\":[]}".utf8), transcript: metadata), warning,
            "Final transcription warnings must be read separately from the capture manifest")
    }
    func testPendingMeetingRestoresItsSavedCaptureReviewWarning() throws {
        let metadata = Data("{\"capture_gaps\":[{\"source\":\"mic\",\"start_ms\":3459,\"end_ms\":554883,\"reason\":\"frame_coverage_shortfall\"}]}".utf8)
        let warning = try XCTUnwrap(MenuPresentation.restoredCaptureWarning(recording: false, current: nil, metadata: metadata))
        XCTAssertTrue(warning.contains("timing uncertainty"))
        XCTAssertTrue(warning.contains("Audio is retained"))
        XCTAssertFalse(warning.contains("restarted"))
    }
    func testPreviousMeetingCannotOverrideActiveCaptureWarning() {
        let metadata = Data("{\"capture_gaps\":[{\"source\":\"system\",\"start_ms\":100,\"end_ms\":200,\"reason\":\"buffers_stalled\"}]}".utf8)
        XCTAssertNil(MenuPresentation.restoredCaptureWarning(recording: true, current: nil, metadata: metadata))
        XCTAssertEqual(MenuPresentation.restoredCaptureWarning(recording: true, current: "Current microphone interrupted", metadata: metadata), "Current microphone interrupted")
    }
    func testSavedInterruptionUsesItsGapEvidenceWithoutClaimingARecovery() throws {
        let metadata = Data("{\"capture_gaps\":[{\"source\":\"system\",\"start_ms\":100,\"end_ms\":200,\"reason\":\"buffers_stalled\"}]}".utf8)
        let warning = try XCTUnwrap(MenuPresentation.restoredCaptureWarning(recording: false, current: nil, metadata: metadata))
        XCTAssertTrue(warning.contains("interrupted"))
        XCTAssertFalse(warning.contains("restarted"))
    }
    func testCleanMeetingClearsPreviousSavedWarningButMissingEvidenceDoesNot() {
        XCTAssertNil(MenuPresentation.restoredCaptureWarning(recording: false, current: "Previous gap", metadata: Data("{\"capture_gaps\":[]}".utf8)))
        XCTAssertEqual(MenuPresentation.restoredCaptureWarning(recording: false, current: "Known gap", metadata: nil), "Known gap")
        XCTAssertEqual(MenuPresentation.restoredCaptureWarning(recording: false, current: "Known gap", metadata: Data("invalid".utf8)), "Known gap")
    }
    func testActualMicrosoftTeamsWatchingStatusRemainsDetected() {
        let title = MenuPresentation.meetingTitle(promptsEnabled: true, accessibilityGranted: true, detection: "Watching Microsoft Teams in Microsoft Teams")
        XCTAssertEqual(title, "Teams call detected")
        XCTAssertEqual(MenuPresentation.title(style: .descriptive, activity: .recording("0:12"), backend: "Local only", meeting: MenuPresentation.callSummary(title)), " Teams call · Recording · 0:12 · Local only")
    }
    func testMissingPermissionDoesNotClaimNoCall() {
        let title = MenuPresentation.meetingTitle(promptsEnabled: true, accessibilityGranted: false, detection: "No active Teams meeting detected")
        XCTAssertEqual(MenuPresentation.callSummary(title), "Manual only")
    }
    func testPreparingCaptureDoesNotAppearReadyOrRecording() {
        XCTAssertEqual(MenuPresentation.activity(recording: false, elapsed: "0:00", status: .idle, preparing: true), .preparing)
    }
    func testFailureDoesNotPretendTranscriptionIsRunning() {
        let activity = MenuPresentation.activity(recording: false, elapsed: "0:00", status: .failed(session: "2026.10.01-1636"))
        XCTAssertEqual(activity, .failed)
        XCTAssertFalse(activity.isWorking)
        XCTAssertEqual(MenuPresentation.title(style: .descriptive, activity: activity, backend: "Local only"), " Needs attention · Local only")
    }
    func testArchivePendingShowsCompletedTranscriptAndTheSpecificNextStep() throws {
        let status = TranscriptionCoordinator.Status.archivePending(session: "AI weekly")
        let activity = MenuPresentation.activity(recording: false, elapsed: "0:00", status: status)
        XCTAssertEqual(activity, .archivePending)
        XCTAssertEqual(activity.title, "Waiting to send")
        XCTAssertFalse(activity.isWorking)
        let detail = try XCTUnwrap(MenuPresentation.pipelineDetail(status))
        XCTAssertTrue(detail.contains("Transcript ready on this Mac"))
        XCTAssertTrue(detail.contains("recovery options"))
        XCTAssertFalse(detail.contains("Transcription did not finish"))
    }
    func testRecordingTakesPriorityWhilePreviousMeetingTranscribes() {
        XCTAssertEqual(MenuPresentation.activity(recording: true, elapsed: "1:24", status: .transcribing(session: "previous", queued: 0)), .recording("1:24"))
    }
    func testIconOnlyHidesTextInEveryState() {
        for state in [HelperActivity.ready, .audioCheck("10s"), .failed, .archivePending, .transcribing, .recording("1:00")] {
            XCTAssertEqual(MenuPresentation.title(style: .iconOnly, activity: state, backend: "Local only"), "")
        }
    }
    func testAppearancePersistsWithoutClobberingGatewayOrEngine() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.json")
        try Data("{\"gateway\":{\"url\":\"https://gateway.example.com\"},\"transcription\":{\"engine\":\"parakeet\"}}".utf8).write(to: url)
        XCTAssertTrue(Config.setMenuBarStyle(.iconOnly, at: url))
        let config = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        XCTAssertEqual(config["menu_bar_style"] as? String, "icon_only")
        XCTAssertEqual((config["gateway"] as? [String: String])?["url"], "https://gateway.example.com")
        XCTAssertEqual((config["transcription"] as? [String: String])?["engine"], "parakeet")
    }
    func testAudioCheckIsVisibleAsActiveWorkAndHasItsOwnTitle() {
        XCTAssertTrue(HelperActivity.audioCheck("10s").isWorking)
        XCTAssertEqual(MenuPresentation.title(style: .descriptive, activity: .audioCheck("10s"), backend: "Audio stays here"),
            " Audio check · 10s · Audio stays here")
    }

    func testChunkRecognitionIsVisibleWithoutReplacingActiveRecording() throws {
        let status = TranscriptionCoordinator.Status.recognizingChunk(session: "meeting", queued: 2)
        XCTAssertEqual(MenuPresentation.activity(recording: true, elapsed: "5:00", status: status), .recording("5:00"))
        XCTAssertEqual(MenuPresentation.activity(recording: false, elapsed: "5:00", status: status), .transcribing)
        let detail = try XCTUnwrap(MenuPresentation.pipelineDetail(status))
        XCTAssertTrue(detail.contains("on this Mac"))
        XCTAssertTrue(detail.contains("final transcript is still pending"))
    }

}
