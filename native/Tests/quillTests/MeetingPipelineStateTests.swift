import Foundation
import XCTest
@testable import quill

final class MeetingPipelineStateTests: XCTestCase {
    private func folder() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-state-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"status":"stopped","ended":"2026-10-08T09:00:00Z","started":"2026-10-08T08:00:00Z","recording_id":"fixture"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        return dir
    }
    func testAttemptsAndFailureSurviveRelaunchAndStopAtThree() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        for attempt in 1...3 {
            var state = try MeetingPipelineState.load(dir, now: Double(attempt * 1000))
            try state.reserveTranscription(at: Double(attempt * 1000))
            XCTAssertFalse(state.mayTranscribe(at: Double(attempt * 1000 + 1)))
            state.transcriptionFailed(URLError(.networkConnectionLost), at: Double(attempt * 1000))
            try state.write(dir)
        }
        let restored = try MeetingPipelineState.load(dir)
        XCTAssertEqual(restored.transcription.count, 3)
        XCTAssertEqual(restored.transcription.lastError?.code, "speech_retry_limit")
        XCTAssertFalse(restored.mayTranscribe(at: 100_000))
    }
    func testModelSetupOnlyRearmsTheMissingModelCause() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        var state = try MeetingPipelineState.load(dir, now: 0)
        try state.reserveTranscription(at: 0)
        state.transcriptionFailed(SpeechRecognitionIssue.localModelMissing, at: 0)
        try state.write(dir)
        var restored = try MeetingPipelineState.load(dir)
        XCTAssertEqual(restored.stage, .waitingForModel)
        XCTAssertFalse(restored.mayTranscribe(at: 1000))
        restored.localModelInstalled(at: 1000)
        XCTAssertTrue(restored.mayTranscribe(at: 1000))
        XCTAssertEqual(restored.transcription.count, 0)
        restored.transcriptionFailed(SpeechRecognitionIssue.cloudCredentialsMissing, at: 1000)
        restored.localModelInstalled(at: 2000)
        XCTAssertFalse(restored.mayTranscribe(at: 2000))
        restored.speechCredentialsInstalled(at: 2000)
        XCTAssertTrue(restored.mayTranscribe(at: 2000))
        restored.transcriptionFailed(SpeechRecognitionIssue.localModelMissing, at: 2000)
        restored.speechCredentialsInstalled(at: 3000)
        XCTAssertFalse(restored.mayTranscribe(at: 3000))
    }
    func testMalformedOrAnotherMeetingsStateCannotBeOverwritten() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("state.json")
        let malformed = Data("{".utf8); try malformed.write(to: file)
        XCTAssertThrowsError(try MeetingPipelineState.load(dir))
        XCTAssertEqual(try Data(contentsOf: file), malformed)
        try FileManager.default.removeItem(at: file)
        let state = try MeetingPipelineState.load(dir)
        try state.write(dir)
        var meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        meta["recording_id"] = "different"
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try MeetingPipelineState.load(dir))
        XCTAssertThrowsError(try state.write(dir))
    }
}
