import Foundation
import XCTest
@testable import quill

final class GatewayHTTPContractTests: XCTestCase, @unchecked Sendable {
    func testSwiftEnvelopeAgainstRealJSHandlerAndSDKPreservesSavedNotes() async throws {
        var repository = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { repository.deleteLastPathComponent() }
        guard FileManager.default.fileExists(atPath: repository.appendingPathComponent("node_modules/openclaw/package.json").path) else {
            throw XCTSkip("Install the pinned OpenClaw development SDK for the Swift-to-JavaScript HTTP contract test")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-http-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", repository.appendingPathComponent("test/http-contract-server.mjs").path, root.path]
        process.currentDirectoryURL = repository
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        var data = Data()
        while data.count < 8 {
            guard let byte = try output.fileHandleForReading.read(upToCount: 1), !byte.isEmpty else { break }
            data.append(byte)
            if byte == Data([10]) { break }
        }
        let port = try XCTUnwrap(Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        let origin = URL(string: "http://127.0.0.1:\(port)")!
        let session = URLSession(configuration: .ephemeral, delegate: NoGatewayRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        func post(_ body: Data) async throws -> (Data, Int) {
            var request = URLRequest(url: origin.appendingPathComponent("plugins/teams-transcribe/ingest"))
            request.timeoutInterval = 20
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
        }
        let meta: [String: Any] = ["started": "2026-10-08T08:00:00Z", "ended": "2026-10-08T08:01:00Z", "audio_started_at": 1791446400.0,
            "status": "stopped", "fixture": true, "notes_mode": "ai", "files": ["mic": "/forbidden/audio"],
            "note_template": ["id": "fixture", "name": "Fixture", "context": "Synthetic", "sections": [["title": "Summary", "instructions": "Summarize"]]]]
        var transcript: [String: Any] = ["engine": "parakeet", "model": "parakeet-tdt-0.6b-v3-coreml", "created_at": "2026-10-08T08:02:00Z",
            "execution_machine": "fixture-mac", "execution_location": "recording_mac",
            "segments": [["speaker": "system_unknown", "source": "system", "start_ms": 0, "end_ms": 1000, "text": "Synthetic speech."]],
            "capture_gaps": [["source": "mic", "start_ms": 1000, "end_ms": 1000, "reason": "helper_interrupted"]]]
        let envelope = try GatewayArchive.envelope(meta: meta, transcript: transcript, recordingID: "http-fixture")
        XCTAssertFalse(String(decoding: envelope, as: UTF8.self).contains("/forbidden/audio"))
        let (first, firstStatus) = try await post(envelope)
        XCTAssertEqual(firstStatus, 200)
        let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: first) as? [String: Any])
        XCTAssertEqual(saved["saved"] as? Bool, true)
        let (repeatData, repeatStatus) = try await post(envelope)
        XCTAssertEqual(repeatStatus, 200)
        let repeated = try XCTUnwrap(JSONSerialization.jsonObject(with: repeatData) as? [String: Any])
        XCTAssertEqual((saved["documents"] as? NSDictionary), (repeated["documents"] as? NSDictionary))
        transcript["segments"] = [["speaker": "system_unknown", "source": "system", "start_ms": 0, "end_ms": 1000, "text": "Synthetic speech."],
                                  ["speaker": "system_unknown", "source": "system", "start_ms": 2000, "end_ms": 3000, "text": "Additional speech."]]
        let (conflict, conflictStatus) = try await post(GatewayArchive.envelope(meta: meta, transcript: transcript, recordingID: "http-fixture"))
        XCTAssertEqual(conflictStatus, 409)
        let failure = DeliveryFailure.response(status: conflictStatus, data: conflict)
        XCTAssertEqual(failure.code, "revision_conflict")
        XCTAssertFalse(failure.retryable)
        XCTAssertFalse(failure.completionAttempted)
        let (invalid, invalidStatus) = try await post(Data(#"{"audio":"forbidden"}"#.utf8))
        XCTAssertEqual(invalidStatus, 422)
        XCTAssertEqual(DeliveryFailure.response(status: invalidStatus, data: invalid).code, "invalid_payload")
        let (counts, _) = try await session.data(from: origin.appendingPathComponent("statistics"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: counts) as? [String: Int])?["completions"], 1)
    }
}
