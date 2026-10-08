import XCTest
import AppKit
import SwiftUI
import AVFoundation
@testable import quill

final class AudioRetentionTests: XCTestCase {
    private func fixture(ended: String = "2026-10-02T10:01:00Z") throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["status": "stopped", "started": "2026-10-02T10:00:00Z", "audio_started_at": 1790935200.0,
                                  "ended": ended, "start_offset_ms": ["mic": 0, "system": 0]]
        try put(meta, "meta.json", dir)
        let transcript: [String: Any] = ["engine": "parakeet", "model": "fixture", "created_at": "2026-10-02T10:01:01Z",
                                        "segments": [["speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "Fixture words"],
                                                     ["speaker": "them", "source": "system", "start_ms": 1000, "end_ms": 2000, "text": "Remote fixture words"]]]
        try put(transcript, "transcript.json", dir)
        try Data("Fixture words".utf8).write(to: dir.appendingPathComponent("transcript.md"))
        let folder = dir.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("Saved notes".utf8).write(to: folder.appendingPathComponent("notes.md"))
        try Data("Saved transcript".utf8).write(to: folder.appendingPathComponent("transcript.md"))
        let id = "teams-" + AudioRetention.digest(Data(("2026-10-02T10:00:00Z\n" + dir.lastPathComponent).utf8)).prefix(24)
        try put(["sessionId": id], "metadata.json", folder)
        try Data(folder.path.utf8).write(to: dir.appendingPathComponent("notes-export-path.txt"))
        let receipt: [String: Any] = ["saved": true, "sessionId": id, "utteranceCount": 2,
                                     "localTranscriptSHA256": AudioRetention.digest(try Data(contentsOf: dir.appendingPathComponent("transcript.json"))),
                                     "localEnvelopeSHA256": try GatewayArchive.sourceFingerprint(dir, meta: meta, transcriptData: Data(contentsOf: dir.appendingPathComponent("transcript.json"))),
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
    func testFractionalISOEndClockPassesTheSameVerification() throws {
        let dir = try fixture(ended: "2026-10-02T10:01:00.000Z"); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertEqual(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }), 2)
    }
    func testUnverifiedBoundaryWordsKeepAudioDespiteMatchingSavedTextProof() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try change(dir, file: "transcript.json", key: "capture_gaps", value: [
            ["source": "mic", "start_ms": 29000, "end_ms": 31000, "reason": "boundary_context_unverified"]])
        let transcript = try Data(contentsOf: dir.appendingPathComponent("transcript.json"))
        var receipt = try ArchiveBacklog.object(dir.appendingPathComponent("archive-receipt.json"))
        receipt["localTranscriptSHA256"] = AudioRetention.digest(transcript)
        receipt["localEnvelopeSHA256"] = try GatewayArchive.sourceFingerprint(dir,
            meta: ArchiveBacklog.object(dir.appendingPathComponent("meta.json")), transcriptData: transcript)
        try put(receipt, "archive-receipt.json", dir)
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 })) { error in
            XCTAssertTrue(String(describing: error).contains("file boundaries require review"))
        }
        assertKept(dir)
    }
    func testMissingSourceProofAndChangedMeetingDetailsKeepAudio() throws {
        for legacy in [false, true] {
            let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            if legacy {
                var receipt = try ArchiveBacklog.object(dir.appendingPathComponent("archive-receipt.json"))
                receipt.removeValue(forKey: "localEnvelopeSHA256")
                try put(receipt, "archive-receipt.json", dir)
            } else {
                try change(dir, file: "meta.json", key: "meeting_context", value: ["title": "Changed after saving"])
            }
            XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 })) {
                XCTAssertTrue(String(describing: $0).contains("Matching Gateway readback missing"))
            }
            assertKept(dir)
        }
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
    func testKnownCaptureGapKeepsAudioEvenWhenDurationsAndReceiptsLookComplete() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try change(dir, file: "meta.json", key: "capture_gaps", value: [["source": "mic", "start_ms": 10000, "end_ms": 20000, "reason": "buffers_stalled"]])
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }))
        assertKept(dir)
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
        var command = try VerifyAudioRetention.parse(["--directory", dir.path])
        XCTAssertFalse(command.delete)
        try command.run()
        assertKept(dir)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio-retention-receipt.json").path))
        XCTAssertEqual(try AudioRetention.deleteAfterVerification(dir), 2)
    }
}


