import XCTest
@testable import quill

final class MenuPresentationTests: XCTestCase {
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
        XCTAssertEqual(activity.title, "Transcript ready")
        XCTAssertFalse(activity.isWorking)
        let detail = try XCTUnwrap(MenuPresentation.pipelineDetail(status))
        XCTAssertTrue(detail.contains("Transcript ready on this Mac"))
        XCTAssertTrue(detail.contains("retry pending saves"))
        XCTAssertFalse(detail.contains("Transcription did not finish"))
    }
    func testRecordingTakesPriorityWhilePreviousMeetingTranscribes() {
        XCTAssertEqual(MenuPresentation.activity(recording: true, elapsed: "1:24", status: .transcribing(session: "previous", queued: 0)), .recording("1:24"))
    }
    func testIconOnlyHidesTextInEveryState() {
        for state in [HelperActivity.ready, .failed, .archivePending, .transcribing, .recording("1:00")] {
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
}
