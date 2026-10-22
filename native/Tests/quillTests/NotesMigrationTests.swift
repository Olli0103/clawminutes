import AppKit
import SwiftUI
import XCTest
@testable import quill

final class NotesMigrationTests: XCTestCase {
    struct Fixture {
        let root: URL, recording: URL, source: URL, destination: URL
        var lease: URL { root.appendingPathComponent("lifecycle.lock") }
        var meeting: RecentMeeting {
            RecentMeeting(directory: recording, title: "Weekly planning", started: nil, stage: .exported,
                issue: nil, detail: "Notes ready", notes: source.appendingPathComponent("notes.md"), transcript: nil)
        }
    }
    func fixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("recording"), destination = root.appendingPathComponent("copies")
        try fm.createDirectory(at: recording, withIntermediateDirectories: true)
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let id = "teams-" + String(repeating: "a", count: 24)
        let receipt: [String: Any] = ["saved": true, "sessionId": id, "documents": ["title": "Weekly planning",
            "startedAt": "2026-10-02T10:00:00Z", "notesMarkdown": "original notes", "transcriptMarkdown": "speech", "metadata": ["sessionId": id]]]
        try JSONSerialization.data(withJSONObject: receipt).write(to: recording.appendingPathComponent("archive-receipt.json"))
        try Data(#"{"status":"stopped","ended":"2026-10-02T12:00:00Z","recording_id":"fixture"}"#.utf8)
            .write(to: recording.appendingPathComponent("meta.json"))
        let oldRoot = root.appendingPathComponent("notes")
        let source = try MeetingDocuments.export(receipt: receipt, root: oldRoot, recording: recording)
        try MeetingDocuments.rememberExport(source, root: oldRoot, recording: recording, sessionID: id)
        try Data("My edited notes".utf8).write(to: source.appendingPathComponent("notes.md"))
        return Fixture(root: root, recording: recording, source: source, destination: destination)
    }
    func testReviewIsReadOnlyAndCopyPreservesEditsAndEmptyDirectories() throws {
        let f = try fixture(), fm = FileManager.default
        try fm.createDirectory(at: f.source.appendingPathComponent("attachments/empty"), withIntermediateDirectories: true)
        try Data("extra attachment".utf8).write(to: f.source.appendingPathComponent("attachments/file.txt"))
        let original = try NotesFolderSnapshot.capture(f.source)
        let binding = try ArchiveBacklog.read(f.recording.appendingPathComponent("notes-export-location.json"))
        let rows = try NotesMigration.review([f.meeting], to: f.destination)
        let plan = try XCTUnwrap(rows.first?.plan)
        XCTAssertNil(rows.first?.issue)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.destination.path), [])
        XCTAssertEqual(try ArchiveBacklog.read(f.recording.appendingPathComponent("notes-export-location.json")), binding)
        let copied = try NotesMigration.execute(plan, activityLockPath: f.lease)
        XCTAssertEqual(try NotesFolderSnapshot.capture(copied), original)
        XCTAssertEqual(try NotesFolderSnapshot.capture(f.source), original)
        XCTAssertEqual(try MeetingDocuments.exportRoot(recording: f.recording, fallbackRoot: f.root).path, f.destination.path)
        XCTAssertTrue(copied.lastPathComponent.hasSuffix("_Weekly-planning"))
    }
    func testChangedAddedAndRemovedSourceFilesInvalidateReviewedPlan() throws {
        for change in ["edit", "add", "remove"] {
            let f = try fixture(), plan = try NotesMigration.prepare(f.recording, to: f.destination)
            if change == "edit" { try Data("Changed again".utf8).write(to: f.source.appendingPathComponent("notes.md")) }
            if change == "add" { try Data("new".utf8).write(to: f.source.appendingPathComponent("new.txt")) }
            if change == "remove" { try FileManager.default.removeItem(at: f.source.appendingPathComponent("transcript.md")) }
            XCTAssertThrowsError(try NotesMigration.execute(plan, activityLockPath: f.lease))
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
            XCTAssertEqual(try String(contentsOf: f.recording.appendingPathComponent("notes-export-path.txt"), encoding: .utf8), f.source.path)
        }
    }
    func testChangedReceiptOrRecordingIdentityInvalidatesReviewedPlan() throws {
        for name in ["archive-receipt.json", "meta.json"] {
            let f = try fixture(), plan = try NotesMigration.prepare(f.recording, to: f.destination)
            let file = f.recording.appendingPathComponent(name)
            var object = try ArchiveBacklog.object(file)
            object[name == "meta.json" ? "recording_id" : "additional"] = "changed"
            try JSONSerialization.data(withJSONObject: object).write(to: file)
            XCTAssertThrowsError(try NotesMigration.execute(plan, activityLockPath: f.lease))
            XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
        }
    }
    func testReplacedDestinationAndConflictNeverPublishOrOverwrite() throws {
        let f = try fixture(), fm = FileManager.default
        let plan = try NotesMigration.prepare(f.recording, to: f.destination)
        let renamed = f.root.appendingPathComponent("previous-destination")
        try fm.moveItem(at: f.destination, to: renamed)
        try fm.createDirectory(at: f.destination, withIntermediateDirectories: false)
        XCTAssertThrowsError(try NotesMigration.execute(plan, activityLockPath: f.lease))
        let fresh = try NotesMigration.prepare(f.recording, to: f.destination)
        try fm.createDirectory(at: fresh.destination, withIntermediateDirectories: true)
        try Data("do not overwrite".utf8).write(to: fresh.destination.appendingPathComponent("sentinel"))
        XCTAssertThrowsError(try NotesMigration.execute(fresh, activityLockPath: f.lease))
        XCTAssertEqual(try String(contentsOf: fresh.destination.appendingPathComponent("sentinel"), encoding: .utf8), "do not overwrite")
    }
    func testLinkedFilesLinkedRootsAndOversizedFilesAreRejected() throws {
        let f = try fixture(), fm = FileManager.default
        let link = f.source.appendingPathComponent("linked.txt")
        try fm.createSymbolicLink(at: link, withDestinationURL: f.source.appendingPathComponent("notes.md"))
        XCTAssertThrowsError(try NotesMigration.prepare(f.recording, to: f.destination))
        try fm.removeItem(at: link)
        let rootLink = f.root.appendingPathComponent("linked-root")
        try fm.createSymbolicLink(at: rootLink, withDestinationURL: f.destination)
        XCTAssertThrowsError(try NotesMigration.prepare(f.recording, to: rootLink))
        let large = f.source.appendingPathComponent("large.bin")
        XCTAssertTrue(fm.createFile(atPath: large.path, contents: nil))
        let handle = try FileHandle(forWritingTo: large)
        try handle.truncate(atOffset: 16_000_001); try handle.close()
        XCTAssertThrowsError(try NotesMigration.prepare(f.recording, to: f.destination))
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: f.destination.path), [])
    }
    func testDestinationInsideSourceCannotRecursivelyCopyItself() throws {
        let f = try fixture()
        XCTAssertThrowsError(try NotesMigration.prepare(f.recording, to: f.source))
        XCTAssertThrowsError(try MeetingDocuments.migrateExport(recording: f.recording, to: f.source))
        XCTAssertEqual(try NotesFolderSnapshot.capture(f.source).files.count, 3)
    }
    func testSaveLockAndInstallerLeaseBlockCopy() throws {
        let f = try fixture(), plan = try NotesMigration.prepare(f.recording, to: f.destination)
        do {
            let saveLock = try XCTUnwrap(AppRunLock.acquire(at: f.recording.appendingPathComponent("archive.lock")))
            try withExtendedLifetime(saveLock) { XCTAssertThrowsError(try NotesMigration.execute(plan, activityLockPath: f.lease)) }
        }
        do {
            let installerLock = try XCTUnwrap(AppRunLock.acquire(at: f.lease))
            try withExtendedLifetime(installerLock) { XCTAssertThrowsError(try NotesMigration.execute(plan, activityLockPath: f.lease)) }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: plan.destination.path))
    }
    func testReviewReportsUnavailableMeetingsWithoutLosingEligibleRows() throws {
        let f = try fixture()
        let missing = RecentMeeting(directory: f.root.appendingPathComponent("missing"), title: "Earlier meeting", started: nil,
            stage: .needsAttention, issue: nil, detail: "", notes: nil, transcript: nil)
        let rows = try NotesMigration.review([f.meeting, missing], to: f.destination)
        XCTAssertNotNil(rows[0].plan); XCTAssertNil(rows[0].issue)
        XCTAssertNil(rows[1].plan); XCTAssertNotNil(rows[1].issue)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.destination.path), [])
    }
    @MainActor func testCopyReviewRendersLightAndDarkWithoutOpeningWindowOrWritingNotes() async throws {
        let f = try fixture(), controller = MenuBarController(preview: true)
        guard let output = ProcessInfo.processInfo.environment["CLAWMINUTES_UI_PREVIEW_DIR"] else { return }
        let previous = NSApp.appearance
        defer { NSApp.appearance = previous }
        for dark in [false, true] {
            NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let view = NSHostingView(rootView: NotesMigrationView(controller: controller, meetings: [f.meeting], destination: f.destination)
                .environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSApp.appearance; window.contentView = view
            try await Task.sleep(for: .milliseconds(500))
            view.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                .write(to: URL(fileURLWithPath: output).appendingPathComponent("notes-copy-" + (dark ? "dark" : "light") + ".png"))
            XCTAssertFalse(window.isVisible)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: f.destination.path), [])
        }
    }
}
