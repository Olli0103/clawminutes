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
        @Sendable func post(_ body: Data) async throws -> (Data, Int) {
            var request = URLRequest(url: origin.appendingPathComponent("plugins/teams-transcribe/ingest"))
            request.timeoutInterval = 20
            request.httpMethod = "POST"
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            return (data, try XCTUnwrap(response as? HTTPURLResponse).statusCode)
        }
        @Sendable func capabilities() async throws -> Data {
            let (data, response) = try await session.data(from: origin.appendingPathComponent("plugins/teams-transcribe/ingest"))
            let status = try XCTUnwrap(response as? HTTPURLResponse).statusCode
            guard status == 200 else { throw DeliveryFailure.response(status: status, data: data) }
            return data
        }
        let negotiated = try GatewayCapabilities.verify(await capabilities())
        XCTAssertEqual(negotiated.archive.verification, "isolated-readback-v1")
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
        var revisedMeta = meta
        let descriptor = MeetingRevisions.Descriptor(number: 2, baseRecordingId: "http-fixture",
            parentSessionId: try XCTUnwrap(saved["sessionId"] as? String), reason: "speaker_correction")
        revisedMeta["revision"] = descriptor.json
        transcript["segments"] = [["speaker": "system_unknown", "source": "system", "start_ms": 0, "end_ms": 1000,
            "text": "Synthetic speech.", "speaker_name": "Fixture Alice", "attribution": "manual"]]
        let revisionEnvelope = try GatewayArchive.envelope(meta: revisedMeta, transcript: transcript, recordingID: descriptor.recordingId)
        let (revisionData, revisionStatus) = try await post(revisionEnvelope)
        XCTAssertEqual(revisionStatus, 200)
        let revision = try XCTUnwrap(JSONSerialization.jsonObject(with: revisionData) as? [String: Any])
        XCTAssertNotEqual(revision["sessionId"] as? String, saved["sessionId"] as? String)
        XCTAssertTrue((revision["documents"] as? [String: Any])?["transcriptMarkdown"] as? String != nil)
        let (_, revisionRepeatStatus) = try await post(revisionEnvelope)
        XCTAssertEqual(revisionRepeatStatus, 200)
        let (originalAgain, originalAgainStatus) = try await post(envelope)
        XCTAssertEqual(originalAgainStatus, 200)
        XCTAssertEqual((try JSONSerialization.jsonObject(with: originalAgain) as? [String: Any])?["documents"] as? NSDictionary,
                       saved["documents"] as? NSDictionary)
        revisedMeta["revision"] = descriptor.json.merging(["audio": "/private/audio"], uniquingKeysWith: { _, new in new })
        XCTAssertThrowsError(try GatewayArchive.envelope(meta: revisedMeta, transcript: transcript, recordingID: descriptor.recordingId))
        let (invalid, invalidStatus) = try await post(Data(#"{"audio":"forbidden"}"#.utf8))
        XCTAssertEqual(invalidStatus, 422)
        XCTAssertEqual(DeliveryFailure.response(status: invalidStatus, data: invalid).code, "invalid_payload")
        let local = root.appendingPathComponent("local-recovery"), notesRoot = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
        var recoveryMeta = meta
        recoveryMeta["fixture"] = false; recoveryMeta["recording_id"] = "http-recovery"
        recoveryMeta["note_template"] = ["id": "fixture", "name": "Fixture", "context": "fixture-invalid-output", "sections": [["title": "Summary", "instructions": "Summarize"]]]
        try JSONSerialization.data(withJSONObject: recoveryMeta).write(to: local.appendingPathComponent("meta.json"))
        let originalTranscript = try JSONSerialization.data(withJSONObject: transcript)
        try originalTranscript.write(to: local.appendingPathComponent("transcript.json"))
        let lease = root.appendingPathComponent("lifecycle.lock")
        let delivery = MeetingDeliveryStage(activityLockPath: lease, saveArchive: { directory in
            try await GatewayArchive.save(directory, transport: { body in
                let (data, status) = try await post(body)
                guard status == 200 else { throw DeliveryFailure.response(status: status, data: data) }
                return data
            }, capabilityTransport: capabilities, exportRootOverride: notesRoot, activityLockPath: lease)
        }, onSaved: { _ in })
        if case .failed(let failure) = await delivery.deliver(local, now: 100) { XCTAssertEqual(failure.code, "ai_invalid_output") }
        else { XCTFail("Synthetic invalid AI output must fail") }
        XCTAssertEqual(ArchiveBacklog.inspect(local, notesRoot: notesRoot).retry?.completionAttempts, 1)
        _ = try NotesRecovery.prepare(local, kind: .retryAI, now: 200, activityLockPath: lease)
        if case .failed(let failure) = await delivery.deliver(local, now: 200) { XCTAssertEqual(failure.code, "ai_invalid_output") }
        else { XCTFail("Explicit retry must preserve the model failure") }
        XCTAssertEqual(ArchiveBacklog.inspect(local, notesRoot: notesRoot).retry?.completionAttempts, 2)
        _ = try NotesRecovery.prepare(local, kind: .transcriptOnly, now: 300, activityLockPath: lease)
        if case .saved = await delivery.deliver(local, now: 300) {} else { XCTFail("Transcript-only recovery must save") }
        let recovered = try ArchiveBacklog.object(local.appendingPathComponent("archive-receipt.json"))
        XCTAssertEqual((recovered["notes"] as? [String: Any])?["backend"] as? String, "transcript-only")
        XCTAssertEqual(ArchiveBacklog.inspect(local, notesRoot: notesRoot).state, .needsReview, "Capture gaps still require review after recovery")
        XCTAssertEqual(try ArchiveBacklog.read(local.appendingPathComponent("transcript.json")), originalTranscript)
        XCTAssertEqual(try ArchiveBacklog.object(local.appendingPathComponent("meta.json"))["notes_mode"] as? String, "ai")
        let regenerated = try MeetingRevisions.create(from: local, change: .template(NoteTemplate(id: "fixture", name: "Fixture", context: "Synthetic",
            sections: [.init(title: "Summary", instructions: "Summarize")])), activityLockPath: lease)
        if case .saved = await delivery.deliver(regenerated, now: 400) {} else { XCTFail("An explicit new version must regenerate notes after transcript-only recovery") }
        let newReceipt = try ArchiveBacklog.object(regenerated.appendingPathComponent("archive-receipt.json"))
        XCTAssertNotEqual(newReceipt["sessionId"] as? String, recovered["sessionId"] as? String)
        XCTAssertEqual((newReceipt["notes"] as? [String: Any])?["backend"] as? String, "gateway-model")
        XCTAssertEqual((try ArchiveBacklog.object(local.appendingPathComponent("archive-receipt.json"))["notes"] as? [String: Any])?["backend"] as? String, "transcript-only")
        try await GatewayArchive.save(regenerated, transport: { _ in XCTFail("Saved exports must not send speech again"); throw URLError(.notConnectedToInternet) },
            capabilityTransport: { XCTFail("Verified local exports must remain usable offline"); throw URLError(.notConnectedToInternet) },
            exportRootOverride: notesRoot, activityLockPath: lease)
        let (counts, _) = try await session.data(from: origin.appendingPathComponent("statistics"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: counts) as? [String: Int])?["completions"], 5)
    }
}
