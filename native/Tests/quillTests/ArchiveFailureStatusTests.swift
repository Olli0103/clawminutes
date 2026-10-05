import Foundation
import XCTest
@testable import quill

private actor ArchiveFixtureEngine: TranscriptionEngine {
    nonisolated let name = "parakeet"
    nonisolated let model = "fixture"
    func prepare() async throws {}
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 1, text: "Fixture speech")]
    }
}
private final class StatusEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [TranscriptionCoordinator.Status] = []
    func append(_ status: TranscriptionCoordinator.Status) { lock.withLock { rows.append(status) } }
    var failed: Bool { lock.withLock { rows.contains { if case .failed = $0 { return true }; return false } } }
    var archivePending: Bool { lock.withLock { rows.contains { if case .archivePending = $0 { return true }; return false } } }
}
final class ArchiveFailureStatusTests: XCTestCase, @unchecked Sendable {
    func testGateway404AfterSuccessfulTranscriptionIsNotATranscriptionFailure() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-archive-status-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(#"{"files":{"mic":"mic.caf"}}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        let engine = ArchiveFixtureEngine()
        let coordinator = TranscriptionCoordinator(activityLockPath: dir.appendingPathComponent("lifecycle.lock"),
            saveArchive: { _ in throw GatewayArchive.ConnectionIssue.routeUnavailable }, makeEngine: { _, _ in engine })
        let done = expectation(description: "Pipeline reports completion or an issue")
        done.assertForOverFulfill = false
        let evidence = StatusEvidence()
        await coordinator.setStatusHandler { status in
            evidence.append(status)
            switch status {
            case .idle, .failed, .archivePending: done.fulfill()
            default: break
            }
        }
        await coordinator.enqueue(dir, transcriptionEnabled: true)
        await fulfillment(of: [done], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        XCTAssertFalse(evidence.failed, "Successful recognition followed by Gateway 404 was presented as processing failure")
        XCTAssertTrue(evidence.archivePending, "Archive failure must remain visible and retryable")
    }
}
