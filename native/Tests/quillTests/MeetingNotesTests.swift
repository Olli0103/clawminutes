import XCTest
@testable import quill
final class MeetingNotesTests: XCTestCase {
    func testActiveCallDisprovesStaleEndObservation() {
        var context = MeetingContext(meeting_id: "teams:fixture", title: "Portfolio sync", title_source: "teams_window", first_observed_at: 100, last_observed_at: 120, ended_observed_at: 130)
        context.observeActive(at: 140)
        XCTAssertEqual(context.first_observed_at, 100)
        XCTAssertEqual(context.last_observed_at, 140)
        XCTAssertNil(context.ended_observed_at)
        XCTAssertNil(context.json["ended_observed_at"])
        context.ended_observed_at = 150
        XCTAssertEqual(context.json["ended_observed_at"] as? Double, 150)
    }
    func testUnicodeFolderComponentHasBoundedByteLength() {
        XCTAssertLessThanOrEqual(MeetingDocuments.component(String(repeating: "会議", count: 100)).utf8.count, 80)
    }
    func testTeamsWindowTitleRequiresSpecificSubject() {
        XCTAssertEqual(TeamsMeetingTitle.clean("Portfolio sync | Microsoft Teams"), "Portfolio sync")
        XCTAssertEqual(TeamsMeetingTitle.clean("Council | weekly | Example Org | alex@example.com"), "Council | weekly")
        XCTAssertEqual(TeamsMeetingTitle.clean("Title | discussion"), "Title | discussion")
        XCTAssertNil(TeamsMeetingTitle.clean("Microsoft Teams"))
        XCTAssertNil(TeamsMeetingTitle.clean("Meeting - Microsoft Teams"))
        XCTAssertNil(TeamsMeetingTitle.clean("Title\nInjected heading"))
    }
    func testTeamsCompactViewLabelIsNotPartOfMeetingTitleOrFolder() {
        XCTAssertEqual(TeamsMeetingTitle.clean("Meeting compact view | AI Standup"), "AI Standup")
        XCTAssertEqual(TeamsMeetingTitle.clean("Meeting compact view | AI Standup | Microsoft Teams"), "AI Standup")
        XCTAssertEqual(TeamsMeetingTitle.clean("Meeting compact view | Council | weekly | Example Org | alex@example.com"), "Council | weekly")
        XCTAssertEqual(MeetingDocuments.component("Meeting compact view | AI Standup"), "AI-Standup")
        XCTAssertNil(TeamsMeetingTitle.clean("Meeting compact view"))
        XCTAssertEqual(TeamsMeetingTitle.clean("Discussion about Meeting compact view"), "Discussion about Meeting compact view")
    }
    func testExportCannotEscapeRootAndPreservesEditsOnRetry() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = "teams-" + String(repeating: "a", count: 24)
        let receipt: [String: Any] = ["sessionId": id, "documents": ["title": "../../escape", "startedAt": "2026-10-02T10:00:00Z", "notesMarkdown": "notes", "transcriptMarkdown": "transcript", "metadata": ["sessionId": id]]]
        let folder = try MeetingDocuments.export(receipt: receipt, root: root, recording: root.appendingPathComponent("raw"))
        XCTAssertTrue(folder.path.hasPrefix(root.path + "/2026/10/"))
        try Data("edited".utf8).write(to: folder.appendingPathComponent("notes.md"))
        XCTAssertEqual(try MeetingDocuments.export(receipt: receipt, root: root, recording: root).path, folder.path)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8), "edited")
    }
    func testSymlinkExportsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("2026"), withDestinationURL: root)
        let id = "teams-" + String(repeating: "a", count: 24)
        let receipt: [String: Any] = ["sessionId": id, "documents": ["title": "title", "startedAt": "2026-10-02T10:00:00Z", "notesMarkdown": "notes", "transcriptMarkdown": "transcript", "metadata": ["sessionId": id]]]
        XCTAssertThrowsError(try MeetingDocuments.export(receipt: receipt, root: root, recording: root))
    }
    @MainActor func testMeetingContextSurvivesCheckpointsAndStopWithoutStartingCapture() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let time = Date().timeIntervalSince1970
        let context = MeetingContext(meeting_id: "teams:fixture", title: "Portfolio sync", title_source: "teams_window", first_observed_at: time, last_observed_at: time)
        let session = try RecordingSession(root: root, context: context, activityLockPath: root.appendingPathComponent("lifecycle.lock"))
        session.checkpoint(); session.stop()
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: session.dir.appendingPathComponent("meta.json"))) as! [String: Any]
        XCTAssertEqual((json["meeting_context"] as? [String: Any])?["title"] as? String, "Portfolio sync")
        XCTAssertNotNil(json["note_template"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("mic.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.dir.appendingPathComponent("system.caf").path))
    }
    func testCleanNamesUseOnlyTimestampAndMeetingTitle() throws {
        XCTAssertEqual(MeetingDocuments.component("  Council - weekly | Example Org | alex@example.com  "), "Council-weekly")
        XCTAssertEqual(MeetingDocuments.component("Holger <> Olli"), "Holger-Olli")
        XCTAssertEqual(MeetingDocuments.component("../ Janus / Roman __ "), "Janus-Roman")
        XCTAssertEqual(MeetingDocuments.component("Réunion: équipe"), "Réunion-équipe")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = exportReceipt(id: "a", title: "Holger <> Olli")
        let folder = try MeetingDocuments.export(receipt: receipt, root: root, recording: root)
        XCTAssertTrue(folder.lastPathComponent.hasSuffix("_Holger-Olli"))
        XCTAssertFalse(folder.lastPathComponent.contains("teams-"))
        XCTAssertNotNil(folder.lastPathComponent.range(of: #"^\d{4}\.\d{2}\.\d{2}-\d{4}_"#, options: .regularExpression))
    }
    func testLegacyExportMigratesWithoutLosingEditedFilesAndRetryIsStable() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = exportReceipt(id: "a", title: "Holger <> Olli")
        let current = try MeetingDocuments.export(receipt: receipt, root: root, recording: root)
        let old = current.deletingLastPathComponent().appendingPathComponent("2026-10-02_1200_Holger----Olli_teams-" + String(repeating: "a", count: 24))
        try FileManager.default.moveItem(at: current, to: old)
        try Data("user edited notes".utf8).write(to: old.appendingPathComponent("notes.md"))
        let metadata = try Data(contentsOf: old.appendingPathComponent("metadata.json"))
        let migrated = try MeetingDocuments.export(receipt: receipt, root: root, recording: root)
        XCTAssertEqual(migrated, current)
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(try String(contentsOf: migrated.appendingPathComponent("notes.md"), encoding: .utf8), "user edited notes")
        XCTAssertEqual(try Data(contentsOf: migrated.appendingPathComponent("metadata.json")), metadata)
        XCTAssertEqual(try MeetingDocuments.export(receipt: receipt, root: root, recording: root), migrated)
    }
    func testTwoMeetingsWithSameNameNeverOverwriteEachOther() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try MeetingDocuments.export(receipt: exportReceipt(id: "a", title: "Same title"), root: root, recording: root)
        let twoReceipt = exportReceipt(id: "b", title: "Same title")
        let two = try MeetingDocuments.export(receipt: twoReceipt, root: root, recording: root)
        XCTAssertNotEqual(one, two)
        XCTAssertEqual(try MeetingDocuments.export(receipt: twoReceipt, root: root, recording: root), two)
        let meta = try JSONSerialization.jsonObject(with: Data(contentsOf: one.appendingPathComponent("metadata.json"))) as! [String: Any]
        XCTAssertEqual(meta["sessionId"] as? String, "teams-" + String(repeating: "a", count: 24))
    }
    func testLinkedLegacyExportCannotBeMigrated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = exportReceipt(id: "a", title: "Title")
        let folder = try MeetingDocuments.export(receipt: receipt, root: root, recording: root)
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.moveItem(at: folder, to: outside)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: outside)
        XCTAssertThrowsError(try MeetingDocuments.export(receipt: receipt, root: root, recording: root))
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("notes.md").path))
    }
    private func exportReceipt(id: String, title: String) -> [String: Any] {
        let sessionID = "teams-" + String(repeating: id, count: 24)
        return ["sessionId": sessionID, "saved": true, "documents": ["title": title, "startedAt": "2026-10-02T10:00:00Z", "notesMarkdown": "notes", "transcriptMarkdown": "transcript", "metadata": ["sessionId": sessionID]]]
    }
    func testRevisionExportPreservesEditedOriginalNotes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = exportReceipt(id: "a", title: "Weekly sync")
        let original = try MeetingDocuments.export(receipt: receipt, root: root, recording: root)
        let edited = Data("User edited original notes".utf8)
        try edited.write(to: original.appendingPathComponent("notes.md"))
        let childReceipt = exportReceipt(id: "b", title: "Weekly sync · v2")
        let child = try MeetingDocuments.export(receipt: childReceipt, root: root, recording: root)
        XCTAssertNotEqual(child, original)
        XCTAssertTrue(child.lastPathComponent.hasSuffix("Weekly-sync-v2"))
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("notes.md")), edited)
        XCTAssertEqual(try MeetingDocuments.export(receipt: childReceipt, root: root, recording: root), child)
        XCTAssertEqual(try Data(contentsOf: original.appendingPathComponent("notes.md")), edited)
    }
    func testTemplateSnapshotAndValidation() throws {
        var template = NoteTemplate.defaults[0]; try template.validate()
        let snapshot = template.json; template.sections[0].title = "Changed"
        XCTAssertEqual((snapshot["sections"] as? [[String: String]])?[0]["title"], "Summary")
        template.sections = []; XCTAssertThrowsError(try template.validate())
    }
}


