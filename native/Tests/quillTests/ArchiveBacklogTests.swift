import Foundation
import XCTest
@testable import quill

private actor SaveCounter {
    private(set) var count = 0
    func save(_ dir: URL) { count += 1 }
}

final class ArchiveBacklogTests: XCTestCase, @unchecked Sendable {
    private func session(_ root: URL, status: String = "stopped") throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["status": status, "started": "2026-10-07T09:00:00Z", "ended": "2026-10-07T10:00:00Z"])
            .write(to: dir.appendingPathComponent("meta.json"))
        try Data(#"{"segments":[{"text":"Fixture speech","start_ms":0,"end_ms":1000}]}"#.utf8)
            .write(to: dir.appendingPathComponent("transcript.json"))
        return dir
    }

    func testBacklogDoesNotMistakeAnInvalidReceiptForDelivery() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(root)
        try Data(#"{"saved":false}"#.utf8).write(to: dir.appendingPathComponent("archive-receipt.json"))
        let saves = SaveCounter()
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"), saveArchive: { await saves.save($0) })
        await coordinator.resumePending(root: root)
        let count = await saves.count
        XCTAssertEqual(count, 1, "A receipt file is not proof that the transcript arrived")
    }

    func testBacklogNeverUploadsAnActiveRecordingEvenWithATranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try session(root, status: "recording")
        let saves = SaveCounter()
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"), saveArchive: { await saves.save($0) })
        await coordinator.resumePending(root: root)
        let count = await saves.count
        XCTAssertEqual(count, 0, "Backlog scans must exclude live recordings")
    }

    func testFailureIsRetriedWithoutRelaunchAndBackoffSurvivesRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try session(root)
        let saves = SaveCounter()
        let save: @Sendable (URL) async throws -> Void = { dir in
            await saves.save(dir)
            throw GatewayArchive.ConnectionIssue.routeUnavailable
        }
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"), saveArchive: save)
        let first = try await coordinator.retryArchiveBacklog(root: root, now: 100)
        XCTAssertEqual(first.pending, 1)
        XCTAssertEqual(first.attempted, 1)
        let deferred = try await coordinator.retryArchiveBacklog(root: root, now: 129)
        XCTAssertEqual(deferred.attempted, 0)
        let relaunched = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"), saveArchive: save)
        let stillDeferred = try await relaunched.retryArchiveBacklog(root: root, now: 129)
        XCTAssertEqual(stillDeferred.attempted, 0)
        let due = try await relaunched.retryArchiveBacklog(root: root, now: 130)
        XCTAssertEqual(due.attempted, 1)
        let forced = try await relaunched.retryArchiveBacklog(root: root, force: true, now: 131)
        XCTAssertEqual(forced.attempted, 1)
        let count = await saves.count
        XCTAssertEqual(count, 3)
    }

    func testVerifiedDeliveryRequiresCurrentHashAndActualExportFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(root), notes = root.appendingPathComponent("notes")
        let data = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        let id = "teams-" + AudioRetention.digest(Data(("2026-10-07T09:00:00Z\n" + dir.lastPathComponent).utf8)).prefix(24)
        let receipt: [String: Any] = ["saved": true, "sessionId": id, "utteranceCount": 1,
            "localTranscriptSHA256": AudioRetention.digest(data), "documents": ["title": "fixture"]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: dir.appendingPathComponent("archive-receipt.json"))
        try Data(notes.appendingPathComponent("meeting").path.utf8).write(to: dir.appendingPathComponent("notes-export-path.txt"))
        XCTAssertEqual(ArchiveBacklog.inspect(dir, notesRoot: notes).state, .exportPending)
        let export = notes.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: export, withIntermediateDirectories: true)
        for name in ["notes.md", "transcript.md"] { try Data("Fixture".utf8).write(to: export.appendingPathComponent(name)) }
        try JSONSerialization.data(withJSONObject: ["sessionId": id]).write(to: export.appendingPathComponent("metadata.json"))
        XCTAssertEqual(ArchiveBacklog.inspect(dir, notesRoot: notes).state, .saved)
        try Data(#"{"segments":[{"text":"Changed speech","start_ms":0,"end_ms":1000}]}"#.utf8).write(to: dir.appendingPathComponent("transcript.json"))
        XCTAssertEqual(ArchiveBacklog.inspect(dir, notesRoot: notes).state, .archivePending)
    }

    func testOverlappingBacklogChecksNeverSendTwice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try session(root)
        let saves = SaveCounter(), gate = SaveGate()
        let started = expectation(description: "Save started")
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"), saveArchive: { dir in
            await saves.save(dir); started.fulfill(); await gate.wait()
            throw GatewayArchive.ConnectionIssue.routeUnavailable
        })
        let initial = Task { try await coordinator.retryArchiveBacklog(root: root) }
        await fulfillment(of: [started], timeout: 5)
        let overlapping = try await coordinator.retryArchiveBacklog(root: root, force: true)
        XCTAssertTrue(overlapping.busy)
        await gate.open()
        _ = try await initial.value
        let count = await saves.count
        XCTAssertEqual(count, 1)
    }

    func testLegacySavedReceiptNeedsVerificationInsteadOfAutomaticResend() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let dir = try session(root)
        let id = "teams-" + AudioRetention.digest(Data(("2026-10-07T09:00:00Z\n" + dir.lastPathComponent).utf8)).prefix(24)
        try JSONSerialization.data(withJSONObject: ["saved": true, "sessionId": id, "utteranceCount": 1])
            .write(to: dir.appendingPathComponent("archive-receipt.json"))
        XCTAssertEqual(ArchiveBacklog.inspect(dir).state, .needsReview)
        let saves = SaveCounter()
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"), saveArchive: { await saves.save($0) })
        let report = try await coordinator.retryArchiveBacklog(root: root, force: true)
        XCTAssertEqual(report.needsReview, 1)
        XCTAssertEqual(report.attempted, 0)
        let count = await saves.count
        XCTAssertEqual(count, 0)
    }
}

private actor SaveGate {
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { opened = true; continuation?.resume(); continuation = nil }
}
