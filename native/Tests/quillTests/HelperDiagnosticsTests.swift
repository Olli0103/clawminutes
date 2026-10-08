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
}
