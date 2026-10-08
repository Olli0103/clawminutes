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
        var state = try MeetingPipelineState.load(dir)
        try state.write(dir)
        var meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        meta["recording_id"] = "different"
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try MeetingPipelineState.load(dir))
        XCTAssertThrowsError(try state.write(dir))
    }
    func testStaleSnapshotCannotEraseAnotherWritersAttemptLimit() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        var current = try MeetingPipelineState.load(dir, now: 0)
        var stale = try MeetingPipelineState.load(dir, now: 0)
        for now in [0.0, 1000, 2000] {
            try current.reserveTranscription(at: now)
            current.transcriptionFailed(URLError(.networkConnectionLost), at: now)
        }
        try current.write(dir)
        let preserved = try Data(contentsOf: dir.appendingPathComponent("state.json"))
        stale.updatedAt = 3000
        XCTAssertThrowsError(try stale.write(dir))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("state.json")), preserved)
        XCTAssertEqual(try MeetingPipelineState.load(dir).transcription.count, 3)
    }
}

extension MeetingPipelineStateTests {
    private func legacyDelivery(_ directory: URL, completions: Int? = 2) throws -> ArchiveBacklog.Retry {
        let data = Data(#"{"segments":[{"text":"Synthetic speech"}]}"#.utf8)
        try data.write(to: directory.appendingPathComponent("transcript.json"))
        var meta = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        meta["notes_mode"] = "ai"
        try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
        let retry = ArchiveBacklog.Retry(attempts: 5, nextAttemptAt: 7000, transcriptSHA256: AudioRetention.digest(data),
            completionAttempts: completions, lastError: DeliveryFailure(code: "ai_invalid_output", detail: "Synthetic failure", retryable: false, completionAttempted: true))
        try JSONEncoder().encode(retry).write(to: directory.appendingPathComponent("archive-retry.json"))
        return retry
    }
    func testSchemaOneAndRetryMigrationIsReadOnlyUntilAnAuthorizedWrite() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        let retry = try legacyDelivery(dir)
        let file = dir.appendingPathComponent("state.json"), legacy = dir.appendingPathComponent("archive-retry.json")
        let old: [String: Any] = ["schemaVersion": 1, "recordingIdentity": try MeetingPipelineState.identity(dir),
            "revision": 1, "stage": "needsAttention", "updatedAt": 6000,
            "transcription": ["count": 2, "nextAttemptAt": 0], "delivery": ["count": 5, "nextAttemptAt": 7000]]
        let original = try JSONSerialization.data(withJSONObject: old), oldRetry = try ArchiveBacklog.read(legacy)
        try original.write(to: file)
        var migrated = try MeetingPipelineState.load(dir)
        XCTAssertEqual(migrated.transcription.count, 2)
        XCTAssertEqual(migrated.deliveryRetry, retry)
        XCTAssertEqual(migrated.generation, 0)
        XCTAssertEqual(try ArchiveBacklog.read(file), original)
        XCTAssertEqual(try ArchiveBacklog.read(legacy), oldRetry)
        try migrated.write(dir)
        let restored = try MeetingPipelineState.load(dir)
        XCTAssertEqual(restored.schemaVersion, 2); XCTAssertEqual(restored.generation, 1)
        XCTAssertEqual(restored.transcription.count, 2); XCTAssertEqual(restored.deliveryRetry, retry)
        XCTAssertEqual(try ArchiveBacklog.read(legacy), oldRetry)
        let committed = try ArchiveBacklog.read(file)
        try migrated.write(dir)
        XCTAssertEqual(try ArchiveBacklog.read(file), committed, "Unchanged state is not another generation")
    }
    func testChangedOrRemovedLegacyEvidenceCannotResetMigratedCounts() throws {
        for remove in [false, true] {
            let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
            _ = try legacyDelivery(dir)
            var migrated = try MeetingPipelineState.load(dir); try migrated.write(dir)
            let committed = try ArchiveBacklog.read(dir.appendingPathComponent("state.json"))
            let legacy = dir.appendingPathComponent("archive-retry.json")
            if remove { try FileManager.default.removeItem(at: legacy) }
            else { try Data("{}".utf8).write(to: legacy) }
            XCTAssertThrowsError(try MeetingPipelineState.load(dir))
            migrated.updatedAt += 1
            XCTAssertThrowsError(try migrated.write(dir))
            XCTAssertEqual(ArchiveBacklog.inspect(dir).state, .needsReview)
            XCTAssertEqual(try ArchiveBacklog.read(dir.appendingPathComponent("state.json")), committed)
        }
    }
    func testDanglingStateAndLegacyLinksFailClosed() throws {
        for name in ["state.json", "archive-retry.json", "notes-recovery.json"] {
            let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
            var earlier = try MeetingPipelineState.load(dir)
            try FileManager.default.createSymbolicLink(at: dir.appendingPathComponent(name), withDestinationURL: dir.appendingPathComponent("absent"))
            XCTAssertThrowsError(try MeetingPipelineState.load(dir))
            XCTAssertThrowsError(try earlier.write(dir))
            XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: dir.appendingPathComponent(name).path), dir.appendingPathComponent("absent").path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("absent").path))
        }
    }
    func testUnknownLegacyPaidBudgetCannotGrantAIRecovery() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        _ = try legacyDelivery(dir, completions: nil)
        let imported = try MeetingPipelineState.load(dir)
        XCTAssertTrue(imported.delivery.budgetUnverified == true)
        XCTAssertEqual(ArchiveBacklog.inspect(dir).state, .needsReview)
        XCTAssertThrowsError(try NotesRecovery.prepare(dir, kind: .retryAI, activityLockPath: dir.appendingPathComponent("lease")))
        _ = try NotesRecovery.prepare(dir, kind: .transcriptOnly, activityLockPath: dir.appendingPathComponent("lease"))
        XCTAssertTrue(ArchiveBacklog.inspect(dir).pending)
        XCTAssertTrue(try MeetingPipelineState.load(dir).delivery.budgetUnverified == true)
        XCTAssertNil(try MeetingPipelineState.load(dir).delivery.completionAttempts)
    }
    func testStaleDeliveryEligibilityAndChangedSpeechCannotResetAttempts() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"segments":[{"text":"Synthetic speech"}]}"#.utf8).write(to: dir.appendingPathComponent("transcript.json"))
        let eligible = ArchiveBacklog.inspect(dir)
        try ArchiveBacklog.reserve(eligible, now: 1000)
        let committed = try ArchiveBacklog.read(dir.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try ArchiveBacklog.reserve(eligible, now: 1000))
        XCTAssertEqual(try MeetingPipelineState.load(dir).delivery.count, 1)
        try Data(#"{"segments":[{"text":"Changed speech"}]}"#.utf8).write(to: dir.appendingPathComponent("transcript.json"))
        let changed = ArchiveBacklog.inspect(dir)
        XCTAssertEqual(changed.state, .needsReview)
        XCTAssertThrowsError(try ArchiveBacklog.reserve(changed, now: 9000))
        XCTAssertEqual(try ArchiveBacklog.read(dir.appendingPathComponent("state.json")), committed)
    }
    func testAStageFlagCannotProveDeliveryOrAuthorizeDeletion() throws {
        let dir = try folder(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"segments":[{"text":"Synthetic speech"}]}"#.utf8).write(to: dir.appendingPathComponent("transcript.json"))
        var state = try MeetingPipelineState.load(dir)
        state.stage = .audioRemoved; try state.write(dir)
        XCTAssertEqual(ArchiveBacklog.inspect(dir).state, .archivePending)
        XCTAssertFalse(AudioRetention.explicitlyRemoved(dir))
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir))
    }
}
