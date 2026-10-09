import Foundation
import XCTest
@testable import quill

final class HelperDiagnosticsTests: XCTestCase {
    func testReportExcludesPrivateContentAndDoesNotChangeMeetingOrSettings() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("2026.10.08-1000-PRIVATE-MEETING-TITLE")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("config.json")
        let data = Data(#"{"gateway":{"url":"https://private-gateway.example","token":"PRIVATE-CREDENTIAL"},"local_speaker_name":"PRIVATE-PERSON"}"#.utf8)
        try data.write(to: settings)
        try Data(#"{"started":"2026-10-08T10:00:00Z","ended":"2026-10-08T11:00:00Z","status":"stopped","recording_id":"PRIVATE-ID","meeting_context":{"title":"PRIVATE-TITLE"}}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        var state = try MeetingPipelineState.load(dir)
        state.schemaVersion = 1 // Legacy fixture; the report imports without publishing a new generation.
        state.transcription.lastError = DeliveryFailure(code: "private_code", detail: "PRIVATE-PROVIDER-DETAIL", retryable: false, completionAttempted: false)
        // Write directly so the read-only report has no event-producing setup side effect.
        let original = try JSONEncoder().encode(state)
        try original.write(to: dir.appendingPathComponent("state.json"))
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let report = try HelperDiagnostics.report(root: root, settings: settings,
            permissions: .init(accessibility: false, microphone: false, systemAudio: false), localModelAvailable: false)
        let rendered = String(decoding: try HelperDiagnostics.data(report), as: UTF8.self)
        for privateValue in ["PRIVATE", "private-gateway", root.path] { XCTAssertFalse(rendered.contains(privateValue)) }
        XCTAssertEqual(report.meetings.count, 1)
        XCTAssertEqual(report.meetings[0].errorCode, "unclassified_error")
        XCTAssertEqual(report.meetings[0].recordingRef.count, 24)
        XCTAssertTrue(report.configurationReadable)
        XCTAssertTrue(report.lockOwnership.hasPrefix("needs_evidence"))
        XCTAssertEqual(try Data(contentsOf: settings), data)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("state.json")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.lock").path))
        let output = root.appendingPathComponent("report.json")
        try HelperDiagnostics.write(report, to: output)
        XCTAssertThrowsError(try HelperDiagnostics.write(report, to: output))
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions] as? Int, 0o600)
    }

    func testLinkedMeetingsAndMalformedStateAreNotTrusted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked"), withDestinationURL: root)
        let dir = root.appendingPathComponent("malformed")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
        try Data(#"{"started":"2026-10-08T10:00:00Z","status":"stopped"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try Data("PRIVATE malformed state".utf8).write(to: dir.appendingPathComponent("state.json"))
        let report = try HelperDiagnostics.report(root: root, settings: root.appendingPathComponent("missing"),
            permissions: .init(accessibility: false, microphone: false, systemAudio: false), localModelAvailable: false)
        XCTAssertEqual(report.meetings.count, 1)
        XCTAssertFalse(report.meetings[0].stateVerified)
        XCTAssertEqual(report.meetings[0].artifactState, .needsReview)
        XCTAssertFalse(String(decoding: try HelperDiagnostics.data(report), as: UTF8.self).contains("PRIVATE"))
    }

    func testEventsAreBoundedAndDoNotIncludeFreeFormErrorsOrIdentity() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = MeetingPipelineState(recordingIdentity: "PRIVATE-ID", stage: .needsAttention, updatedAt: 100)
        state.transcription.lastError = DeliveryFailure(code: "PRIVATE-CODE", detail: "PRIVATE-SPEECH", retryable: false, completionAttempted: false)
        XCTAssertTrue(PipelineEvents.record(state, at: root))
        let file = root.appendingPathComponent("events.jsonl")
        XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("PRIVATE"))
        XCTAssertEqual(PipelineEvents.recent(at: root).first?.errorCode, "unclassified_error")
        try Data(repeating: 0x20, count: PipelineEvents.maximumBytes).write(to: file)
        state.stage = .transcribing; state.transcription.lastError = nil
        XCTAssertTrue(PipelineEvents.record(state, at: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.previous.jsonl").path))
        XCTAssertEqual(PipelineEvents.recent(at: root).count, 1)
        XCTAssertLessThan(try Data(contentsOf: file).count, 4096)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int, 0o600)
    }

    func testEventSinkRefusesLinksAndNeverModifiesTheirTarget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("private-file")
        try Data("PRIVATE".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("events.jsonl"), withDestinationURL: target)
        let state = MeetingPipelineState(recordingIdentity: "id", stage: .recorded, updatedAt: 0)
        XCTAssertFalse(PipelineEvents.record(state, at: root))
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "PRIVATE")
        XCTAssertTrue(PipelineEvents.recent(at: root).isEmpty)
    }
    func testReportSeparatesLocalExportFailureFromPaidAttemptsAndKeepsStateReadOnly() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let meta: [String: Any] = ["status": "stopped", "recording_id": "meeting", "started": "2026-10-08T10:00:00Z", "ended": "2026-10-08T10:01:00Z", "notes_mode": "ai"]
        try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
        let transcript: [String: Any] = ["engine": "parakeet", "model": "fixture", "execution_machine": "fixture", "execution_location": "recording_mac", "segments": [["speaker": "unknown", "source": "system", "start_ms": 0, "end_ms": 1000, "text": "PRIVATE speech"]]]
        let data = try JSONSerialization.data(withJSONObject: transcript)
        try data.write(to: directory.appendingPathComponent("transcript.json"))
        let id = "teams-" + AudioRetention.digest(Data("2026-10-08T10:00:00Z\nmeeting".utf8)).prefix(24)
        let body = try GatewayArchive.envelope(meta: meta, transcript: transcript, recordingID: "meeting")
        let receipt: [String: Any] = ["saved": true, "sessionId": id, "utteranceCount": 1,
            "localTranscriptSHA256": AudioRetention.digest(data), "localEnvelopeSHA256": try GatewayArchive.envelopeFingerprint(body),
            "documents": ["title": "PRIVATE", "startedAt": "2026-10-08T10:00:00Z", "notesMarkdown": "PRIVATE notes", "transcriptMarkdown": "PRIVATE speech", "metadata": ["sessionId": id]]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent("archive-receipt.json"))
        _ = try MeetingDocuments.validateDocuments(receipt)
        XCTAssertEqual(ArchiveBacklog.inspect(directory).verifiedText, .archive)
        var state = try MeetingPipelineState.load(directory)
        state.generation = 1; state.stage = .needsAttention
        state.transcription.count = 1
        state.transcription.lastError = .init(code: "local_model_missing", detail: "PRIVATE stale speech failure", retryable: false, completionAttempted: false)
        state.delivery.count = 2; state.delivery.completionAttempts = 2
        state.delivery.transcriptSHA256 = AudioRetention.digest(data)
        state.delivery.lastError = .init(code: "ai_invalid_output", detail: "PRIVATE stale AI failure", retryable: false, completionAttempted: true)
        state.localExport = .init(count: 3, nextAttemptAt: 9999, lastError: .init(code: "local_export_retry_limit", detail: "PRIVATE path", retryable: false, completionAttempted: false), lastErrorAt: 500)
        let original = try JSONEncoder().encode(state)
        try original.write(to: directory.appendingPathComponent("state.json"))
        let before = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let report = try HelperDiagnostics.report(root: root, settings: root.appendingPathComponent("config.json"), permissions: .init(accessibility: false, microphone: false, systemAudio: false), localModelAvailable: false)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: HelperDiagnostics.data(report)) as? [String: Any])
        let meeting = try XCTUnwrap((object["meetings"] as? [[String: Any]])?.first)
        XCTAssertEqual(meeting["localExportAttempts"] as? Int, 3)
        XCTAssertEqual(meeting["completionAttempts"] as? Int, 2)
        XCTAssertEqual(meeting["deliveryAttempts"] as? Int, 2)
        XCTAssertEqual(meeting["errorCode"] as? String, "local_export_retry_limit")
        XCTAssertNil(meeting["transcriptionErrorCode"]); XCTAssertNil(meeting["deliveryErrorCode"])
        XCTAssertEqual(meeting["localExportErrorCode"] as? String, "local_export_retry_limit")
        XCTAssertFalse(String(decoding: try HelperDiagnostics.data(report), as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("state.json")), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("events.lock").path))
    }
    func testEventIncludesLocalExportCounterCauseAndUnknownPaidBudget() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var state = MeetingPipelineState(recordingIdentity: "PRIVATE", stage: .needsAttention, updatedAt: 100)
        state.localExport = .init(count: 3, lastError: .init(code: "local_export_retry_limit", detail: "PRIVATE path", retryable: false, completionAttempted: false))
        state.delivery.count = 8; state.delivery.budgetUnverified = true
        XCTAssertTrue(PipelineEvents.record(state, at: root))
        let line = try ArchiveBacklog.read(root.appendingPathComponent("events.jsonl"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line) as? [String: Any])
        XCTAssertEqual(object["localExportAttempts"] as? Int, 3)
        XCTAssertEqual(object["localExportErrorCode"] as? String, "local_export_retry_limit")
        XCTAssertEqual(object["paidBudgetUnverified"] as? Bool, true)
        XCTAssertNil(object["completionAttempts"])
        XCTAssertFalse(String(decoding: line, as: UTF8.self).contains("PRIVATE"))
        XCTAssertEqual(PipelineEvents.recent(at: root).count, 1)
    }

    func testEventReaderKeepsLegacyEventsAndRejectsMalformedNewFields() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy: [String: Any] = ["schemaVersion": 1, "time": 1, "recordingRef": String(repeating: "a", count: 24), "stage": "recorded", "transcriptionAttempts": 1, "deliveryAttempts": 2, "errorCode": "unclassified_error"]
        var lines = [legacy]
        var current = legacy; current["schemaVersion"] = 2; current["time"] = 2
        current["localExportAttempts"] = 3; current["localExportErrorCode"] = "local_export_retry_limit"; current["completionAttempts"] = 2
        lines.append(current)
        for (field, bad) in [("localExportAttempts", -1 as Any), ("completionAttempts", 4 as Any), ("localExportErrorCode", "PRIVATE provider text" as Any), ("paidBudgetUnverified", "PRIVATE" as Any)] {
            var invalid = current; invalid[field] = bad; lines.append(invalid)
        }
        let data = try lines.reduce(into: Data()) { result, line in result.append(try JSONSerialization.data(withJSONObject: line)); result.append(0x0a) }
        try data.write(to: root.appendingPathComponent("events.jsonl"))
        let events = PipelineEvents.recent(at: root)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.first?.schemaVersion, 1); XCTAssertNil(events.first?.localExportAttempts)
        XCTAssertEqual(events.last?.localExportAttempts, 3)
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(events), as: UTF8.self).contains("PRIVATE"))
    }

}
