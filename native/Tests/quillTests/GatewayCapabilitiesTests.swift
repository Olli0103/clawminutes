import Foundation
import XCTest
@testable import quill

final class GatewayCapabilitiesTests: XCTestCase, @unchecked Sendable {
    private func status() -> [String: Any] {
        ["plugin": "teams-transcribe", "protocolVersion": 1, "rawAudioAccepted": false,
         "gatewayMachine": "fixture-gateway", "notesModelConfigured": "fixture/model",
         "archive": ["adapterVersion": 1, "sdkVersion": "2026.9.7", "verification": "isolated-readback-v1"],
         "capabilities": ["textEnvelope": 1, "structuredErrors": 1, "idempotentCompletedSave": true,
                          "cappedNotesAttempts": 3, "revisions": 1, "notesRecovery": 1]]
    }
    private func data(_ value: [String: Any]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    func testCapabilitiesRejectLegacyUnsafeAndUnverifiedContracts() throws {
        XCTAssertEqual(try GatewayCapabilities.verify(data(status())).archive.sdkVersion, "2026.9.7")
        for (key, replacement) in [("protocolVersion", 2 as Any), ("rawAudioAccepted", true), ("plugin", "other"),
                                    ("archive", ["adapterVersion": 1, "sdkVersion": "2026.9.9", "verification": "isolated-readback-v1"]),
                                    ("gatewayMachine", "private\nheader"), ("capabilities", ["textEnvelope": 1])] {
            var value = status(); value[key] = replacement
            XCTAssertThrowsError(try GatewayCapabilities.verify(data(value))) { error in
                let issue = DeliveryFailure.classify(error)
                XCTAssertEqual(issue.code, "plugin_update_needed"); XCTAssertFalse(issue.retryable); XCTAssertFalse(issue.completionAttempted)
            }
        }
        var legacy = status(); legacy.removeValue(forKey: "protocolVersion")
        XCTAssertThrowsError(try GatewayCapabilities.verify(data(legacy)))
        XCTAssertThrowsError(try GatewayCapabilities.verify(Data(repeating: 32, count: 16_385)))
    }
    private func session(_ root: URL) throws -> URL {
        let directory = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data(["recording_id": "capabilities-fixture", "status": "stopped", "started": "2026-10-08T10:00:00Z",
                  "audio_started_at": 1791453600, "ended": "2026-10-08T10:01:00Z", "notes_mode": "ai"])
            .write(to: directory.appendingPathComponent("meta.json"))
        try Transcript(engine: "parakeet", model: "parakeet-tdt-0.6b-v3-coreml", created_at: "2026-10-08T10:02:00Z", segments: [
            .init(speaker: "system_unknown", start_ms: 0, end_ms: 1000, text: "Synthetic speech", source: "system")
        ]).write(to: directory)
        return directory
    }
    private actor Counter {
        var calls = 0
        func hit() { calls += 1 }
    }
    func testIncompatiblePreflightNeverTransmitsSpeechOrWritesReceipt() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try session(root)
        let transcript = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        let sent = Counter()
        do {
            try await GatewayArchive.save(directory, transport: { _ in await sent.hit(); return Data() },
                capabilityTransport: { Data(#"{"plugin":"teams-transcribe","rawAudioAccepted":false}"#.utf8) },
                exportRootOverride: root.appendingPathComponent("notes"), activityLockPath: root.appendingPathComponent("lease"))
            XCTFail("Legacy status cannot permit transmission")
        } catch { XCTAssertEqual(DeliveryFailure.classify(error).code, "plugin_update_needed") }
        let count = await sent.calls
        XCTAssertEqual(count, 0)
        XCTAssertEqual(try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json")), transcript)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("archive-receipt.json").path))
    }
    func testVerifiedCompatibilityRearmsOnlyMatchingFailureWithoutResettingBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = try session(root), file = directory.appendingPathComponent("archive-retry.json")
        let transcript = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        let retry = ArchiveBacklog.Retry(attempts: 4, nextAttemptAt: 1000, transcriptSHA256: AudioRetention.digest(transcript),
            completionAttempts: 1, lastError: GatewayCapabilities.unsupported)
        try JSONEncoder().encode(retry).write(to: file)
        let before = try ArchiveBacklog.read(file)
        try ArchiveBacklog.rearmConnection(ArchiveBacklog.inspect(directory), now: 2000)
        XCTAssertEqual(try ArchiveBacklog.read(file), before, "A generic Retry cannot bypass compatibility review")
        let proof = try GatewayCapabilities.verify(data(status()))
        try ArchiveBacklog.rearmConnection(ArchiveBacklog.inspect(directory), now: 2000, capabilities: proof)
        let ready = try JSONDecoder().decode(ArchiveBacklog.Retry.self, from: ArchiveBacklog.read(file))
        XCTAssertNil(ready.lastError); XCTAssertEqual(ready.attempts, 4); XCTAssertEqual(ready.completionAttempts, 1)
        XCTAssertTrue(ArchiveBacklog.inspect(directory).pending)
        var invalidOutput = retry
        invalidOutput.lastError = DeliveryFailure(code: "ai_invalid_output", detail: "Synthetic", retryable: false, completionAttempted: true)
        try JSONEncoder().encode(invalidOutput).write(to: file)
        let blocked = try ArchiveBacklog.read(file)
        try ArchiveBacklog.rearmConnection(ArchiveBacklog.inspect(directory), now: 3000, capabilities: proof)
        XCTAssertEqual(try ArchiveBacklog.read(file), blocked, "A verified connection cannot grant an AI retry")
    }
}
