import XCTest
@testable import quill

final class RecordingStorageTests: XCTestCase {
    func testLowDiskSpaceRefusesCaptureBeforeAudioFilesExist() throws {
        XCTAssertThrowsError(try RecordingStorage.checkStart(freeBytes: 999_999_999))
        XCTAssertNoThrow(try RecordingStorage.checkStart(freeBytes: 1_000_000_000))
    }
    func testStorageSummaryCountsAudioAndDoesNotFollowLinks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-storage-" + UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-outside-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try Data(repeating: 1, count: 100).write(to: root.appendingPathComponent("mic.caf"))
        try Data(repeating: 1, count: 100_000).write(to: root.appendingPathComponent("transcript.json"))
        try Data(repeating: 1, count: 100_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked.caf"), withDestinationURL: outside)
        let summary = try RecordingStorage.summary(root: root)
        XCTAssertTrue(summary.hasPrefix("100 bytes of recording audio"), summary)
    }
}
