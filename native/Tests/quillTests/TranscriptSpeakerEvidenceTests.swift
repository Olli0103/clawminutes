import Foundation
import XCTest
@testable import quill

final class TranscriptSpeakerEvidenceTests: XCTestCase {
    func testVoiceMatchIsMarkedInNativeMarkdownAndPreservesEvidence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let segment = Transcript.Segment(speaker: "system_1", start_ms: 0, end_ms: 1000, text: "Fixture speech", source: "system", speaker_name: "Alice", attribution: "meeting_voice")
        let transcript = Transcript(engine: "fixture", model: "fixture", created_at: "2026-10-08T10:00:00Z", segments: [segment])
        try transcript.write(to: root)
        XCTAssertEqual(segment.displayName, "Alice (voice match, uncertain)")
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent("transcript.md"), encoding: .utf8).contains("Alice (voice match, uncertain)"))
        let saved = try JSONDecoder().decode(Transcript.self, from: Data(contentsOf: root.appendingPathComponent("transcript.json")))
        XCTAssertEqual(saved.segments[0].speaker_name, "Alice")
        XCTAssertEqual(saved.segments[0].attribution, "meeting_voice")
        var direct = segment; direct.attribution = "meeting_tile"
        XCTAssertEqual(direct.displayName, "Alice")
    }
}
