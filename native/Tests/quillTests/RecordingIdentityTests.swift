import XCTest
@testable import quill

final class RecordingIdentityTests: XCTestCase {
    @MainActor func testEndedContextDoesNotBlockFreshSpeakerEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date().timeIntervalSince1970
        let old = MeetingContext(meeting_id: "old", title: "Old call", title_source: "teams_window",
                                 first_observed_at: time - 100, last_observed_at: time - 15, ended_observed_at: time - 10)
        let session = try RecordingSession(root: root, context: old)
        let fresh = MeetingContext(meeting_id: "new", title: "Current call", title_source: "teams_window",
                                   first_observed_at: time + 1, last_observed_at: time + 1)
        session.updateMeetingContext(fresh)
        session.recordSpeakers(SpeakerObservation(observed_at: time + 1, meeting_id: "new", names: ["Fixture participant"], source: "meeting_tile"))
        session.checkpoint()
        let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: session.dir.appendingPathComponent("meta.json"))) as! [String: Any]
        XCTAssertEqual((metadata["meeting_context"] as? [String: Any])?["meeting_id"] as? String, "new")
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("speaker-observations.jsonl").path))
    }
    @MainActor func testFreshMeetingTitleFollowsTimestampInFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date().timeIntervalSince1970
        let context = MeetingContext(meeting_id: "call", title: "Portfolio sync", title_source: "teams_window", first_observed_at: time, last_observed_at: time)
        let session = try RecordingSession(root: root, context: context)
        XCTAssertTrue(session.dir.lastPathComponent.hasSuffix("_Portfolio-sync"))
    }
    func testFinishedRenamePreservesArchiveIdentityAndDoesNotRenameAgain() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = root.appendingPathComponent("2026.10.02-1332")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["status": "stopped", "started": "2026-10-02T11:32:42Z", "meeting_title_override": "Portfolio / sync"]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        try Data("preserved".utf8).write(to: dir.appendingPathComponent("transcript.md"))
        let target = try RecordingFolders.renameFinished(dir)
        XCTAssertTrue(target.lastPathComponent.contains("_Portfolio-sync"))
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: target.appendingPathComponent("meta.json"))) as! [String: Any]
        XCTAssertEqual(saved["recording_id"] as? String, "2026.10.02-1332")
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("transcript.md"), encoding: .utf8), "preserved")
        XCTAssertEqual(try RecordingFolders.renameFinished(target), target)
    }
    func testActiveFolderCannotBeRenamed() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["status": "recording", "meeting_title_override": "Call"]).write(to: dir.appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try RecordingFolders.renameFinished(dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }
    @MainActor func testDifferentLiveMeetingCannotInjectSpeakerEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date().timeIntervalSince1970
        let context = MeetingContext(meeting_id: "call", title: "Portfolio sync", title_source: "teams_window", first_observed_at: time, last_observed_at: time)
        let session = try RecordingSession(root: root, context: context)
        session.recordSpeakers(SpeakerObservation(observed_at: time + 1, meeting_id: "unrelated", names: ["Other person"], source: "meeting_tile"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("speaker-observations.jsonl").path))
    }
}
