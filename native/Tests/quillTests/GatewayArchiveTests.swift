import XCTest
@testable import quill

final class GatewayArchiveTests: XCTestCase {
    func testMissingRouteDoesNotAssertPluginInstallationState() {
        let message = GatewayArchive.ConnectionIssue.routeUnavailable.description
        XCTAssertTrue(message.contains("HTTP 404"))
        XCTAssertTrue(message.contains("proxy"))
        XCTAssertFalse(message.contains("plugin is not installed"))
    }
    func testRejectsCredentialAndNonTLSURLs() throws {
        for value in ["http://remote.example", "https://user:secret@example.com", "https://example.com/?token=secret", "https://example.com/path", "file:///tmp/audio", "wss://example.com"] {
            XCTAssertThrowsError(try GatewayArchive.origin(value))
        }
        XCTAssertEqual(try GatewayArchive.origin("https://example.com").host, "example.com")
        XCTAssertNoThrow(try GatewayArchive.origin("http://127.0.0.1:18789"))
    }

    func testTextEnvelopeCannotLeakAudioOrPaths() throws {
        let data = try GatewayArchive.envelope(
            meta: ["started": "2026-10-01T10:00:00Z", "audio_started_at": 1790848800, "files": ["mic": "/private/audio.caf"], "audio": Data([1, 2, 3]), "local_speaker_name": "Private name"],
            transcript: ["engine": "parakeet", "segments": [["text": "hello", "start_ms": 0, "end_ms": 100, "raw_audio": Data([4, 5, 6])]], "participant_roster": ["private": true]], recordingID: "fixture")
        let value = String(data: data, encoding: .utf8)!
        XCTAssertFalse(value.contains("private"))
        XCTAssertFalse(value.contains("raw_audio"))
        XCTAssertFalse(value.contains("files"))
        XCTAssertTrue(value.contains("hello"))
    }
}