extension AudioRetentionTests {
    func testNoTeamsSpeechKeepsAudioEvenWithMatchingNotesAndDurations() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try change(dir, file: "transcript.json", key: "segments", value: [["speaker": "me", "start_ms": 0, "end_ms": 1000, "text": "Only my microphone"]])
        try change(dir, file: "archive-receipt.json", key: "utteranceCount", value: 1)
        try change(dir, file: "archive-receipt.json", key: "localTranscriptSHA256", value: AudioRetention.digest(Data(contentsOf: dir.appendingPathComponent("transcript.json"))))
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }))
        assertKept(dir)
    }
}

extension AudioRetentionTests {
    func testReadOnlyReviewCreatesNoReceiptAndRetainsAllSourceFiles() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let before = try NotesFolderSnapshot.capture(dir)
        let plan = try XCTUnwrap(AudioRetention.review(dir, measure: { _ in 60 }))
        XCTAssertEqual(plan.remaining.count, 2); XCTAssertEqual(plan.bytes, 6)
        XCTAssertEqual(try NotesFolderSnapshot.capture(dir), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio-retention-receipt.json").path))
    }
    func testReviewedDeletionRejectsChangedTextReceiptAndAudio() throws {
        for file in ["transcript.md", "archive-receipt.json", "system.caf"] {
            let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            let plan = try XCTUnwrap(AudioRetention.review(dir, measure: { _ in 60 }))
            let target = dir.appendingPathComponent(file)
            if file == "archive-receipt.json" { try change(dir, file: file, key: "extra", value: "changed") }
            else { try Data("changed".utf8).write(to: target) }
            XCTAssertThrowsError(try AudioCleanup.execute(plan, activityLockPath: dir.appendingPathComponent("lifecycle.lock"), measure: { _ in 60 }))
            assertKept(dir)
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("audio-retention-receipt.json").path))
        }
    }
    func testInterruptedCleanupResumesOnlyAfterFreshRemainingTrackVerification() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        enum Interruption: Error { case simulated }
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }, policy: .explicitExisting, remove: { file in
            if file.lastPathComponent == "system.caf" { throw Interruption.simulated }
            try FileManager.default.removeItem(at: file)
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        XCTAssertFalse(AudioRetention.explicitlyRemoved(dir))
        let plan = try XCTUnwrap(AudioRetention.review(dir, measure: { file in
            XCTAssertEqual(file.lastPathComponent, "system.caf"); return 60
        }))
        XCTAssertEqual(plan.missing, ["mic.caf"]); XCTAssertEqual(plan.remaining.count, 1)
        XCTAssertEqual(try AudioCleanup.execute(plan, activityLockPath: dir.appendingPathComponent("lifecycle.lock"), measure: { _ in 60 }), 1)
        XCTAssertTrue(AudioRetention.explicitlyRemoved(dir))
        let audit = try JSONDecoder().decode(AudioRetention.Audit.self, from: ArchiveBacklog.read(dir.appendingPathComponent("audio-retention-receipt.json")))
        XCTAssertEqual(audit.policy, .explicitExisting); XCTAssertTrue(audit.deleted)
        XCTAssertEqual(Set(audit.removed), Set(["mic.caf", "system.caf"]))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes/notes.md").path))
    }
    func testUnlinkBeforeProgressWriteCanResumeFromPreparedAudit() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        enum Interruption: Error { case simulated }
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }, remove: { file in
            try FileManager.default.removeItem(at: file)
            throw Interruption.simulated
        }))
        let audit = try JSONDecoder().decode(AudioRetention.Audit.self, from: ArchiveBacklog.read(dir.appendingPathComponent("audio-retention-receipt.json")))
        XCTAssertEqual(audit.removed, []); XCTAssertFalse(audit.deleted)
        XCTAssertEqual(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }), 1)
        XCTAssertTrue(AudioRetention.explicitlyRemoved(dir))
    }
    func testPartialCleanupRejectsChangedSurvivingTrackOrProof() throws {
        for file in ["system.caf", "transcript.md"] {
            let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
            enum Interruption: Error { case simulated }
            XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }, remove: { file in
                if file.lastPathComponent == "system.caf" { throw Interruption.simulated }
                try FileManager.default.removeItem(at: file)
            }))
            try Data("changed".utf8).write(to: dir.appendingPathComponent(file))
            XCTAssertThrowsError(try AudioRetention.review(dir, measure: { _ in 60 }))
            XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }))
            XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        }
    }
    func testMissingTrackWithoutPreparedAuditCannotAuthorizeRemainingDeletion() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.removeItem(at: dir.appendingPathComponent("mic.caf"))
        XCTAssertThrowsError(try AudioRetention.review(dir, measure: { _ in 60 }))
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
    }
    func testCleanupRechecksAfterFirstUnlinkAndRetainsChangedRemainingTrack() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }, remove: { file in
            try FileManager.default.removeItem(at: file)
            try Data("replaced track".utf8).write(to: dir.appendingPathComponent("system.caf"))
        }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        XCTAssertFalse(AudioRetention.explicitlyRemoved(dir))
    }
    func testSaveLockAndInstallerLeaseBlockHistoricalCleanup() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try XCTUnwrap(AudioRetention.review(dir, measure: { _ in 60 }))
        do {
            let lock = try XCTUnwrap(AppRunLock.acquire(at: dir.appendingPathComponent("archive.lock")))
            try withExtendedLifetime(lock) {
                XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }))
            }
        }
        do {
            let lease = dir.appendingPathComponent("lifecycle.lock")
            let lock = try XCTUnwrap(AppRunLock.acquire(at: lease))
            try withExtendedLifetime(lock) {
                XCTAssertThrowsError(try AudioCleanup.execute(plan, activityLockPath: lease, measure: { _ in 60 }))
            }
        }
        assertKept(dir)
    }
    func testReviewListsBlockedMeetingsAlongsideEligibleOnes() throws {
        let eligible = try fixture(), gap = try fixture()
        defer { try? FileManager.default.removeItem(at: eligible); try? FileManager.default.removeItem(at: gap) }
        try change(gap, file: "meta.json", key: "capture_gaps", value: [["reason": "capture_failed"]])
        let meetings = [eligible, gap].map { directory in
            RecentMeeting(directory: directory, title: "Fixture meeting", started: nil, stage: .exported,
                issue: nil, detail: "", notes: directory.appendingPathComponent("notes/notes.md"), transcript: nil)
        }
        let rows = try AudioCleanup.review(meetings, measure: { _ in 60 })
        XCTAssertNotNil(rows[0].plan); XCTAssertNil(rows[0].issue)
        XCTAssertNil(rows[1].plan); XCTAssertTrue(rows[1].issue?.contains("gaps") == true)
        assertKept(eligible); assertKept(gap)
    }
    func testIncompleteOrFalseRemovalMarkerCannotProveRemoval() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        try put(["policy": "explicit_existing_audio_deletion", "files": ["mic.caf", "system.caf"], "deleted": true], "audio-retention-receipt.json", dir)
        XCTAssertFalse(AudioRetention.explicitlyRemoved(dir))
        try change(dir, file: "audio-retention-receipt.json", key: "deleted", value: false)
        try FileManager.default.removeItem(at: dir.appendingPathComponent("mic.caf"))
        try FileManager.default.removeItem(at: dir.appendingPathComponent("system.caf"))
        XCTAssertFalse(AudioRetention.explicitlyRemoved(dir))
        XCTAssertThrowsError(try AudioRetention.review(dir, measure: { _ in 60 }))
    }
}

