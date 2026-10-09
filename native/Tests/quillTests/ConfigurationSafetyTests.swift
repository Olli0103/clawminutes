import XCTest
@testable import quill

final class ConfigurationSafetyTests: XCTestCase {
    func testNotesModeDoesNotReplaceMalformedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        let original = Data("{broken settings".utf8)
        try original.write(to: path)
        XCTAssertFalse(Config.setNotesMode("ai", at: path))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
    func testWritersPreserveUnknownKeysAndTemplatesAcrossExternalEdits() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        let templates = [String(repeating: "template content ", count: 100_000)]
        let original: [String: Any] = ["note_templates": templates, "extension_setting": "original"]
        try JSONSerialization.data(withJSONObject: original).write(to: path)
        XCTAssertTrue(Config.setNotesMode("ai", at: path))
        var current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(current["note_templates"] as? [String], templates)
        XCTAssertEqual(current["extension_setting"] as? String, "original")
        current["extension_setting"] = "external edit"
        try JSONSerialization.data(withJSONObject: current).write(to: path, options: .atomic)
        try Config.setGateway(url: "https://gateway.example", authentication: "token", at: path)
        current = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        XCTAssertEqual(current["extension_setting"] as? String, "external edit")
        XCTAssertEqual(current["note_templates"] as? [String], templates)
        XCTAssertEqual(current["notes_mode"] as? String, "ai")
    }
    func testGatewayDoesNotReplaceMalformedConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("config.json")
        let original = Data("[\"not a settings object\"]".utf8)
        try original.write(to: path)
        XCTAssertThrowsError(try Config.setGateway(url: "https://gateway.example", authentication: "token", at: path))
        XCTAssertEqual(try Data(contentsOf: path), original)
    }
}

extension ConfigurationSafetyTests {
    func testRetentionOptInDoesNotApplyToOldRecordingsOrUntimedLegacySetting() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent("config.json")
        let meta = root.appendingPathComponent("meta.json")
        try Data(#"{"audio_retention":"delete_after_verification"}"#.utf8).write(to: settings)
        try Data(#"{"audio_started_at":1000}"#.utf8).write(to: meta)
        XCTAssertFalse(Config.mayAutomaticallyDeleteAudio(root, at: settings))
        try Data(#"{"audio_retention":"delete_after_verification","audio_retention_opted_in_at":2000}"#.utf8).write(to: settings)
        XCTAssertFalse(Config.mayAutomaticallyDeleteAudio(root, at: settings))
        try Data(#"{"audio_started_at":2001}"#.utf8).write(to: meta)
        XCTAssertTrue(Config.mayAutomaticallyDeleteAudio(root, at: settings))
        try Data(#"{"audio_retention":"keep","audio_retention_opted_in_at":2000}"#.utf8).write(to: settings)
        XCTAssertFalse(Config.mayAutomaticallyDeleteAudio(root, at: settings))
    }
}
