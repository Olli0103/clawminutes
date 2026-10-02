import AVFoundation
import XCTest
@testable import quill

final class RecordingPermissionsTests: XCTestCase {
    @MainActor func testFixtureLabelSurvivesCleanStopWithoutCapture() throws {
        let key = "OPENCLAW_TEAMS_CAPTURE_FIXTURE"
        let previous = ProcessInfo.processInfo.environment[key]
        setenv(key, "1", 1)
        defer { if let previous { setenv(key, previous, 1) } else { unsetenv(key) } }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try RecordingSession(root: root)
        session.checkpoint()
        session.stop()
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: session.dir.appendingPathComponent("meta.json"))) as? [String: Any])
        XCTAssertEqual(meta["fixture"] as? Bool, true)
        XCTAssertEqual(meta["capture_scope"] as? String, "global_system_fixture")
    }
    func testExistingMicrophoneGrantDoesNotPrompt() async throws {
        var prompted = false
        try await RecordingPermissions.authorizeMicrophone(status: .authorized, request: { prompted = true; return false })
        XCTAssertFalse(prompted)
    }
    func testMicrophoneDeniedStopsBeforeCapture() async {
        var prompted = false
        do {
            try await RecordingPermissions.authorizeMicrophone(status: .denied, request: { prompted = true; return true })
            XCTFail("Denied permission must not continue to capture")
        } catch { XCTAssertTrue(error is RecordingPermissionError) }
        XCTAssertFalse(prompted)
    }
    func testFirstMicrophoneGrantMayContinue() async throws {
        var prompted = false
        try await RecordingPermissions.authorizeMicrophone(status: .notDetermined, request: { prompted = true; return true })
        XCTAssertTrue(prompted)
    }
    func testFirstMicrophoneDenialStopsBeforeCapture() async {
        do {
            try await RecordingPermissions.authorizeMicrophone(status: .notDetermined, request: { false })
            XCTFail("Declining the prompt must not continue to capture")
        } catch { XCTAssertTrue(error is RecordingPermissionError) }
    }
    private func attempt(status: String, audio: Bool = false) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["status": status]).write(to: dir.appendingPathComponent("meta.json"))
        if audio { try Data([1]).write(to: dir.appendingPathComponent("system.caf")) }
        return dir
    }
    func testFailedStartWithoutAudioIsNotPendingTranscription() throws {
        let dir = try attempt(status: "start_failed"); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertTrue(RecordingSession.isUnstartedAttempt(dir))
    }
    func testPartialCaptureRemainsRecoverable() throws {
        let dir = try attempt(status: "start_failed", audio: true); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(RecordingSession.isUnstartedAttempt(dir))
    }
    func testExistingStoppedRecordingIsNotSuppressed() throws {
        let dir = try attempt(status: "stopped"); defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(RecordingSession.isUnstartedAttempt(dir))
    }
}
