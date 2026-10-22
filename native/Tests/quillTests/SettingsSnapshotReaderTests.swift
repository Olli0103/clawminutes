import Foundation
import XCTest
@testable import quill

private final class SettingsReadProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var reads: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
    func read(_ url: URL) throws -> Data {
        lock.lock(); count += 1; lock.unlock()
        return try Data(contentsOf: url)
    }
}

final class SettingsSnapshotReaderTests: XCTestCase {
    private func fixture() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-settings-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("config.json")
        try Data(#"{"speaker_detection":true,"local_speaker_name":"Fixture Person"}"#.utf8).write(to: file)
        return file
    }
    func testRepeatedUnchangedSettingsReadsParseSourceOnlyOnce() throws {
        let path = try fixture(), probe = SettingsReadProbe()
        let reader = SettingsSnapshotReader(readBytes: probe.read)
        for _ in 0..<100 {
            XCTAssertEqual(reader.read(at: path)?["local_speaker_name"] as? String, "Fixture Person")
        }
        XCTAssertEqual(probe.reads, 1, "Speaker polling must reuse unchanged settings instead of reading JSON each time")
    }
    private func write(_ json: [String: Any], to path: URL, atomic: Bool = false) throws {
        try JSONSerialization.data(withJSONObject: json).write(to: path, options: atomic ? .atomic : [])
    }
    func testAtomicReplacementDeletionAndRecreationInvalidate() throws {
        let path = try fixture(), probe = SettingsReadProbe()
        let reader = SettingsSnapshotReader(readBytes: probe.read)
        XCTAssertNotNil(reader.read(at: path))
        try write(["local_speaker_name": "Replacement"], to: path, atomic: true)
        XCTAssertEqual(reader.read(at: path)?["local_speaker_name"] as? String, "Replacement")
        try FileManager.default.removeItem(at: path)
        XCTAssertNil(reader.read(at: path))
        try write(["local_speaker_name": "Recreated"], to: path)
        XCTAssertEqual(reader.read(at: path)?["local_speaker_name"] as? String, "Recreated")
        XCTAssertEqual(probe.reads, 3)
    }
    func testSameSizeEditWithRestoredModificationTimeInvalidates() throws {
        let path = try fixture()
        let fixedTime = Date(timeIntervalSince1970: 1_000_000)
        try write(["local_speaker_name": "AAAA"], to: path)
        try FileManager.default.setAttributes([.modificationDate: fixedTime], ofItemAtPath: path.path)
        let reader = SettingsSnapshotReader()
        XCTAssertEqual(reader.read(at: path)?["local_speaker_name"] as? String, "AAAA")
        try write(["local_speaker_name": "BBBB"], to: path)
        try FileManager.default.setAttributes([.modificationDate: fixedTime], ofItemAtPath: path.path)
        XCTAssertEqual(reader.read(at: path)?["local_speaker_name"] as? String, "BBBB")
    }
    func testMalformedEditNeverReturnsStaleSettingsAndWarnsOncePerSnapshot() throws {
        let path = try fixture(), probe = SettingsReadProbe(), warnings = SettingsReadProbe()
        let reader = SettingsSnapshotReader(readBytes: probe.read, warning: warnings.increment)
        XCTAssertNotNil(reader.read(at: path))
        try Data("secret invalid JSON".utf8).write(to: path)
        for _ in 0..<100 { XCTAssertNil(reader.read(at: path)) }
        XCTAssertEqual(warnings.reads, 1)
        XCTAssertEqual(probe.reads, 2)
        try write(["speaker_detection": false], to: path)
        XCTAssertEqual(reader.read(at: path)?["speaker_detection"] as? Bool, false)
    }
    func testFreshReadIncludesUnknownKeysAndDoesNotReuseCache() throws {
        let path = try fixture(), probe = SettingsReadProbe()
        try write(["speaker_detection": true, "unknown_extension": ["keep": "value"],
                   "gateway": ["url": "https://fixture.invalid"], "audio_retention": "keep"], to: path)
        let reader = SettingsSnapshotReader(readBytes: probe.read)
        let cached = reader.read(at: path)
        XCTAssertNil(cached?["unknown_extension"])
        XCTAssertNil(cached?["gateway"])
        XCTAssertNil(cached?["audio_retention"])
        XCTAssertEqual((reader.fresh(at: path)?["unknown_extension"] as? [String: String])?["keep"], "value")
        XCTAssertNotNil(reader.fresh(at: path)?["gateway"])
        XCTAssertEqual(probe.reads, 3)
        try Data("[invalid".utf8).write(to: path)
        XCTAssertNil(reader.fresh(at: path))
    }
    func testLargeTemplateProfileDoesNotPreventSmallPreferenceCaching() throws {
        let path = try fixture(), probe = SettingsReadProbe()
        try write(["speaker_detection": false, "note_templates": String(repeating: "x", count: 2_000_000)], to: path)
        let reader = SettingsSnapshotReader(readBytes: probe.read)
        for _ in 0..<10 {
            let value = reader.read(at: path)
            XCTAssertEqual(value?["speaker_detection"] as? Bool, false)
            XCTAssertNil(value?["note_templates"])
        }
        XCTAssertEqual(probe.reads, 1)
        XCTAssertEqual((reader.fresh(at: path)?["note_templates"] as? String)?.count, 2_000_000)
    }
    func testOversizedHotPreferenceWorksWithoutRetention() throws {
        let path = try fixture(), probe = SettingsReadProbe()
        try write(["local_speaker_name": String(repeating: "x", count: 129)], to: path)
        let reader = SettingsSnapshotReader(maxBytes: 128, readBytes: probe.read)
        for _ in 0..<3 { XCTAssertEqual((reader.read(at: path)?["local_speaker_name"] as? String)?.count, 129) }
        XCTAssertEqual(probe.reads, 3)
    }
    func testCacheRetainsAtMostFourPaths() throws {
        let paths = try (0..<5).map { _ in try fixture() }, probe = SettingsReadProbe()
        let reader = SettingsSnapshotReader(readBytes: probe.read)
        for path in paths { XCTAssertNotNil(reader.read(at: path)) }
        XCTAssertNotNil(reader.read(at: paths[4]))
        XCTAssertEqual(probe.reads, 5)
        XCTAssertNotNil(reader.read(at: paths[0]))
        XCTAssertEqual(probe.reads, 6)
    }
    func testChangedDuringReadCannotPublishOldSnapshot() throws {
        let path = try fixture()
        let reader = SettingsSnapshotReader(readBytes: { url in
            let before = try Data(contentsOf: url)
            try Data(#"{"local_speaker_name":"Changed"}"#.utf8).write(to: url, options: .atomic)
            return before
        })
        XCTAssertNil(reader.read(at: path))
        XCTAssertEqual(SettingsSnapshotReader().read(at: path)?["local_speaker_name"] as? String, "Changed")
    }
    func testTransientReadFailureIsNotCached() throws {
        let path = try fixture(), probe = SettingsReadProbe()
        let reader = SettingsSnapshotReader(readBytes: { url in
            probe.increment()
            if probe.reads == 1 { throw CocoaError(.fileReadUnknown) }
            return try Data(contentsOf: url)
        }, warning: {})
        XCTAssertNil(reader.read(at: path))
        XCTAssertNotNil(reader.read(at: path))
        XCTAssertEqual(probe.reads, 2)
    }
    func testReturnedDictionaryMutationDoesNotMutateCache() throws {
        let path = try fixture()
        try write(["post_processing": ["mode": "fixture"]], to: path)
        let reader = SettingsSnapshotReader()
        var first = try XCTUnwrap(reader.read(at: path))
        var nested = try XCTUnwrap(first["post_processing"] as? [String: Any])
        nested["mode"] = "changed"; first["post_processing"] = nested
        XCTAssertEqual((reader.read(at: path)?["post_processing"] as? [String: String])?["mode"], "fixture")
    }
    func testConcurrentPollersShareOneRead() throws {
        let path = try fixture(), probe = SettingsReadProbe(), failures = SettingsReadProbe()
        let reader = SettingsSnapshotReader(readBytes: probe.read)
        DispatchQueue.concurrentPerform(iterations: 100) { _ in
            if reader.read(at: path)?["local_speaker_name"] as? String != "Fixture Person" { failures.increment() }
        }
        XCTAssertEqual(failures.reads, 0)
        XCTAssertEqual(probe.reads, 1)
    }
    func testSymbolicLinkTargetEditAndRetargetInvalidate() throws {
        let path = try fixture(), other = try fixture()
        let link = path.deletingLastPathComponent().appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: path)
        let reader = SettingsSnapshotReader()
        XCTAssertNotNil(reader.read(at: link))
        try write(["local_speaker_name": "Target edit"], to: path, atomic: true)
        XCTAssertEqual(reader.read(at: link)?["local_speaker_name"] as? String, "Target edit")
        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: other)
        XCTAssertEqual(reader.read(at: link)?["local_speaker_name"] as? String, "Fixture Person")
    }

}
