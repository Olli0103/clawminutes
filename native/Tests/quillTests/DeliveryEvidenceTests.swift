import Foundation
import XCTest
@testable import quill

final class DeliveryEvidenceTests: XCTestCase {
    struct Fixture {
        let directory: URL, notes: URL, lease: URL
        let receipt: [String: Any]
    }
    private func fixture(saved: Bool = true, gaps: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("meeting"), notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let meta: [String: Any] = ["status": "stopped", "recording_id": "meeting", "started": "2026-10-08T10:00:00Z",
            "ended": "2026-10-08T10:01:00Z", "audio_started_at": 1791453600, "notes_mode": "transcript",
            "meeting_context": ["title": "Original title"]]
        try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
        var transcript: [String: Any] = ["engine": "parakeet", "model": "parakeet-tdt-0.6b-v3-coreml", "created_at": "2026-10-08T10:02:00Z",
            "execution_machine": "fixture", "execution_location": "recording_mac",
            "segments": [["speaker": "unknown", "source": "system", "start_ms": 0, "end_ms": 1000, "text": "Synthetic speech"]]]
        if gaps { transcript["capture_gaps"] = [["source": "system", "start_ms": 1000, "end_ms": 2000, "reason": "track_unavailable"]] }
        let data = try JSONSerialization.data(withJSONObject: transcript)
        try data.write(to: directory.appendingPathComponent("transcript.json"))
        let id = "teams-" + AudioRetention.digest(Data("2026-10-08T10:00:00Z\nmeeting".utf8)).prefix(24)
        let body = try GatewayArchive.envelope(meta: meta, transcript: transcript, recordingID: "meeting")
        let canonical = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: body), options: [.sortedKeys])
        let receipt: [String: Any] = ["saved": true, "sessionId": id, "utteranceCount": 1,
            "localTranscriptSHA256": AudioRetention.digest(data), "localEnvelopeSHA256": AudioRetention.digest(canonical),
            "documents": ["title": "Original title", "startedAt": "2026-10-08T10:00:00Z", "notesMarkdown": "Saved notes",
                "transcriptMarkdown": "Saved speech", "metadata": ["sessionId": id]]]
        if saved {
            try JSONSerialization.data(withJSONObject: receipt).write(to: directory.appendingPathComponent("archive-receipt.json"))
            let export = try MeetingDocuments.export(receipt: receipt, root: notes, recording: directory)
            try MeetingDocuments.rememberExport(export, root: notes, recording: directory, sessionID: String(id))
        }
        return Fixture(directory: directory, notes: notes, lease: root.appendingPathComponent("lease"), receipt: receipt)
    }
    func testChangedMetadataCannotHideBehindAnUnchangedTranscript() throws {
        for key in ["meeting_context", "participants", "note_template"] {
            let f = try fixture()
            XCTAssertEqual(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes).state, .saved)
            var meta = try ArchiveBacklog.object(f.directory.appendingPathComponent("meta.json"))
            if key == "meeting_context" { meta[key] = ["title": "Changed title"] }
            if key == "participants" { meta[key] = ["joined": [["name": "Fixture Alice", "sources": ["meeting_roster"]]], "coverage": "partial", "invited": [], "invitees_status": "unavailable"] }
            if key == "note_template" { meta[key] = ["id": "changed", "name": "Changed", "context": "Different instructions", "sections": [["title": "Summary", "instructions": "Summarize"]]] }
            try JSONSerialization.data(withJSONObject: meta).write(to: f.directory.appendingPathComponent("meta.json"))
            XCTAssertEqual(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes).state, .needsReview, key)
        }
    }
    func testMetadataChangeDuringSaveCannotBindTheOldResponse() async throws {
        let f = try fixture(saved: false)
        let reply = try JSONSerialization.data(withJSONObject: f.receipt)
        let directory = f.directory
        do {
            try await GatewayArchive.save(f.directory, transport: { _ in
                var meta = try ArchiveBacklog.object(directory.appendingPathComponent("meta.json"))
                meta["meeting_context"] = ["title": "Changed during delivery"]
                try JSONSerialization.data(withJSONObject: meta).write(to: directory.appendingPathComponent("meta.json"))
                return reply
            }, capabilityTransport: { try LegacyReceiptReconciliationTests.capabilities() }, exportRootOverride: f.notes, activityLockPath: f.lease)
            XCTFail("An old response cannot prove delivery of changed metadata")
        } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory.appendingPathComponent("archive-receipt.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.notes.path))
        let conflict = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("delivery-conflict.") })
        let preserved = try ArchiveBacklog.object(conflict)
        let originalRequest = try XCTUnwrap(preserved["request"] as? [String: Any])
        let originalMeta = try XCTUnwrap(originalRequest["meta"] as? [String: Any])
        XCTAssertEqual((originalMeta["meeting_context"] as? [String: Any])?["title"] as? String, "Original title")
        XCTAssertEqual((preserved["receipt"] as? [String: Any])?["sessionId"] as? String, f.receipt["sessionId"] as? String)
    }
    func testSavedGapWarningTakesPriorityOverStaleModelAndAIErrors() throws {
        let f = try fixture(gaps: true)
        var state = try MeetingPipelineState.load(f.directory)
        state.transcription.lastError = SpeechRecognitionIssue.localModelMissing.failure
        state.transcription.lastErrorAt = 100
        state.delivery = .init(count: 2, nextAttemptAt: 7000,
            lastError: DeliveryFailure(code: "ai_invalid_output", detail: "Earlier AI failure", retryable: false, completionAttempted: true),
            transcriptSHA256: f.receipt["localTranscriptSHA256"] as? String, completionAttempts: 2)
        try state.write(f.directory)
        let item = ArchiveBacklog.inspect(f.directory, notesRoot: f.notes)
        let meeting = RecentMeeting.make(item)
        XCTAssertEqual(meeting.stage, .needsAttention)
        XCTAssertNil(meeting.issue)
        XCTAssertTrue(meeting.detail.contains("capture gaps"))
        state = try MeetingPipelineState.load(f.directory)
        state.reconcile(item, now: 8000)
        XCTAssertNil(state.transcription.lastError); XCTAssertNil(state.transcription.lastErrorAt)
        XCTAssertNil(state.delivery.lastError); XCTAssertEqual(state.delivery.count, 2)
        XCTAssertEqual(state.delivery.completionAttempts, 2)
    }
    func testSourceFingerprintIgnoresObjectOrderAndPrivateCaptureHousekeeping() throws {
        let f = try fixture()
        let file = f.directory.appendingPathComponent("meta.json")
        var meta = try ArchiveBacklog.object(file)
        meta["checkpoint_at"] = 9999; meta["files"] = ["mic": "PRIVATE AUDIO PATH"]
        try JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys]).write(to: file)
        XCTAssertEqual(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes).state, .saved)
        let body = try GatewayArchive.deliveryEnvelope(f.directory, meta: meta, transcriptData: ArchiveBacklog.read(f.directory.appendingPathComponent("transcript.json")))
        let reordered = try JSONSerialization.data(withJSONObject: JSONSerialization.jsonObject(with: body), options: [.prettyPrinted, .sortedKeys])
        XCTAssertEqual(try GatewayArchive.envelopeFingerprint(body), try GatewayArchive.envelopeFingerprint(reordered))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("PRIVATE AUDIO PATH"))
    }
    func testSavedSourceConflictDoesNotAllowNetworkOrAnotherPaidAttempt() async throws {
        let f = try fixture()
        var meta = try ArchiveBacklog.object(f.directory.appendingPathComponent("meta.json"))
        meta["meeting_context"] = ["title": "Changed after saving"]
        try JSONSerialization.data(withJSONObject: meta).write(to: f.directory.appendingPathComponent("meta.json"))
        do {
            try await GatewayArchive.save(f.directory, transport: { _ in XCTFail("A saved conflict must not resend"); return Data() },
                capabilityTransport: { XCTFail("A saved conflict needs review before network"); return Data() }, exportRootOverride: f.notes, activityLockPath: f.lease)
            XCTFail("Changed saved metadata must require a revision")
        } catch {}
        XCTAssertFalse(RecentMeeting.make(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes)).canVerifyLegacyReceipt)
    }
    func testSuccessfulCallbackWithoutSavedArtifactsCannotClaimCompletion() async throws {
        let f = try fixture(saved: false)
        let stage = MeetingDeliveryStage(activityLockPath: f.lease, saveArchive: { _ in },
            onSaved: { _ in XCTFail("A callback returning does not prove saved documents") })
        if case .failed(let issue) = await stage.deliver(f.directory, now: 100) {
            XCTAssertEqual(issue.code, "local_save_unverified")
        } else { XCTFail("Delivery must verify its artifacts before reporting success") }
        let state = try MeetingPipelineState.load(f.directory)
        XCTAssertEqual(state.delivery.count, 1); XCTAssertEqual(state.delivery.completionAttempts, 0)
    }
    func testVerifiedLocalExportIgnoresRemoteBackoffAndPreservesPaidBudget() async throws {
        let f = try fixture()
        let path = try String(contentsOf: f.directory.appendingPathComponent("notes-export-path.txt"), encoding: .utf8)
        try FileManager.default.removeItem(atPath: path)
        var state = try MeetingPipelineState.load(f.directory)
        state.delivery = .init(count: 5, nextAttemptAt: 7000, transcriptSHA256: f.receipt["localTranscriptSHA256"] as? String, completionAttempts: 3)
        try state.write(f.directory)
        let coordinator = TranscriptionCoordinator(activityLockPath: f.lease, saveArchive: { _ in
            XCTFail("A verified local export must not invoke Gateway delivery")
        })
        let report = try await coordinator.retryArchiveBacklog(root: f.directory.deletingLastPathComponent(), now: 100)
        XCTAssertEqual(report.attempted, 1, "Local export must not inherit a Gateway retry deadline")
        XCTAssertEqual(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes).state, .saved)
        state = try MeetingPipelineState.load(f.directory)
        XCTAssertEqual(state.delivery.count, 5); XCTAssertEqual(state.delivery.completionAttempts, 3)
        XCTAssertEqual(state.delivery.nextAttemptAt, 7000)
    }
    func testExportFailureAfterRemoteReceiptDoesNotBecomeAnAIFailure() async throws {
        let f = try fixture(saved: false), directory = f.directory
        var state = try MeetingPipelineState.load(directory)
        state.delivery = .init(count: 2, nextAttemptAt: 0, transcriptSHA256: f.receipt["localTranscriptSHA256"] as? String, completionAttempts: 3)
        // A completed receipt proves delivery even if an old paid cap remains.
        let receipt = try JSONSerialization.data(withJSONObject: f.receipt)
        try receipt.write(to: directory.appendingPathComponent("archive-receipt.json"))
        try state.write(directory)
        try MeetingDocuments.rememberExport(f.notes.appendingPathComponent("meeting"), root: f.notes,
            recording: directory, sessionID: f.receipt["sessionId"] as! String)
        try Data("destination is blocked".utf8).write(to: f.notes)
        let stage = MeetingDeliveryStage(activityLockPath: f.lease, saveArchive: { _ in
            XCTFail("Local export is already receipted")
        }, onSaved: { _ in XCTFail("An obstructed destination is not saved") })
        if case .failed(let issue) = await stage.deliver(directory, now: 100) {
            XCTAssertEqual(issue.code, "local_export_failed")
        } else { XCTFail("A blocked notes folder must report a local export failure") }
        state = try MeetingPipelineState.load(directory)
        XCTAssertEqual(state.delivery.count, 2); XCTAssertEqual(state.delivery.completionAttempts, 3)
        XCTAssertNil(state.delivery.lastError, "Export failure cannot replace delivery with an AI cap")
        let persisted = try ArchiveBacklog.object(directory.appendingPathComponent("state.json"))
        XCTAssertEqual((persisted["localExport"] as? [String: Any])?["count"] as? Int, 1)
    }
    func testLocalExportBudgetSurvivesRelaunchAndExplicitRetryIsOffline() throws {
        let f = try fixture()
        let original = try String(contentsOf: f.directory.appendingPathComponent("notes-export-path.txt"), encoding: .utf8)
        try FileManager.default.removeItem(at: f.notes)
        try Data("blocked".utf8).write(to: f.notes)
        for now in [100.0, 200, 400] {
            XCTAssertThrowsError(try VerifiedLocalExport.perform(f.directory, activityLockPath: f.lease, now: now))
        }
        var state = try MeetingPipelineState.load(f.directory)
        XCTAssertEqual(state.localExport?.count, 3)
        XCTAssertEqual(state.localExport?.lastError?.code, "local_export_retry_limit")
        XCTAssertEqual(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes).state, .needsReview)
        XCTAssertTrue(RecentMeeting.make(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes)).canRetryLocalExport)
        XCTAssertFalse(try VerifiedLocalExport.perform(f.directory, activityLockPath: f.lease, now: 10000))
        try FileManager.default.removeItem(at: f.notes)
        XCTAssertTrue(try VerifiedLocalExport.perform(f.directory, activityLockPath: f.lease, now: 10001, explicit: true))
        state = try MeetingPipelineState.load(f.directory)
        XCTAssertEqual(state.localExport?.count, 4); XCTAssertNil(state.localExport?.lastError)
        XCTAssertEqual(state.delivery.count, 0)
        XCTAssertEqual(try String(contentsOf: f.directory.appendingPathComponent("notes-export-path.txt"), encoding: .utf8), original)
    }
    func testLocalExportBackoffAndOwnershipDoNotReserveAnAttempt() throws {
        let f = try fixture()
        let original = try String(contentsOf: f.directory.appendingPathComponent("notes-export-path.txt"), encoding: .utf8)
        try FileManager.default.removeItem(atPath: original)
        var state = try MeetingPipelineState.load(f.directory)
        state.localExport = .init(count: 1, nextAttemptAt: 500)
        try state.write(f.directory)
        XCTAssertFalse(try VerifiedLocalExport.perform(f.directory, activityLockPath: f.lease, now: 100))
        let lock = try XCTUnwrap(AppRunLock.acquire(at: f.directory.appendingPathComponent("archive.lock")))
        XCTAssertThrowsError(try VerifiedLocalExport.perform(f.directory, activityLockPath: f.lease, now: 100, explicit: true))
        withExtendedLifetime(lock) {}
        state = try MeetingPipelineState.load(f.directory)
        XCTAssertEqual(state.localExport?.count, 1)
    }
    func testFirstRemoteSaveWithDiskFailureIsRecordedOnlyAsLocalExport() async throws {
        let f = try fixture(saved: false), dir = f.directory, notes = f.notes, lease = f.lease
        let reply = try JSONSerialization.data(withJSONObject: f.receipt)
        let stage = MeetingDeliveryStage(activityLockPath: lease, saveArchive: { directory in
            try await GatewayArchive.save(directory, transport: { _ in
                // Simulate disk becoming unavailable only after the remote save.
                try MeetingDocuments.rememberExport(notes.appendingPathComponent("meeting"), root: notes,
                    recording: dir, sessionID: "teams-" + AudioRetention.digest(Data("2026-10-08T10:00:00Z\nmeeting".utf8)).prefix(24))
                try Data("blocked".utf8).write(to: notes)
                return reply
            }, capabilityTransport: { try LegacyReceiptReconciliationTests.capabilities() },
                exportRootOverride: notes, activityLockPath: lease)
        }, onSaved: { _ in XCTFail("No exported notes yet") })
        if case .failed(let issue) = await stage.deliver(dir, now: 100) {
            XCTAssertEqual(issue.code, "local_export_failed")
        } else { XCTFail("Disk failure must not claim completion") }
        let state = try MeetingPipelineState.load(dir)
        XCTAssertEqual(state.delivery.count, 1); XCTAssertNil(state.delivery.lastError)
        XCTAssertEqual(state.localExport?.count, 1)
        XCTAssertEqual(ArchiveBacklog.inspect(dir, notesRoot: notes).verifiedText, .archive)
    }
    func testMalformedLocalExportStateFailsClosed() throws {
        let f = try fixture()
        var state = try MeetingPipelineState.load(f.directory); try state.write(f.directory)
        var json = try ArchiveBacklog.object(f.directory.appendingPathComponent("state.json"))
        json["localExport"] = ["count": -1, "nextAttemptAt": 0]
        try JSONSerialization.data(withJSONObject: json).write(to: f.directory.appendingPathComponent("state.json"))
        XCTAssertThrowsError(try MeetingPipelineState.load(f.directory))
        XCTAssertThrowsError(try VerifiedLocalExport.perform(f.directory, activityLockPath: f.lease, explicit: true))
    }

    func testManualArchiveRespectsPermanentFailure() async throws {
        let f = try fixture(saved: false)
        var state = try MeetingPipelineState.load(f.directory)
        state.delivery = .init(count: 1, nextAttemptAt: 0,
            lastError: DeliveryFailure(code: "ai_invalid_output", detail: "Review the model output", retryable: false, completionAttempted: true),
            transcriptSHA256: f.receipt["localTranscriptSHA256"] as? String, completionAttempts: 1)
        try state.write(f.directory)
        let original = try ArchiveBacklog.read(f.directory.appendingPathComponent("state.json"))
        let command = try ArchiveSession.parse(["--directory", f.directory.path])
        do {
            try await command.archive(activityLockPath: f.lease, appLockPath: f.lease.appendingPathExtension("app"), now: 100,
                saveArchive: { _ in XCTFail("Manual archive must not bypass a permanent failure") })
            XCTFail("A skipped send must not report that the meeting was saved")
        } catch {}
        XCTAssertEqual(try ArchiveBacklog.read(f.directory.appendingPathComponent("state.json")), original)
    }

    func testManualArchivePreservesBlockedBudgetsAndRetryDeadline() async throws {
        for kind in ["paid_cap", "unknown_budget", "backoff"] {
            let f = try fixture(saved: false)
            var state = try MeetingPipelineState.load(f.directory)
            state.delivery = .init(count: 3, nextAttemptAt: kind == "backoff" ? 500 : 0,
                transcriptSHA256: f.receipt["localTranscriptSHA256"] as? String,
                completionAttempts: kind == "paid_cap" ? 3 : 0)
            if kind == "unknown_budget" { state.delivery.completionAttempts = nil; state.delivery.budgetUnverified = true }
            try state.write(f.directory)
            let original = try ArchiveBacklog.read(f.directory.appendingPathComponent("state.json"))
            let command = try ArchiveSession.parse(["--directory", f.directory.path])
            do {
                try await command.archive(activityLockPath: f.lease, appLockPath: f.lease.appendingPathExtension("app"), now: 100,
                    saveArchive: { _ in XCTFail("Blocked manual archive must not send") })
                XCTFail("Blocked meeting must not claim success: \(kind)")
            } catch {}
            XCTAssertEqual(try ArchiveBacklog.read(f.directory.appendingPathComponent("state.json")), original, kind)
        }
    }
    func testManualArchiveReservesAndPersistsPaidFailure() async throws {
        let f = try fixture(saved: false), directory = f.directory
        let command = try ArchiveSession.parse(["--directory", directory.path])
        do {
            try await command.archive(activityLockPath: f.lease, appLockPath: f.lease.appendingPathExtension("app"), now: 100,
                saveArchive: { folder in
                    let reserved = try MeetingPipelineState.load(folder)
                    XCTAssertEqual(reserved.delivery.count, 1)
                    XCTAssertEqual(reserved.delivery.nextAttemptAt, 130)
                    throw DeliveryFailure(code: "ai_invalid_output", detail: "Synthetic invalid output", retryable: false, completionAttempted: true)
                })
            XCTFail("Failed completion must not claim success")
        } catch { XCTAssertEqual((error as? DeliveryFailure)?.code, "ai_invalid_output") }
        let state = try MeetingPipelineState.load(directory)
        XCTAssertEqual(state.delivery.count, 1); XCTAssertEqual(state.delivery.completionAttempts, 1)
        XCTAssertEqual(state.delivery.lastError?.code, "ai_invalid_output")
    }
    func testManualArchiveHonorsHelperOwnershipAndVerifiedOfflineSave() async throws {
        let f = try fixture(), path = f.lease.appendingPathExtension("app")
        let command = try ArchiveSession.parse(["--directory", f.directory.path])
        do {
            let owner = try XCTUnwrap(AppRunLock.acquire(at: path))
            defer { withExtendedLifetime(owner) {} }
            do {
                try await command.archive(activityLockPath: f.lease, appLockPath: path, now: 100,
                    saveArchive: { _ in XCTFail("Active helper owns delivery") })
                XCTFail("CLI must not compete with the running helper")
            } catch {}
        }
        try await command.archive(activityLockPath: f.lease, appLockPath: path, now: 100,
            saveArchive: { _ in XCTFail("Verified export needs no Gateway request") })
        XCTAssertEqual(ArchiveBacklog.inspect(f.directory, notesRoot: f.notes).verifiedText, .exported)
    }
    func testManualArchiveUsesRealWriterAndVerifiesSavedArtifacts() async throws {
        let f = try fixture(saved: false), notes = f.notes, lease = f.lease
        let response = try JSONSerialization.data(withJSONObject: f.receipt)
        let command = try ArchiveSession.parse(["--directory", f.directory.path])
        try await command.archive(activityLockPath: lease, appLockPath: lease.appendingPathExtension("app"), now: 100,
            saveArchive: { folder in
                try await GatewayArchive.save(folder, transport: { _ in response },
                    capabilityTransport: { try LegacyReceiptReconciliationTests.capabilities() },
                    exportRootOverride: notes, activityLockPath: lease)
            })
        XCTAssertEqual(ArchiveBacklog.inspect(f.directory, notesRoot: notes).verifiedText, .exported)
        XCTAssertEqual(try MeetingPipelineState.load(f.directory).delivery.count, 1)
    }
    func testManualArchiveCannotClaimSuccessFromAnEmptyCallback() async throws {
        let f = try fixture(saved: false)
        let command = try ArchiveSession.parse(["--directory", f.directory.path])
        do {
            try await command.archive(activityLockPath: f.lease, appLockPath: f.lease.appendingPathExtension("app"), now: 100,
                saveArchive: { _ in })
            XCTFail("An empty callback does not prove saved artifacts")
        } catch { XCTAssertEqual((error as? DeliveryFailure)?.code, "local_save_unverified") }
        XCTAssertEqual(try MeetingPipelineState.load(f.directory).delivery.count, 1)
    }

}
