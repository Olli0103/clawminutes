import AppKit
import SwiftUI
import XCTest
@testable import quill

final class LegacyReceiptReconciliationTests: XCTestCase {
    struct Fixture {
        let root: URL, recording: URL, notes: URL
        var lease: URL { root.appendingPathComponent("lease") }
    }
    func fixture(ai: Bool = false) throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("meeting"), notes = root.appendingPathComponent("notes")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        var meta: [String: Any] = ["status": "stopped", "started": "2026-10-02T10:00:00Z", "ended": "2026-10-02T10:01:00Z",
            "audio_started_at": 1790935200, "notes_mode": ai ? "ai" : "transcript"]
        if ai { meta["note_template"] = ["id": "fixture", "name": "Fixture", "context": "Synthetic", "sections": [["title": "Summary", "instructions": "Summarize"]]] }
        try JSONSerialization.data(withJSONObject: meta).write(to: recording.appendingPathComponent("meta.json"))
        let transcript: [String: Any] = ["engine": "parakeet", "model": "parakeet-tdt-0.6b-v3-coreml", "created_at": "2026-10-02T10:02:00Z",
            "execution_machine": "fixture-mac", "execution_location": "recording_mac", "segments": [["speaker": "unknown", "source": "system", "start_ms": 0, "end_ms": 1000, "text": "Synthetic speech"]]]
        try JSONSerialization.data(withJSONObject: transcript).write(to: recording.appendingPathComponent("transcript.json"))
        let id = "teams-" + AudioRetention.digest(Data(("2026-10-02T10:00:00Z\nmeeting").utf8)).prefix(24)
        try JSONSerialization.data(withJSONObject: ["saved": true, "sessionId": id, "utteranceCount": 1])
            .write(to: recording.appendingPathComponent("archive-receipt.json"))
        return Fixture(root: root, recording: recording, notes: notes)
    }
    static func capabilities(verification: Bool = true) throws -> Data {
        var features: [String: Any] = ["textEnvelope": 1, "structuredErrors": 1, "idempotentCompletedSave": true, "cappedNotesAttempts": 3, "revisions": 1, "notesRecovery": 1]
        if verification { features["receiptVerification"] = 1 }
        return try JSONSerialization.data(withJSONObject: ["plugin": "teams-transcribe", "protocolVersion": 1, "rawAudioAccepted": false, "gatewayMachine": "fixture", "capabilities": features,
            "archive": ["adapterVersion": 1, "sdkVersion": "2026.9.7", "verification": "isolated-readback-v1"]])
    }
    static func response(_ plan: LegacyReceiptReconciliation.Plan, valid: Bool = true) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["saved": true, "sessionId": plan.sessionID, "utteranceCount": 1,
            "verification": ["version": 1, "mode": "canonical_readback", "requestSHA256": valid ? AudioRetention.digest(plan.body) : "wrong"],
            "documents": ["title": "Weekly planning", "startedAt": "2026-10-02T10:00:00Z", "notesMarkdown": "Verified notes", "transcriptMarkdown": "Verified text", "metadata": ["sessionId": plan.sessionID]]])
    }
    func testPreparationDoesNotPublishFilesOrGuessAHash() throws {
        let f = try fixture(), before = try NotesFolderSnapshot.capture(f.recording)
        let plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        XCTAssertEqual(plan.utterances, 1)
        XCTAssertEqual(try NotesFolderSnapshot.capture(f.recording), before)
        XCTAssertTrue(RecentMeeting.make(ArchiveBacklog.inspect(f.recording)).canVerifyLegacyReceipt)
        XCTAssertNil(try ArchiveBacklog.object(f.recording.appendingPathComponent("archive-receipt.json"))["localTranscriptSHA256"])
    }
    func testRepairPreservesUnknownPaidBudgetAndLegacyEvidence() async throws {
        let f = try fixture(ai: true)
        let transcript = try ArchiveBacklog.read(f.recording.appendingPathComponent("transcript.json"))
        var legacyReceipt = try ArchiveBacklog.object(f.recording.appendingPathComponent("archive-receipt.json"))
        legacyReceipt["localTranscriptSHA256"] = AudioRetention.digest(transcript)
        try JSONSerialization.data(withJSONObject: legacyReceipt).write(to: f.recording.appendingPathComponent("archive-receipt.json"))
        let retry = ArchiveBacklog.Retry(attempts: 2, nextAttemptAt: 9999, transcriptSHA256: AudioRetention.digest(transcript))
        let retryBytes = try JSONEncoder().encode(retry)
        try retryBytes.write(to: f.recording.appendingPathComponent("archive-retry.json"))
        let plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        let old = try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-receipt.json"))
        let response = try Self.response(plan)
        let result = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in response }, capabilityTransport: { try Self.capabilities() }, activityLockPath: f.lease)
        XCTAssertTrue(result.exported)
        XCTAssertEqual(try ArchiveBacklog.object(f.recording.appendingPathComponent("archive-receipt.json"))["localEnvelopeSHA256"] as? String,
            try GatewayArchive.envelopeFingerprint(plan.body))
        XCTAssertEqual(ArchiveBacklog.inspect(f.recording, notesRoot: f.notes).state, .saved)
        let state = try MeetingPipelineState.load(f.recording)
        XCTAssertEqual(state.delivery.count, 2); XCTAssertTrue(state.delivery.budgetUnverified == true)
        XCTAssertNil(state.delivery.completionAttempts)
        XCTAssertEqual(try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-retry.json")), retryBytes)
        let backup = f.recording.appendingPathComponent("archive-receipt.legacy-" + AudioRetention.digest(old) + ".json")
        XCTAssertEqual(try ArchiveBacklog.read(backup), old)
    }
    func testOldGatewayOrUnboundReplyCannotRepairReceipt() async throws {
        for supported in [false, true] {
            let f = try fixture(), plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
            let old = try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-receipt.json"))
            let response = try Self.response(plan, valid: false)
            do {
                _ = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in
                    if !supported { XCTFail("An old Gateway must not receive meeting text for verification") }
                    return response
                }, capabilityTransport: { try Self.capabilities(verification: supported) }, activityLockPath: f.lease)
                XCTFail("Verification must reject missing admission or mismatched request proof")
            } catch {}
            XCTAssertEqual(try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-receipt.json")), old)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.notes.path))
        }
    }
    func testChangesDuringNetworkReadbackCannotPublishReceipt() async throws {
        let f = try fixture(), plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        let old = try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-receipt.json"))
        let response = try Self.response(plan)
        do {
            _ = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in
                try Data("changed speech".utf8).write(to: f.recording.appendingPathComponent("transcript.json"))
                return response
            }, capabilityTransport: { try Self.capabilities() }, activityLockPath: f.lease)
            XCTFail("Changed local speech must invalidate readback")
        } catch {}
        XCTAssertEqual(try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-receipt.json")), old)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.notes.path))
    }
    func testDirectSaveCannotResendAnUnverifiedLegacyReceipt() async throws {
        let f = try fixture()
        do {
            try await GatewayArchive.save(f.recording, transport: { _ in XCTFail("No resend allowed"); return Data() },
                capabilityTransport: { XCTFail("No network preflight allowed"); return Data() }, exportRootOverride: f.notes, activityLockPath: f.lease)
            XCTFail("Legacy receipt requires explicit verification")
        } catch { XCTAssertTrue(String(describing: error).contains(LegacyReceiptReconciliation.reason)) }
    }
    func testEarlierFingerprintConflictPreservesAllEvidence() throws {
        let f = try fixture(ai: true)
        let retry = ArchiveBacklog.Retry(attempts: 3, nextAttemptAt: 9999, transcriptSHA256: String(repeating: "a", count: 64))
        try JSONEncoder().encode(retry).write(to: f.recording.appendingPathComponent("archive-retry.json"))
        let before = try NotesFolderSnapshot.capture(f.recording)
        XCTAssertThrowsError(try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)) {
            XCTAssertTrue(String(describing: $0).contains("earlier local delivery fingerprint differs"))
        }
        XCTAssertEqual(try NotesFolderSnapshot.capture(f.recording), before)
    }
    func testMalformedDocumentsCannotPublishAReceiptOrBackup() async throws {
        let f = try fixture(), plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        var reply = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.response(plan)) as? [String: Any])
        reply["documents"] = ["title": "Missing required content"]
        let data = try JSONSerialization.data(withJSONObject: reply)
        let old = try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-receipt.json"))
        do {
            _ = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in data },
                capabilityTransport: { try Self.capabilities() }, activityLockPath: f.lease)
            XCTFail("Malformed documents must fail before publication")
        } catch {}
        XCTAssertEqual(try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-receipt.json")), old)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.recording.path).contains { $0.hasPrefix("archive-receipt.legacy-") })
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.notes.path))
    }
    func testReplacedDirectoryCannotCreateALockOrSendText() async throws {
        let f = try fixture(), plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        let original = f.root.appendingPathComponent("original"), target = f.root.appendingPathComponent("replacement")
        try FileManager.default.moveItem(at: f.recording, to: original)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: f.recording, withDestinationURL: target)
        do {
            _ = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in XCTFail("No text allowed"); return Data() },
                capabilityTransport: { XCTFail("No network allowed"); return Data() }, activityLockPath: f.lease)
            XCTFail("A replaced directory must fail before locks are created")
        } catch {}
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.lease.path))
    }
    func testSaveAndInstallerOwnershipBlockVerification() async throws {
        for installer in [false, true] {
            let f = try fixture(), plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
            let lock = try XCTUnwrap(AppRunLock.acquire(at: installer ? f.lease : f.recording.appendingPathComponent("archive.lock")))
            defer { withExtendedLifetime(lock) {} }
            do {
                _ = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in XCTFail("No text allowed"); return Data() },
                    capabilityTransport: { XCTFail("No network allowed"); return Data() }, activityLockPath: f.lease)
                XCTFail("Existing ownership must block verification")
            } catch {}
            XCTAssertNil(try ArchiveBacklog.object(f.recording.appendingPathComponent("archive-receipt.json"))["localTranscriptSHA256"])
        }
    }
    func testExportFailureRetainsVerifiedReceiptAndRetriesOffline() async throws {
        let f = try fixture(), plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        let response = try Self.response(plan)
        try Data("obstructed destination".utf8).write(to: f.notes)
        let result = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in response },
            capabilityTransport: { try Self.capabilities() }, activityLockPath: f.lease)
        XCTAssertFalse(result.exported)
        XCTAssertEqual(try ArchiveBacklog.object(f.recording.appendingPathComponent("archive-receipt.json"))["localTranscriptSHA256"] as? String, plan.transcriptSHA256)
        try FileManager.default.removeItem(at: f.notes)
        try await GatewayArchive.save(f.recording, transport: { _ in XCTFail("Verified export must stay offline"); return Data() },
            capabilityTransport: { XCTFail("Verified export needs no handshake"); return Data() }, exportRootOverride: f.notes, activityLockPath: f.lease)
        XCTAssertEqual(ArchiveBacklog.inspect(f.recording, notesRoot: f.notes).state, .saved)
    }
    @MainActor func testLegacyReviewRendersWithoutNetworkOrPublishingFiles() async throws {
        guard let output = ProcessInfo.processInfo.environment["CLAWMINUTES_UI_PREVIEW_DIR"] else { return }
        let controller = MenuBarController(preview: true), previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for missing in [false, true] {
            let f = try fixture()
            if missing { try FileManager.default.removeItem(at: f.recording.appendingPathComponent("archive-receipt.json")) }
            let before = try NotesFolderSnapshot.capture(f.recording)
            let meeting = RecentMeeting.make(ArchiveBacklog.inspect(f.recording))
            for dark in [false, true] {
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let view = NSHostingView(rootView: LegacyReceiptView(controller: controller, meeting: meeting, initialRoot: f.notes)
                    .environment(\.colorScheme, dark ? .dark : .light))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 470), styleMask: [.titled], backing: .buffered, defer: false)
                window.appearance = NSApp.appearance; window.contentView = view
                try await Task.sleep(for: .milliseconds(500)); view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let name = (missing ? "missing-receipt-" : "legacy-receipt-") + (dark ? "dark" : "light") + ".png"
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    .write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
                XCTAssertFalse(window.isVisible); XCTAssertEqual(try NotesFolderSnapshot.capture(f.recording), before)
            }
        }
    }
    func testLostReceiptCanRecoverAnExactCompletedSaveWithoutResettingUnknownBudget() async throws {
        let f = try fixture(ai: true)
        try FileManager.default.removeItem(at: f.recording.appendingPathComponent("archive-receipt.json"))
        let transcript = try ArchiveBacklog.read(f.recording.appendingPathComponent("transcript.json"))
        let retry = ArchiveBacklog.Retry(attempts: 2, nextAttemptAt: 9999, transcriptSHA256: AudioRetention.digest(transcript))
        let legacy = try JSONEncoder().encode(retry)
        try legacy.write(to: f.recording.appendingPathComponent("archive-retry.json"))
        let before = try NotesFolderSnapshot.capture(f.recording)
        let plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        XCTAssertEqual(try NotesFolderSnapshot.capture(f.recording), before)
        let response = try Self.response(plan)
        let result = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in response },
            capabilityTransport: { try Self.capabilities() }, activityLockPath: f.lease)
        XCTAssertTrue(result.exported)
        XCTAssertEqual(ArchiveBacklog.inspect(f.recording, notesRoot: f.notes).state, .saved)
        let state = try MeetingPipelineState.load(f.recording)
        XCTAssertEqual(state.delivery.count, 2); XCTAssertTrue(state.delivery.budgetUnverified == true)
        XCTAssertNil(state.delivery.completionAttempts)
        XCTAssertEqual(try ArchiveBacklog.read(f.recording.appendingPathComponent("archive-retry.json")), legacy)
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: f.recording.path).contains { $0.hasPrefix("archive-receipt.legacy-") })
    }

    func testMissingReceiptReviewIsAvailableWithoutInventingPriorDelivery() throws {
        let f = try fixture()
        try FileManager.default.removeItem(at: f.recording.appendingPathComponent("archive-receipt.json"))
        let before = try NotesFolderSnapshot.capture(f.recording)
        let item = ArchiveBacklog.inspect(f.recording)
        XCTAssertEqual(item.state, .archivePending)
        XCTAssertTrue(RecentMeeting.make(item).canVerifyLegacyReceipt)
        let plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
        XCTAssertTrue(plan.receiptWasMissing)
        XCTAssertEqual(plan.sessionID, "teams-" + (try MeetingPipelineState.identity(f.recording)).prefix(24))
        XCTAssertEqual(try NotesFolderSnapshot.capture(f.recording), before)
        XCTAssertEqual(try MeetingPipelineState.load(f.recording).delivery.count, 0)
    }
    func testMissingReceiptRejectsAbsentOrConflictingCanonicalSaveWithoutLocalPublication() async throws {
        for kind in ["missing", "conflict", "unsupported", "bad_proof", "bad_documents"] {
            let f = try fixture()
            try FileManager.default.removeItem(at: f.recording.appendingPathComponent("archive-receipt.json"))
            let plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
            let before = try NotesFolderSnapshot.capture(f.recording)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.response(plan, valid: kind != "bad_proof")) as? [String: Any])
            if kind == "bad_documents" { object["documents"] = ["title": "Incomplete"] }
            let response = try JSONSerialization.data(withJSONObject: object)
            do {
                _ = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in
                    if kind == "unsupported" { XCTFail("Old Gateway cannot receive text") }
                    if kind == "missing" || kind == "conflict" {
                        throw DeliveryFailure(code: kind == "missing" ? "archive_not_verified" : "revision_conflict",
                            detail: "No exact completed save", retryable: false, completionAttempted: false)
                    }
                    return response
                }, capabilityTransport: { try Self.capabilities(verification: kind != "unsupported") }, activityLockPath: f.lease)
                XCTFail("No exact proof exists: \(kind)")
            } catch {}
            let after = try NotesFolderSnapshot.capture(f.recording)
            XCTAssertEqual(after.files.filter { $0.key != "archive.lock" }, before.files, kind)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.notes.path))
        }
    }
    func testReceiptAppearingDuringMissingReceiptReviewInvalidatesRepair() async throws {
        for duringRequest in [false, true] {
            let f = try fixture()
            let file = f.recording.appendingPathComponent("archive-receipt.json")
            let original = try ArchiveBacklog.read(file)
            try FileManager.default.removeItem(at: file)
            let plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes)
            let response = try Self.response(plan)
            if !duringRequest { try original.write(to: file) }
            do {
                _ = try await LegacyReceiptReconciliation.apply(plan, transport: { _ in
                    if !duringRequest { XCTFail("A stale review cannot send text") }
                    try original.write(to: file)
                    return response
                }, capabilityTransport: {
                    if !duringRequest { XCTFail("A stale review cannot start negotiation") }
                    return try Self.capabilities()
                }, activityLockPath: f.lease)
                XCTFail("A newly present receipt must invalidate the missing-receipt plan")
            } catch {}
            XCTAssertEqual(try ArchiveBacklog.read(file), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.notes.path))
        }
    }
    func testMalformedPresentReceiptCannotBeTreatedAsMissing() throws {
        for bytes in [Data("invalid json".utf8), Data("false".utf8), Data("{}".utf8)] {
            let f = try fixture(), file = f.recording.appendingPathComponent("archive-receipt.json")
            try bytes.write(to: file)
            XCTAssertFalse(LegacyReceiptReconciliation.receiptAbsent(f.recording))
            XCTAssertThrowsError(try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes))
            XCTAssertFalse(RecentMeeting.make(ArchiveBacklog.inspect(f.recording)).canVerifyLegacyReceipt)
            XCTAssertEqual(try ArchiveBacklog.read(file), bytes)
        }
        let f = try fixture(), file = f.recording.appendingPathComponent("archive-receipt.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: f.root.appendingPathComponent("absent-target"))
        XCTAssertFalse(LegacyReceiptReconciliation.receiptAbsent(f.recording))
        XCTAssertThrowsError(try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.notes))
    }

    func testMissingReceiptUsesOnlyTheOriginalMatchingExportBinding() throws {
        for mismatch in [false, true] {
            let f = try fixture(), file = f.recording.appendingPathComponent("archive-receipt.json")
            let id = try XCTUnwrap(ArchiveBacklog.object(file)["sessionId"] as? String)
            try MeetingDocuments.rememberExport(f.notes.appendingPathComponent("existing"), root: f.notes,
                recording: f.recording, sessionID: mismatch ? "teams-other" : id)
            try FileManager.default.removeItem(at: file)
            let before = try NotesFolderSnapshot.capture(f.recording)
            // Normal export callers cannot use a receipt-less binding.
            XCTAssertThrowsError(try MeetingDocuments.exportRoot(recording: f.recording, fallbackRoot: f.root.appendingPathComponent("new-default")))
            if mismatch {
                XCTAssertThrowsError(try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.root.appendingPathComponent("new-default")))
            } else {
                let plan = try LegacyReceiptReconciliation.prepare(f.recording, notesRoot: f.root.appendingPathComponent("new-default"))
                XCTAssertEqual(plan.exportRoot.path, f.notes.path)
            }
            XCTAssertEqual(try NotesFolderSnapshot.capture(f.recording), before)
        }
    }

}
