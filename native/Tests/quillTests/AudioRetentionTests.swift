import XCTest
import AVFoundation
@testable import quill

final class AudioRetentionTests: XCTestCase {
    private func fixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["status": "stopped", "audio_started_at": 1790935200.0,
                                  "ended": "2026-10-02T10:01:00Z", "start_offset_ms": ["mic": 0, "system": 0]]
        try put(meta, "meta.json", dir)
        let transcript: [String: Any] = ["engine": "parakeet", "model": "fixture", "created_at": "2026-10-02T10:01:01Z",
                                        "segments": [["speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "Fixture words"]]]
        try put(transcript, "transcript.json", dir)
        try Data("Fixture words".utf8).write(to: dir.appendingPathComponent("transcript.md"))
        let folder = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Saved notes".utf8).write(to: folder.appendingPathComponent("notes.md"))
        try Data("Saved transcript".utf8).write(to: folder.appendingPathComponent("transcript.md"))
        let id = "teams-" + String(repeating: "a", count: 24)
        try put(["sessionId": id], "metadata.json", folder)
        try Data(folder.path.utf8).write(to: dir.appendingPathComponent("notes-export-path.txt"))
        let receipt: [String: Any] = ["saved": true, "sessionId": id, "utteranceCount": 1,
                                     "localTranscriptSHA256": AudioRetention.digest(try Data(contentsOf: dir.appendingPathComponent("transcript.json"))),
                                     "documents": ["notesMarkdown": "Saved notes", "transcriptMarkdown": "Saved transcript", "metadata": ["sessionId": id]]]
        try put(receipt, "archive-receipt.json", dir)
        for name in ["mic.caf", "system.caf"] { try Data([1, 2, 3]).write(to: dir.appendingPathComponent(name)) }
        return dir
    }
    private func put(_ value: [String: Any], _ name: String, _ dir: URL) throws {
        try JSONSerialization.data(withJSONObject: value).write(to: dir.appendingPathComponent(name))
    }
    private func change(_ dir: URL, file: String, key: String, value: Any) throws {
        let url = dir.appendingPathComponent(file)
        var data = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        data[key] = value
        try put(data, file, dir)
    }
    private func assertKept(_ dir: URL) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
    }
    func testVerifiedDeletionKeepsTextAndIsIdempotent() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let text = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        XCTAssertEqual(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }), 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("transcript.json")), text)
        XCTAssertEqual(try AudioRetention.deleteAfterVerification(dir, measure: { _ in XCTFail("Already removed"); return 0 }), 0)
    }
    func testActiveRecordingIsNeverDeleted() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try change(dir, file: "meta.json", key: "status", value: "recording")
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 })); assertKept(dir)
    }
    func testFailedArchiveAndMismatchedTranscriptKeepAudio() throws {
        for pair in [("saved", false as Any), ("localTranscriptSHA256", "different" as Any), ("utteranceCount", 3 as Any)] {
            let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            try change(dir, file: "archive-receipt.json", key: pair.0, value: pair.1)
            XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 })); assertKept(dir)
        }
    }
    func testIncompleteCoverageKeepsBothTracks() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { $0.lastPathComponent == "mic.caf" ? 1 : 60 })); assertKept(dir)
    }
    func testUnreadableAudioKeepsBothTracks() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir)); assertKept(dir)
    }
    func testEditedExportKeepsAudio() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try Data("Edited notes".utf8).write(to: dir.appendingPathComponent("notes/notes.md"))
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 })); assertKept(dir)
    }
    func testInvalidTimestampKeepsAudio() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try change(dir, file: "transcript.json", key: "segments", value: [["speaker": "me", "start_ms": -1, "end_ms": 1000, "text": "Fixture"]])
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 })); assertKept(dir)
    }
    func testLinkedAudioCannotDeleteTarget() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("mic.caf"), target = dir.appendingPathComponent("outside.caf")
        try FileManager.default.moveItem(at: audio, to: target)
        try FileManager.default.createSymbolicLink(at: audio, withDestinationURL: target)
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path)); assertKept(dir)
    }
    func testStaleMeetingContextKeepsAudio() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try change(dir, file: "meta.json", key: "meeting_context", value: ["ended_observed_at": 1790935000.0])
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 })); assertKept(dir)
    }
    func testProductionAudioProbeAcceptsMatchingPCMTracks() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        for name in ["mic.caf", "system.caf"] {
            let url = dir.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_440_000)!
            buffer.frameLength = 1_440_000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 1_440_000)
            try file.write(from: buffer)
        }
        XCTAssertEqual(try AudioRetention.deleteAfterVerification(dir), 2)
    }
}
