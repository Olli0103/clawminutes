import Foundation
import XCTest
@testable import quill

final class MeetingSearchIndexTests: XCTestCase, @unchecked Sendable {
    private func folder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func meeting(_ root: URL, title: String = "Weekly planning", attention: Bool = false,
                         notes: String? = nil, speech: String? = nil) throws -> RecentMeeting {
        let directory = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let notesFile = notes.map { _ in directory.appendingPathComponent("notes.md") }
        let transcript = speech.map { _ in directory.appendingPathComponent("transcript.md") }
        if let notes, let notesFile { try Data(notes.utf8).write(to: notesFile) }
        if let speech, let transcript { try Data(speech.utf8).write(to: transcript) }
        return RecentMeeting(directory: directory, title: title, started: nil,
            stage: attention ? .needsAttention : .exported, issue: attention ? .signInRequired : nil,
            detail: "", notes: notesFile, transcript: transcript)
    }
    func testSearchMatchesAllTermsAcrossTitleAndNotesWithUnicodeExcerpts() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let item = try meeting(root, notes: "# Summary\n\nDiscussed the Café budget.\nNo approval was given.", speech: "Unrelated speech")
        let report = try await MeetingSearchIndex().search([item], query: " WEEKLY cafe BUDGET ")
        XCTAssertEqual(report.matches.map(\.id), [item.id])
        XCTAssertEqual(report.matches.first?.field, .notes)
        XCTAssertTrue(report.matches.first?.excerpt?.contains("Café budget") == true)
        XCTAssertFalse(report.matches.first?.excerpt?.contains("\n") == true)
        XCTAssertEqual(report.unavailableDocuments, 0)
    }
    func testAttentionFilterAppliesToSpeechMatchesAndPreservesOrder() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let ready = try meeting(root, speech: "Synthetic budget discussion")
        let attention = try meeting(root, attention: true, speech: "Synthetic budget discussion")
        let index = MeetingSearchIndex()
        let all = try await index.search([ready, attention], query: "budget")
        let filtered = try await index.search([ready, attention], query: "budget", attentionOnly: true)
        XCTAssertEqual(all.matches.map(\.id), [ready.id, attention.id])
        XCTAssertEqual(filtered.matches.map(\.id), [attention.id])
        XCTAssertEqual(filtered.matches.first?.meeting.stage, .needsAttention)
    }
    func testUnchangedDocumentsReuseCacheButRestoredMtimeEditsInvalidateIt() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let item = try meeting(root, speech: "Synthetic alpha discussion")
        let file = try XCTUnwrap(item.transcript)
        let index = MeetingSearchIndex()
        _ = try await index.search([item], query: "alpha")
        _ = try await index.search([item], query: "discussion")
        let firstReads = await index.fileReads
        XCTAssertEqual(firstReads, 1)
        let modified = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        try Data("Synthetic bravo discussion".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        let changed = try await index.search([item], query: "bravo")
        let old = try await index.search([item], query: "alpha")
        XCTAssertEqual(changed.matches.count, 1)
        XCTAssertTrue(old.matches.isEmpty)
        let laterReads = await index.fileReads
        XCTAssertEqual(laterReads, 2)
        try FileManager.default.removeItem(at: file)
        let missing = try await index.search([item], query: "bravo")
        XCTAssertTrue(missing.matches.isEmpty); XCTAssertEqual(missing.unavailableDocuments, 1)
    }
    func testLinkedLeafAndLinkedAncestorNeverExposeTargetSpeech() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let target = try meeting(root, speech: "Private target speech")
        let file = try XCTUnwrap(target.transcript)
        let alias = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target.directory)
        let linked = RecentMeeting(directory: alias, title: "Other meeting", started: nil, stage: .transcribed,
            issue: nil, detail: "", notes: nil, transcript: alias.appendingPathComponent("transcript.md"))
        let leaf = try meeting(root, speech: "Placeholder")
        let leafFile = try XCTUnwrap(leaf.transcript)
        try FileManager.default.removeItem(at: leafFile)
        try FileManager.default.createSymbolicLink(at: leafFile, withDestinationURL: file)
        let index = MeetingSearchIndex()
        let report = try await index.search([linked, leaf], query: "private")
        XCTAssertTrue(report.matches.isEmpty); XCTAssertEqual(report.unavailableDocuments, 2)
        let reads = await index.fileReads
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "Private target speech")
    }
    func testLimitsAreVisibleAndCacheDoesNotGrowWithHistory() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let huge = try meeting(root, speech: String(repeating: "budget ", count: 100))
        let index = MeetingSearchIndex(maximumDocumentBytes: 128, maximumCacheBytes: 48)
        let omitted = try await index.search([huge], query: "budget")
        XCTAssertTrue(omitted.matches.isEmpty); XCTAssertEqual(omitted.unavailableDocuments, 1)
        XCTAssertNotNil(omitted.notice)
        let tooLong = try await index.search([huge], query: String(repeating: "x", count: 257))
        XCTAssertTrue(tooLong.queryTooLong); XCTAssertNotNil(tooLong.notice)
        var items: [RecentMeeting] = []
        for _ in 0..<8 { items.append(try meeting(root, speech: "budget note")) }
        let all = try await index.search(items, query: "budget")
        XCTAssertEqual(all.matches.count, 8, "Cache eviction must not truncate search coverage")
        let bytes = await index.cachedBytes
        XCTAssertLessThanOrEqual(bytes, 48)
        _ = try await index.search(items, query: "")
        let cleared = await index.cachedBytes
        XCTAssertEqual(cleared, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("search-index.json").path))
    }
    func testCancelledSearchReadsNothingAndCannotReturnAStaleReport() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let item = try meeting(root, speech: "Synthetic budget discussion"), index = MeetingSearchIndex()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await index.search([item], query: "budget")
        }
        do { _ = try await task.value; XCTFail("A cancelled query cannot publish matches") }
        catch { XCTAssertTrue(error is CancellationError) }
        let reads = await index.fileReads
        XCTAssertEqual(reads, 0)
    }
    func testEmptyQueryDoesNotReadSpeechAndRemovalEvictsItsCache() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let item = try meeting(root, speech: "Synthetic budget discussion"), index = MeetingSearchIndex()
        let titles = try await index.search([item], query: "  ")
        XCTAssertEqual(titles.matches.count, 1)
        let reads = await index.fileReads
        XCTAssertEqual(reads, 0)
        _ = try await index.search([item], query: "budget")
        let present = await index.cachedBytes
        XCTAssertGreaterThan(present, 0)
        _ = try await index.search([], query: "budget")
        let removed = await index.cachedBytes
        XCTAssertEqual(removed, 0)
    }
}