extension AudioRetentionTests {
    @MainActor func testHistoricalAudioReviewRendersLightAndDarkWithoutDeletionOrVisibleWindow() async throws {
        let eligible = try fixture(), blocked = try fixture()
        defer { try? FileManager.default.removeItem(at: eligible); try? FileManager.default.removeItem(at: blocked) }
        let format = AVAudioFormat(standardFormatWithSampleRate: 24000, channels: 1)!
        for name in ["mic.caf", "system.caf"] {
            let url = eligible.appendingPathComponent(name)
            try FileManager.default.removeItem(at: url)
            let file = try AVAudioFile(forWriting: url, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_440_000)!
            buffer.frameLength = 1_440_000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 1_440_000)
            try file.write(from: buffer)
        }
        try change(blocked, file: "meta.json", key: "capture_gaps", value: [["reason": "capture_failed"]])
        let meetings = [eligible, blocked].enumerated().map { index, directory in
            RecentMeeting(directory: directory, title: index == 0 ? "Weekly planning" : "Design review", started: Date(timeIntervalSince1970: 1790935200),
                stage: .exported, issue: nil, detail: "", notes: directory.appendingPathComponent("notes/notes.md"), transcript: nil)
        }
        let rows = try AudioCleanup.review(meetings)
        XCTAssertEqual(rows[0].plan?.remaining.count, 2); XCTAssertNil(rows[1].plan)
        let controller = MenuBarController(preview: true)
        guard let output = ProcessInfo.processInfo.environment["CLAWMINUTES_UI_PREVIEW_DIR"] else { return }
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: AudioCleanupView(controller: controller, meetings: meetings)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSApp.appearance; window.contentView = view
            try await Task.sleep(for: .milliseconds(500))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("audio-cleanup-" + (dark ? "dark" : "light") + ".png"))
            XCTAssertFalse(window.isVisible)
            assertKept(eligible); assertKept(blocked)
            XCTAssertFalse(FileManager.default.fileExists(atPath: eligible.appendingPathComponent("audio-retention-receipt.json").path))
        }
    }
    func testAReplacementTrackCannotBeMarkedDeleted() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 60 }, remove: { file in
            try FileManager.default.removeItem(at: file)
            try Data("new audio".utf8).write(to: file)
        }))
        assertKept(dir); XCTAssertFalse(AudioRetention.explicitlyRemoved(dir))
    }
    func testLinkedRecordingFolderCannotCreateADeletionLockInItsTarget() throws {
        let dir = try fixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let link = dir.appendingPathComponent("linked-recording")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dir)
        XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(link, measure: { _ in 60 }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("archive.lock").path))
        assertKept(dir)
    }
}

