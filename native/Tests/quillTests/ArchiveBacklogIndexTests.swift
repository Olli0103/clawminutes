import XCTest
@testable import quill

final class ArchiveBacklogIndexTests: XCTestCase {
    func testUnchangedHistoryIsVerifiedOnceAndSameLengthEditsInvalidateIt() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let dir = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(#"{"status":"stopped","ended":"2026-10-02T12:00:00Z"}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        let transcript = dir.appendingPathComponent("transcript.json")
        try Data("first".utf8).write(to: transcript)
        let mtime = try FileManager.default.attributesOfItem(atPath: transcript.path)[.modificationDate] as! Date
        var checks = 0
        var index = ArchiveBacklogIndex { directory, _ in
            checks += 1
            return ArchiveBacklog.Item(directory: directory, state: .saved, reason: "Fixture")
        }
        for _ in 0..<20 { _ = try index.scan(root: root, notesRoot: root) }
        XCTAssertEqual(checks, 1)
        try Data("other".utf8).write(to: transcript)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: transcript.path)
        _ = try index.scan(root: root, notesRoot: root)
        XCTAssertEqual(checks, 2, "ctime must invalidate an edit with the same length and restored mtime")
        _ = try index.scan(root: root, notesRoot: root.appendingPathComponent("new-default"))
        XCTAssertEqual(checks, 3)
    }
}
