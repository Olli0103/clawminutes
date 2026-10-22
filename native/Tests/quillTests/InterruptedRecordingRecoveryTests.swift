import XCTest
@testable import quill

final class InterruptedRecordingRecoveryTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        return root
    }
    private func session(_ root: URL, status: String = "recording") throws -> URL {
        let dir = root.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let meta: [String: Any] = ["status": status, "audio_started_at": 1000.0, "checkpoint_at": 1010.0,
                                  "files": ["mic": "mic.caf", "system": "system.caf"],
                                  "capture_segments": [["source": "mic", "file": "mic.caf", "offset_ms": 0, "frames_written": 0],
                                                       ["source": "system", "file": "system.caf", "offset_ms": 0, "frames_written": 0]]]
        try JSONSerialization.data(withJSONObject: meta).write(to: dir.appendingPathComponent("meta.json"))
        for name in ["mic.caf", "system.caf"] { try Data("original audio".utf8).write(to: dir.appendingPathComponent(name)) }
        return dir
    }
    func testOrphanUsesActualAudioBeyondCheckpointAndDoesNotInventOfflineCallTime() throws {
        let root = try root(), dir = try session(root)
        let owner = try XCTUnwrap(AppRunLock.acquire(at: root.appendingPathComponent("run.lock")))
        let result = try InterruptedRecordingRecovery.recover(root: root, owner: owner,
            activityLockPath: root.appendingPathComponent("lifecycle.lock"), now: Date(timeIntervalSince1970: 2000), measure: { _ in 12 })
        XCTAssertEqual(result.map { $0.resolvingSymlinksInPath().path }, [dir.resolvingSymlinksInPath().path])
        let data = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(meta["status"] as? String, "interrupted")
        XCTAssertEqual(meta["ended"] as? String, "1970-01-01T00:16:52Z")
        XCTAssertFalse((meta["capture_gaps"] as? [[String: Any]] ?? []).isEmpty)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("mic.caf")), Data("original audio".utf8))
        XCTAssertEqual(try InterruptedRecordingRecovery.recover(root: root, owner: owner,
            activityLockPath: root.appendingPathComponent("lifecycle.lock"), measure: { _ in XCTFail("Already recovered"); return 0 }), [])
    }
    func testInstallerLeasePreventsAnyRecoveryMutation() throws {
        let root = try root(), dir = try session(root)
        let path = root.appendingPathComponent("lifecycle.lock")
        let owner = try XCTUnwrap(AppRunLock.acquire(at: root.appendingPathComponent("run.lock")))
        let fd = open(path.path, O_CREAT | O_RDWR, 0o600); defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0)
        let before = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        XCTAssertThrowsError(try InterruptedRecordingRecovery.recover(root: root, owner: owner, activityLockPath: path))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("meta.json")), before)
    }
    func testStoppedAndNewerCapturesAreNeverReclassified() throws {
        let root = try root(), dir = try session(root, status: "stopped")
        let owner = try XCTUnwrap(AppRunLock.acquire(at: root.appendingPathComponent("run.lock")))
        let newer = try session(root)
        var meta = try JSONSerialization.jsonObject(with: Data(contentsOf: newer.appendingPathComponent("meta.json"))) as! [String: Any]
        meta["audio_started_at"] = Date().timeIntervalSince1970 + 60
        try JSONSerialization.data(withJSONObject: meta).write(to: newer.appendingPathComponent("meta.json"))
        let before = try Data(contentsOf: dir.appendingPathComponent("meta.json"))
        XCTAssertEqual(try InterruptedRecordingRecovery.recover(root: root, owner: owner,
            activityLockPath: root.appendingPathComponent("lifecycle.lock"), measure: { _ in XCTFail("Not an orphan"); return 0 }), [])
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("meta.json")), before)
    }
}