extension AudioRetentionTests {
    private func splitFixture(pending: Bool = false, uncertain: Bool = false) throws -> URL {
        let dir = try fixture()
        var meta = try ArchiveBacklog.object(dir.appendingPathComponent("meta.json"))
        meta["files"] = ["mic": "mic.caf", "system": "system.caf"]
        meta["capture_segments"] = [
            ["source": "mic", "file": "mic.caf", "offset_ms": 0, "closed": true, "timing_uncertain": uncertain],
            ["source": "system", "file": "system.caf", "offset_ms": 0, "closed": true],
            ["source": "mic", "file": "mic-2.caf", "offset_ms": 30000, "closed": true, "rotation_pending": pending],
            ["source": "system", "file": "system-2.caf", "offset_ms": 30000, "closed": true]]
        try put(meta, "meta.json", dir)
        for name in ["mic-2.caf", "system-2.caf"] { try Data([1, 2, 3]).write(to: dir.appendingPathComponent(name)) }
        var receipt = try ArchiveBacklog.object(dir.appendingPathComponent("archive-receipt.json"))
        receipt["localEnvelopeSHA256"] = try GatewayArchive.sourceFingerprint(dir, meta: meta,
            transcriptData: Data(contentsOf: dir.appendingPathComponent("transcript.json")))
        try put(receipt, "archive-receipt.json", dir)
        return dir
    }
    func testContinuousChunksVerifyEachBoundaryAndDeleteOnlyAfterAllProofs() throws {
        let dir = try splitFixture(); defer { try? FileManager.default.removeItem(at: dir) }
        let plan = try XCTUnwrap(AudioRetention.review(dir, measure: { _ in 30 }))
        XCTAssertEqual(plan.tracks.map(\.seconds), [30, 30, 30, 30])
        XCTAssertEqual(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 30 }), 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic-2.caf").path))
    }
    func testShortOrOverlappingInternalChunkCannotBeHiddenByALaterFile() throws {
        for seconds in [27.0, 35.0] {
            let dir = try splitFixture(); defer { try? FileManager.default.removeItem(at: dir) }
            XCTAssertThrowsError(try AudioRetention.review(dir, measure: { $0.lastPathComponent == "mic.caf" ? seconds : 30 }))
            assertKept(dir)
        }
    }
    func testUncertainHandoffRejectsRemovalEvenWithMatchingTextReceipts() throws {
        for pending in [true, false] {
            let dir = try splitFixture(pending: pending, uncertain: !pending)
            defer { try? FileManager.default.removeItem(at: dir) }
            XCTAssertThrowsError(try AudioRetention.deleteAfterVerification(dir, measure: { _ in 30 }))
            assertKept(dir)
        }
    }
}