extension MeetingNotesTests {
    func testExplicitMigrationCopiesEditedNotesAndKeepsOriginal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        var receipt = exportReceipt(id: "a", title: "Meeting")
        receipt["saved"] = true
        try JSONSerialization.data(withJSONObject: receipt).write(to: recording.appendingPathComponent("archive-receipt.json"))
        try Data(#"{"status":"stopped","ended":"2026-10-02T12:00:00Z"}"#.utf8).write(to: recording.appendingPathComponent("meta.json"))
        let oldRoot = root.appendingPathComponent("old"), newRoot = root.appendingPathComponent("new")
        let old = try MeetingDocuments.export(receipt: receipt, root: oldRoot, recording: recording)
        try MeetingDocuments.rememberExport(old, root: oldRoot, recording: recording, sessionID: receipt["sessionId"] as! String)
        try Data("User edits".utf8).write(to: old.appendingPathComponent("notes.md"))
        let copied = try MeetingDocuments.migrateExport(recording: recording, to: newRoot)
        XCTAssertEqual(try Data(contentsOf: copied.appendingPathComponent("notes.md")), Data("User edits".utf8))
        XCTAssertEqual(try Data(contentsOf: old.appendingPathComponent("notes.md")), Data("User edits".utf8))
        XCTAssertEqual(try MeetingDocuments.exportRoot(recording: recording, fallbackRoot: oldRoot).path, newRoot.path)
        XCTAssertEqual(try MeetingDocuments.migrateExport(recording: recording, to: newRoot), copied)
    }
}
