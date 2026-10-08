import Foundation
import XCTest
@testable import quill

final class MeetingLibraryTests: XCTestCase {
    @MainActor func testSearchKeepsAttentionFilterAndNeverTreatsSendingAsReady() {
        let root = URL(fileURLWithPath: "/fixture")
        let ready = RecentMeeting(directory: root.appendingPathComponent("one"), title: "Weekly planning", started: nil, stage: .exported, issue: nil, detail: "", notes: root.appendingPathComponent("notes.md"), transcript: nil)
        let pending = RecentMeeting(directory: root.appendingPathComponent("two"), title: "Weekly design", started: nil, stage: .needsAttention, issue: .signInRequired, detail: "", notes: nil, transcript: nil)
        XCTAssertEqual(MeetingLibraryView.filtered([ready, pending], query: " WEEKLY ", attentionOnly: false).count, 2)
        XCTAssertEqual(MeetingLibraryView.filtered([ready, pending], query: "weekly", attentionOnly: true).map(\.id), [pending.id])
        XCTAssertTrue(MeetingLibraryView.filtered([ready, pending], query: "unrelated", attentionOnly: false).isEmpty)
        XCTAssertFalse(pending.ready)
    }
    func testTranscriptAvailabilityRefusesLinkedDocumentsWithoutReadingContents() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("transcript.md"), link = root.appendingPathComponent("linked.md")
        try Data("Fixture speech".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        XCTAssertTrue(RecentMeeting.readableDocument(file))
        XCTAssertFalse(RecentMeeting.readableDocument(link))
        XCTAssertFalse(RecentMeeting.readableDocument(root))
    }
}
