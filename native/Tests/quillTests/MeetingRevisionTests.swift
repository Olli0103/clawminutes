import Foundation
import AVFoundation
import XCTest
@testable import quill

final class MeetingRevisionTests: XCTestCase {
    private func source(_ root: URL) throws -> URL {
        let directory = root.appendingPathComponent("2026.10.08-1200_Weekly-sync")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta: [String: Any] = ["started": "2026-10-08T10:00:00Z", "ended": "2026-10-08T10:01:00Z", "status": "stopped", "audio_started_at": 1791453600, "recording_id": "version-fixture", "files": ["system": "system.caf"], "meeting_context": ["title": "Weekly sync"]]
        try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
        try Data("PRIVATE AUDIO".utf8).write(to: directory.appendingPathComponent("system.caf"))
        let transcript = Transcript(engine: "parakeet", model: "parakeet-tdt-0.6b-v3-coreml", created_at: "2026-10-08T10:02:00Z", segments: [
            .init(speaker: "system_unknown", start_ms: 0, end_ms: 1000, text: "First speaker", source: "system"),
            .init(speaker: "system_unknown", start_ms: 1000, end_ms: 2000, text: "Another speaker", source: "system")])
        try transcript.write(to: directory)
        try receipt(directory)
        return directory
    }
    private func receipt(_ directory: URL) throws {
        let meta = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
        let transcript = try ArchiveBacklog.read(directory.appendingPathComponent("transcript.json"))
        let started = meta["started"] as! String, id = meta["recording_id"] as! String
        try JSONSerialization.data(withJSONObject: ["saved": true, "sessionId": MeetingRevisions.Descriptor.archiveIdentity(started: started, recordingId: id), "utteranceCount": 2,
            "documents": ["fixture": true], "localTranscriptSHA256": AudioRetention.digest(transcript)])
            .write(to: directory.appendingPathComponent("archive-receipt.json"))
    }
    func testSpeakerRevisionPreservesOriginalAndOnlyChangesSelectedTurnsWithoutCopyingAudio() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try source(root)
        let bytes = try ArchiveBacklog.read(original.appendingPathComponent("transcript.json"))
        let meta = try ArchiveBacklog.read(original.appendingPathComponent("meta.json"))
        let output = try MeetingRevisions.create(from: original, change: .speaker(indices: [0], name: "Fixture Alice"), activityLockPath: root.appendingPathComponent("lifecycle.lock"))
        XCTAssertTrue(output.lastPathComponent.contains("Weekly-sync_v2"))
        let corrected = try JSONDecoder().decode(Transcript.self, from: ArchiveBacklog.read(output.appendingPathComponent("transcript.json")))
        XCTAssertEqual(corrected.segments[0].speaker_name, "Fixture Alice")
        XCTAssertEqual(corrected.segments[0].attribution, "manual")
        XCTAssertNil(corrected.segments[1].speaker_name)
        XCTAssertEqual(try ArchiveBacklog.read(original.appendingPathComponent("transcript.json")), bytes)
        XCTAssertEqual(try ArchiveBacklog.read(original.appendingPathComponent("meta.json")), meta)
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("system.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("archive-receipt.json").path))
        let markdown = String(decoding: try ArchiveBacklog.read(output.appendingPathComponent("transcript.md")), as: UTF8.self)
        XCTAssertTrue(markdown.hasPrefix("# Weekly-sync · v2"))
        XCTAssertFalse(markdown.contains("revision-staging"))
        XCTAssertEqual(try MeetingPipelineState.load(output).revision, 2)
        XCTAssertEqual(ArchiveBacklog.inspect(output).state, .archivePending)
        XCTAssertThrowsError(try MeetingRevisions.create(from: original, change: .speaker(indices: [1], name: "Other"), activityLockPath: root.appendingPathComponent("lifecycle.lock")))
        try receipt(output)
        let third = try MeetingRevisions.create(from: output, change: .template(NoteTemplate.defaults[1]), activityLockPath: root.appendingPathComponent("lifecycle.lock"))
        XCTAssertEqual(try MeetingPipelineState.load(third).revision, 3)
        let thirdMeta = try ArchiveBacklog.object(third.appendingPathComponent("meta.json"))
        XCTAssertEqual(thirdMeta["notes_mode"] as? String, "ai")
        XCTAssertEqual((thirdMeta["note_template"] as? [String: Any])?["id"] as? String, "one-to-one")
        let descriptor = try XCTUnwrap(MeetingRevisions.descriptor(meta: thirdMeta, directory: third))
        XCTAssertEqual(descriptor.parentSessionId, try ArchiveBacklog.object(output.appendingPathComponent("archive-receipt.json"))["sessionId"] as? String)
    }
    func testUnsavedOrChangedSourceCannotCreateAVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try source(root)
        try Data("changed".utf8).write(to: original.appendingPathComponent("transcript.json"))
        XCTAssertThrowsError(try MeetingRevisions.create(from: original, change: .template(NoteTemplate.defaults[0]), activityLockPath: root.appendingPathComponent("lifecycle.lock")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".revision-staging").path))
    }
    func testPreviewResolvesOriginalAudioForVersionsAndRefusesLinkedTracks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try source(root), track = original.appendingPathComponent("system.caf")
        try FileManager.default.removeItem(at: track)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160000)); buffer.frameLength = 160000
        do { let file = try AVAudioFile(forWriting: track, settings: format.settings); try file.write(from: buffer) }
        let child = try MeetingRevisions.create(from: original, change: .speaker(indices: [0], name: "Alice"), activityLockPath: root.appendingPathComponent("lifecycle.lock"))
        let segment = Transcript.Segment(speaker: "system_unknown", start_ms: 1000, end_ms: 2000, text: "Fixture", source: "system")
        let clip = try XCTUnwrap(MeetingAudioPreview.clip(directory: child, segment: segment))
        XCTAssertEqual(clip.file.resolvingSymlinksInPath(), track.resolvingSymlinksInPath()); XCTAssertEqual(clip.start, 1); XCTAssertEqual(clip.duration, 8)
        let outside = root.appendingPathComponent("outside.caf")
        try FileManager.default.moveItem(at: track, to: outside)
        try FileManager.default.createSymbolicLink(at: track, withDestinationURL: outside)
        XCTAssertNil(try MeetingAudioPreview.clip(directory: child, segment: segment))
    }
    func testRevisionCommandRequiresExactModeAndDescriptorRejectsExtraFields() throws {
        let command = try ReviseMeeting.parse(["/unused", "--turns", "0", "--name", "Alice", "--template", "meeting"])
        XCTAssertThrowsError(try command.run())
        let descriptor = MeetingRevisions.Descriptor(number: 2, baseRecordingId: "fixture", parentSessionId: MeetingRevisions.Descriptor.archiveIdentity(started: "2026-10-08T10:00:00Z", recordingId: "fixture"), reason: "speaker_correction")
        let metadata: [String: Any] = ["started": "2026-10-08T10:00:00Z", "recording_id": descriptor.recordingId,
            "revision": descriptor.json.merging(["audio": "private"], uniquingKeysWith: { _, value in value })]
        XCTAssertThrowsError(try MeetingRevisions.descriptor(meta: metadata, directory: URL(fileURLWithPath: "/unused")))
    }
    func testReplacementTranscriptCreatesNewVersionAndStateCannotClaimAnotherVersion() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = try source(root)
        let originalBytes = try ArchiveBacklog.read(original.appendingPathComponent("transcript.json"))
        var replacement = try JSONDecoder().decode(Transcript.self, from: originalBytes)
        replacement.segments[0].text = "Re-transcribed speech"
        let output = try MeetingRevisions.create(from: original, change: .retranscribed(replacement), activityLockPath: root.appendingPathComponent("lifecycle.lock"))
        let changed = try JSONDecoder().decode(Transcript.self, from: ArchiveBacklog.read(output.appendingPathComponent("transcript.json")))
        XCTAssertEqual(changed.segments[0].text, "Re-transcribed speech")
        XCTAssertEqual(try ArchiveBacklog.read(original.appendingPathComponent("transcript.json")), originalBytes)
        var state = try MeetingPipelineState.load(output); state.revision = 1
        XCTAssertThrowsError(try state.write(output))
        XCTAssertEqual(try MeetingPipelineState.load(output).revision, 2)
    }
}
