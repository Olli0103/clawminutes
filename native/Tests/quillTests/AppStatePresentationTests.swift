import XCTest
import AVFoundation
@testable import quill

@MainActor
final class AppStatePresentationTests: XCTestCase {
    private func meeting(_ name: String = "Planning", code: String = "sign_in_required", stage: MeetingPipelineState.Stage = .needsAttention) -> RecentMeeting {
        RecentMeeting(directory: URL(fileURLWithPath: "/synthetic/" + name), title: name, started: Date(), stage: stage,
            issue: DeliveryFailure(code: code, detail: "fixture", retryable: code == "network_unavailable", completionAttempted: code == "ai_generation_failed"),
            detail: "fixture", notes: nil, transcript: URL(fileURLWithPath: "/synthetic/transcript.md"))
    }
    func testHeadlinePriorityNeverHidesAnActiveCallBehindAttention() {
        let state = AppState()
        state.recentMeetings = [meeting()]
        XCTAssertEqual(state.headline, .attention)
        state.pipelineStatus = .transcribing(session: "Old meeting", queued: 0)
        XCTAssertEqual(state.headline, .processing)
        state.detection = "Teams meeting detected"
        XCTAssertEqual(state.headline, .callDetected)
        state.recording = true
        XCTAssertEqual(state.headline, .recording)
        XCTAssertEqual(state.attentionGroups.count, 1)
        XCTAssertEqual(state.recentMeetings.first?.issue?.code, "sign_in_required")
    }
    func testCallDetectedIncludesTitleAndStaleSubjectDoesNotProveCall() {
        let state = AppState()
        state.meetingSubject = "Portfolio sync"
        state.detection = "No active Teams meeting detected"
        XCTAssertEqual(state.headline, .ready)
        XCTAssertEqual(state.primaryTitle, "Start recording")
        state.detection = "Teams meeting detected"
        XCTAssertEqual(state.primaryTitle, "Record Portfolio sync")
    }
    func testThreeSameCausesHaveOneFixAndMixedCausesStaySeparate() {
        let state = AppState()
        state.recentMeetings = (1...3).map { meeting("Planning \($0)") }
        XCTAssertEqual(state.attentionGroups.count, 1)
        XCTAssertEqual(state.attentionGroups[0].meetings.count, 3)
        XCTAssertEqual(state.attentionGroups[0].action, "Sign in")
        state.recentMeetings = [meeting(), meeting("Review", code: "network_unavailable"), meeting("Customer", code: "ai_generation_failed")]
        XCTAssertEqual(state.attentionGroups.map(\.cause), [.signIn, .gateway, .aiNotes])
    }
    func testDifferentUnknownCausesAreNeverCollapsedIntoOneBanner() {
        let state = AppState()
        state.recentMeetings = [meeting("Speech", code: "local_model_missing"), meeting("File", code: "local_save_failed")]
        XCTAssertEqual(state.attentionGroups.count, 2)
        XCTAssertEqual(Set(state.attentionGroups.map(\.id)).count, 2)
    }
    func testPipelineFailureBeforeBacklogRefreshStillShowsAttention() {
        let state = AppState()
        state.pipelineStatus = .failed(session: "Fixture")
        XCTAssertEqual(state.headline, .attention)
        state.detection = "Teams meeting detected"
        XCTAssertEqual(state.headline, .callDetected)
    }
    func testInterruptedRecordingAndUnconfirmedNotesAreDifferentCauses() {
        var unconfirmed = meeting(code: "fixture")
        unconfirmed.canVerifyLegacyReceipt = true
        XCTAssertEqual(AttentionCause.forMeeting(unconfirmed), .unconfirmed)
        unconfirmed.hasCaptureWarnings = true
        XCTAssertEqual(AttentionCause.forMeeting(unconfirmed), .interrupted)
    }
    func testOnlyActualSavingStagesShowSending() {
        let state = AppState()
        state.recentMeetings = [meeting(stage: .delivering)]
        XCTAssertEqual(state.headline, .sending)
        state.recentMeetings = [meeting(stage: .exported)]
        XCTAssertEqual(state.headline, .ready)
    }
    func testRelativeDatesUseTodayYesterdayAndShortDate() {
        let locale = Locale(identifier: "en_GB")
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = Date(timeIntervalSince1970: 1791531000)
        XCTAssertTrue(MeetingDate.string(now, now: now, calendar: calendar, locale: locale).hasPrefix("Today"))
        XCTAssertTrue(MeetingDate.string(now.addingTimeInterval(-86400), now: now, calendar: calendar, locale: locale).hasPrefix("Yesterday"))
        let older = MeetingDate.string(now.addingTimeInterval(-86400 * 5), now: now, calendar: calendar, locale: locale)
        XCTAssertFalse(older.contains("Today")); XCTAssertFalse(older.contains("Yesterday"))
        XCTAssertTrue(MeetingDate.title(nil, started: now).hasPrefix("Teams call · "))
    }
    func testDisabledMeterDoesNoWorkAndEnabledMeterExposesRMS() throws {
        let meter = AudioLevelMeter()
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64))
        buffer.frameLength = 64
        for channel in 0..<2 { for i in 0..<64 { buffer.floatChannelData![channel][i] = 0.5 } }
        meter.observe(buffer); XCTAssertEqual(meter.value, 0)
        meter.setEnabled(true); meter.observe(buffer)
        XCTAssertEqual(meter.value, 0.5, accuracy: 0.0001)
        meter.setEnabled(false); XCTAssertEqual(meter.value, 0)
        XCTAssertEqual(buffer.floatChannelData![0][0], 0.5, "Display telemetry must not mutate capture buffers")
    }
    func testRenameChangesOnlyOverrideAndPreservesDeliveryFingerprint() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meta: [String: Any] = ["status": "stopped", "started": "2026-10-09T09:00:00Z", "recording_id": "fixture", "meeting_context": ["title": "Original"]]
        let file = root.appendingPathComponent("meta.json")
        try JSONSerialization.data(withJSONObject: meta).write(to: file)
        let transcript: [String: Any] = ["segments": [["text": "Fixture", "start_ms": 0, "end_ms": 1000]]]
        let before = try GatewayArchive.envelope(meta: meta, transcript: transcript, recordingID: "fixture")
        try MeetingTitleOverride.save("New title", in: root)
        let after = try ArchiveBacklog.object(file)
        XCTAssertEqual(after["meeting_title_override"] as? String, "New title")
        XCTAssertEqual(after["status"] as? String, "stopped")
        XCTAssertEqual(after["recording_id"] as? String, "fixture")
        let beforeJSON = try JSONSerialization.jsonObject(with: before) as! NSDictionary
        let afterJSON = try JSONSerialization.jsonObject(with: GatewayArchive.envelope(meta: after, transcript: transcript, recordingID: "fixture")) as! NSDictionary
        XCTAssertEqual(beforeJSON, afterJSON, "UI rename must not change the text-delivery envelope")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("state.json").path))
    }
    func testRenameRejectsActiveRecordingAndLockContention() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("meta.json")
        let original = try JSONSerialization.data(withJSONObject: ["status": "recording"])
        try original.write(to: file)
        XCTAssertThrowsError(try MeetingTitleOverride.save("Rename", in: root))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let lock = try XCTUnwrap(AppRunLock.acquire(at: root.appendingPathComponent("archive.lock")))
        XCTAssertThrowsError(try MeetingTitleOverride.save("Rename", in: root))
        withExtendedLifetime(lock) {}
    }
}
