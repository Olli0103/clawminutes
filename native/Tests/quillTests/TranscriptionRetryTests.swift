import Foundation
import XCTest
@testable import quill

private actor RetrySpeechEngine: TranscriptionEngine {
    nonisolated let name = "parakeet"
    nonisolated let model = "fixture"
    var missingModel: Bool
    var transient: Bool
    private(set) var preparations = 0
    init(missingModel: Bool = false, transient: Bool = false) { self.missingModel = missingModel; self.transient = transient }
    func installModel() { missingModel = false }
    func prepare() async throws {
        preparations += 1
        if missingModel { throw SpeechRecognitionIssue.localModelMissing }
        if transient { throw URLError(.networkConnectionLost) }
    }
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] { [.init(start: 0, end: 1, text: "Fixture speech")] }
}
final class TranscriptionRetryTests: XCTestCase, @unchecked Sendable {
    private func fixture() throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-speech-retry-" + UUID().uuidString)
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"status":"stopped","ended":"2026-10-08T09:00:00Z","started":"2026-10-08T08:00:00Z","files":{"mic":"mic.caf"}}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        return (root, dir)
    }
    func testModelDownloadRequeuesFailedMeetingWithoutRelaunch() async throws {
        let (root, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = RetrySpeechEngine(missingModel: true)
        let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"),
            clock: { 1000 }, localModelAvailable: { false }, audioDuration: { _ in 1 },
            saveArchive: { _ in throw URLError(.notConnectedToInternet) }, makeEngine: { _, _ in engine })
        let missing = expectation(description: "Missing model is durable")
        await coordinator.setStatusHandler { if case .needsReview = $0 { missing.fulfill() } }
        await coordinator.enqueue(dir, transcriptionEnabled: true)
        await fulfillment(of: [missing], timeout: 5)
        XCTAssertEqual(try MeetingPipelineState.load(dir).stage, .waitingForModel)
        let automatic = try await coordinator.retryPendingTranscriptions(root: root)
        XCTAssertEqual(automatic, 0)
        await engine.installModel()
        let ready = expectation(description: "Transcribed and delivery pending")
        ready.assertForOverFulfill = false
        await coordinator.setStatusHandler { if case .archivePending = $0 { ready.fulfill() } }
        let requeued = try await coordinator.retryPendingTranscriptions(root: root, modelInstalled: true)
        XCTAssertEqual(requeued, 1)
        await fulfillment(of: [ready], timeout: 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        let preparations = await engine.preparations
        XCTAssertEqual(preparations, 2)
    }
    func testTransientFailureRetriesAcrossRelaunchButStopsAtThree() async throws {
        let (root, dir) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let engine = RetrySpeechEngine(transient: true)
        for attempt in 1...3 {
            let time = Double(attempt * 1000)
            let coordinator = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"),
                clock: { time }, localModelAvailable: { false }, makeEngine: { _, _ in engine })
            let failed = expectation(description: "Durable failure \(attempt)")
            await coordinator.setStatusHandler { if case .needsReview = $0 { failed.fulfill() } }
            let queued = try await coordinator.retryPendingTranscriptions(root: root)
            XCTAssertEqual(queued, 1)
            await fulfillment(of: [failed], timeout: 5)
        }
        let final = TranscriptionCoordinator(activityLockPath: root.appendingPathComponent("lease"),
            clock: { 100_000 }, localModelAvailable: { false }, makeEngine: { _, _ in engine })
        let queued = try await final.retryPendingTranscriptions(root: root)
        XCTAssertEqual(queued, 0)
        let preparations = await engine.preparations
        XCTAssertEqual(preparations, 3)
        XCTAssertEqual(try MeetingPipelineState.load(dir).transcription.count, 3)
    }
}
