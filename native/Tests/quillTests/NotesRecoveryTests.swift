import Foundation
import XCTest
@testable import quill

final class NotesRecoveryTests: XCTestCase {
    private func session(_ root: URL, attempts: Int = 1) throws -> URL {
        let directory = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["recording_id": "recovery-fixture", "status": "stopped",
            "started": "2026-10-08T10:00:00Z", "ended": "2026-10-08T10:01:00Z", "audio_started_at": 1791453600,
            "notes_mode": "ai", "files": [String: String](), "note_template": NoteTemplate.defaults[0].json])
            .write(to: directory.appendingPathComponent("meta.json"))
        try Transcript(engine: "parakeet", model: "parakeet-tdt-0.6b-v3-coreml", created_at: "2026-10-08T10:02:00Z", segments: [
            .init(speaker: "system_unknown", start_ms: 0, end_ms: 1000, text: "Synthetic speech", source: "system")])
            .write(to: directory)
        let data = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        let error = DeliveryFailure(code: attempts >= 3 ? "ai_retry_limit" : "ai_invalid_output", detail: "Synthetic AI failure", retryable: false, completionAttempted: true)
        let retry = ArchiveBacklog.Retry(attempts: attempts, nextAttemptAt: 1000, transcriptSHA256: AudioRetention.digest(data), completionAttempts: attempts, lastError: error)
        try JSONEncoder().encode(retry).write(to: directory.appendingPathComponent("archive-retry.json"))
        return directory
    }
    func testTranscriptRecoveryPreservesSourceAndBudgetAndCanWaitForNetworkAfterCap() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try session(root, attempts: 3)
        let metadata = try ArchiveBacklog.read(directory.appendingPathComponent("meta.json")), transcript = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        let request = try NotesRecovery.prepare(directory, kind: .transcriptOnly, now: 1100, activityLockPath: root.appendingPathComponent("lease"))
        var item = ArchiveBacklog.inspect(directory)
        XCTAssertTrue(item.pending); XCTAssertEqual(item.retry?.completionAttempts, 3); XCTAssertEqual(item.retry?.attempts, 3)
        XCTAssertEqual(try NotesRecovery.active(directory, retry: item.retry, transcriptData: transcript), request)
        XCTAssertEqual(try ArchiveBacklog.read(directory.appendingPathComponent("meta.json")), metadata)
        XCTAssertEqual(try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json")), transcript)
        try ArchiveBacklog.reserve(item, now: 1100)
        try ArchiveBacklog.recordFailure(URLError(.notConnectedToInternet), directory: directory)
        item = ArchiveBacklog.inspect(directory)
        XCTAssertTrue(item.pending); XCTAssertEqual(item.retry?.lastError?.code, "network_unavailable")
        XCTAssertEqual(item.retry?.completionAttempts, 3)
        try ArchiveBacklog.recordFailure(DeliveryFailure.signInRequired, directory: directory)
        XCTAssertFalse(ArchiveBacklog.inspect(directory).pending)
        try ArchiveBacklog.rearmSignIn(ArchiveBacklog.inspect(directory), now: 1200)
        XCTAssertTrue(ArchiveBacklog.inspect(directory).pending, "A sign-in remedy must not be blocked by an old AI budget during text-only recovery")
        XCTAssertEqual(ArchiveBacklog.inspect(directory).retry?.completionAttempts, 3)
        let history = try XCTUnwrap(NotesRecovery.read(directory, transcriptData: transcript)).history
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].failure.code, "ai_retry_limit")
    }
    func testExplicitAIRetryDoesNotResetCountsOrAllowDuplicateClicks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try session(root)
        let first = try NotesRecovery.prepare(directory, kind: .retryAI, now: 1100, activityLockPath: root.appendingPathComponent("lease"))
        XCTAssertThrowsError(try NotesRecovery.prepare(directory, kind: .retryAI, activityLockPath: root.appendingPathComponent("lease")))
        var item = ArchiveBacklog.inspect(directory); XCTAssertTrue(item.pending); XCTAssertEqual(item.retry?.completionAttempts, 1)
        try ArchiveBacklog.reserve(item, now: 1100)
        let failure = DeliveryFailure(code: "ai_invalid_output", detail: "Synthetic second failure", retryable: false, completionAttempted: true)
        try ArchiveBacklog.recordFailure(failure, directory: directory)
        let second = try NotesRecovery.prepare(directory, kind: .retryAI, now: 1200, activityLockPath: root.appendingPathComponent("lease"))
        XCTAssertNotEqual(first.id, second.id); item = ArchiveBacklog.inspect(directory); XCTAssertEqual(item.retry?.completionAttempts, 2)
        try ArchiveBacklog.reserve(item, now: 1200); try ArchiveBacklog.recordFailure(failure, directory: directory)
        XCTAssertFalse(ArchiveBacklog.inspect(directory).pending)
        XCTAssertThrowsError(try NotesRecovery.prepare(directory, kind: .retryAI, activityLockPath: root.appendingPathComponent("lease")))
    }
    func testInterruptedIntentPublicationKeepsOldRequestAndStaleSourcesFailClosed() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try session(root)
        let first = try NotesRecovery.prepare(directory, kind: .retryAI, now: 1100, activityLockPath: root.appendingPathComponent("lease"))
        let oldRetry = try ArchiveBacklog.read(directory.appendingPathComponent("archive-retry.json"))
        try ArchiveBacklog.recordFailure(DeliveryFailure(code: "ai_invalid_output", detail: "Synthetic", retryable: false, completionAttempted: true), directory: directory)
        _ = try NotesRecovery.prepare(directory, kind: .transcriptOnly, now: 1200, activityLockPath: root.appendingPathComponent("lease"))
        try oldRetry.write(to: directory.appendingPathComponent("archive-retry.json"))
        let transcript = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        let retry = try JSONDecoder().decode(ArchiveBacklog.Retry.self, from: oldRetry)
        XCTAssertEqual(try NotesRecovery.active(directory, retry: retry, transcriptData: transcript), first)
        try Data("Changed speech".utf8).write(to: directory.appendingPathComponent("transcript.json"))
        XCTAssertThrowsError(try NotesRecovery.active(directory, retry: retry, transcriptData: Data("Changed speech".utf8)))
    }
    func testClosedRequestAndSavedMeetingsCannotBeRearmed() throws {
        XCTAssertThrowsError(try NotesRecovery.Request.decode(["kind": "retry_ai", "id": UUID().uuidString, "audio": "forbidden"]))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try session(root)
        try Data("Saved receipt".utf8).write(to: directory.appendingPathComponent("archive-receipt.json"))
        XCTAssertThrowsError(try NotesRecovery.prepare(directory, kind: .transcriptOnly, activityLockPath: root.appendingPathComponent("lease")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("notes-recovery.json").path))
    }
}
