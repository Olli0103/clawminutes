import Foundation
import XCTest
@testable import quill

final class MeetingLibraryTests: XCTestCase, @unchecked Sendable {
    func testSearchKeepsAttentionFilterAndNeverTreatsSendingAsReady() async throws {
        let root = URL(fileURLWithPath: "/fixture")
        let ready = RecentMeeting(directory: root.appendingPathComponent("one"), title: "Weekly planning", started: nil, stage: .exported, issue: nil, detail: "", notes: root.appendingPathComponent("notes.md"), transcript: nil)
        let pending = RecentMeeting(directory: root.appendingPathComponent("two"), title: "Weekly design", started: nil, stage: .needsAttention, issue: .signInRequired, detail: "", notes: nil, transcript: nil)
        let index = MeetingSearchIndex()
        let all = try await index.search([ready, pending], query: " WEEKLY ")
        let attention = try await index.search([ready, pending], query: "weekly", attentionOnly: true)
        let none = try await index.search([ready, pending], query: "unrelated")
        XCTAssertEqual(all.matches.count, 2)
        XCTAssertEqual(attention.matches.map(\.id), [pending.id])
        XCTAssertTrue(none.matches.isEmpty)
        XCTAssertFalse(pending.ready)
    }
    func testSearchFindsSpeechOutsideTheMeetingTitle() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("transcript.md")
        try Data("Synthetic budget discussion".utf8).write(to: file)
        let meeting = RecentMeeting(directory: root, title: "Weekly planning", started: nil, stage: .transcribed,
            issue: nil, detail: "", notes: nil, transcript: file)
        let result = try await MeetingSearchIndex().search([meeting], query: "budget")
        XCTAssertEqual(result.matches.map(\.id), [meeting.id])
        XCTAssertEqual(result.matches.first?.field, .transcript)
        XCTAssertEqual(result.matches.first?.excerpt, "Synthetic budget discussion")
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
