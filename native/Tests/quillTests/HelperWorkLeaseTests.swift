import Foundation
import XCTest
@testable import quill

private func pythonLockProbe(_ path: URL) throws -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a+b')\ntry: fcntl.flock(f.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)\nexcept BlockingIOError: sys.exit(1)", path.path]
    process.standardError = FileHandle.nullDevice
    try process.run(); process.waitUntilExit()
    return process.terminationStatus
}

private actor LeaseProbeEngine: TranscriptionEngine {
    nonisolated let name = "parakeet"
    nonisolated let model = "fixture"
    let path: URL
    let fail: Bool
    var prepares = 0
    var lockProbe: Int32?
    init(path: URL, fail: Bool = false) { self.path = path; self.fail = fail }
    func prepare() async throws {
        prepares += 1
        lockProbe = try pythonLockProbe(path)
        if fail { throw TranscriptionFailure("fixture failure") }
    }
    func release() async {}
    func transcribe(_ audio: URL) async throws -> [TranscriptSegment] {
        [TranscriptSegment(start: 0, end: 1, text: "fixture")]
    }
}

final class HelperWorkLeaseTests: XCTestCase, @unchecked Sendable {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("clawminutes-lease-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: url) }
        return url
    }
    private func session(_ root: URL) throws -> URL {
        let dir = root.appendingPathComponent("session")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(#"{"files":{"mic":"mic.caf"}}"#.utf8).write(to: dir.appendingPathComponent("meta.json"))
        try Data().write(to: dir.appendingPathComponent("mic.caf"))
        return dir
    }
    private func installer(_ path: URL) throws -> (Process, Pipe) {
        let task = Process(), input = Pipe(), ready = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", "import fcntl,sys\nf=open(sys.argv[1],'a+b'); fcntl.flock(f.fileno(),fcntl.LOCK_EX|fcntl.LOCK_NB)\nsys.stdout.write('R');sys.stdout.flush();sys.stdin.read()", path.path]
        task.standardInput = input; task.standardOutput = ready; task.standardError = FileHandle.nullDevice
        try task.run()
        XCTAssertEqual(try ready.fileHandleForReading.read(upToCount: 1), Data("R".utf8))
        return (task, input)
    }

    func testPythonInstallerCannotAcquireUntilAllSwiftWorkFinishes() throws {
        let path = try folder().appendingPathComponent("lifecycle.lock")
        var first: HelperWorkLease? = try HelperWorkLease.acquire(at: path)
        var second: HelperWorkLease? = try HelperWorkLease.acquire(at: path)
        XCTAssertNotNil(first); XCTAssertNotNil(second)
        XCTAssertEqual(try pythonLockProbe(path), 1)
        first = nil
        XCTAssertEqual(try pythonLockProbe(path), 1)
        second = nil
        XCTAssertEqual(try pythonLockProbe(path), 0)
    }

    func testExclusivePythonInstallerBlocksSwiftAndCrashReleasesIt() throws {
        let path = try folder().appendingPathComponent("lifecycle.lock")
        let (task, input) = try installer(path)
        defer { try? input.fileHandleForWriting.close(); if task.isRunning { task.terminate(); task.waitUntilExit() } }
        XCTAssertThrowsError(try HelperWorkLease.acquire(at: path))
        task.terminate(); task.waitUntilExit()
        XCTAssertNotNil(try HelperWorkLease.acquire(at: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: path.path))
    }

    func testRecordingCannotCreateAnAttemptWhileInstallerOwnsLease() throws {
        let root = try folder(), path = root.appendingPathComponent("lifecycle.lock")
        let recordings = root.appendingPathComponent("recordings")
        let (task, input) = try installer(path)
        defer { try? input.fileHandleForWriting.close(); task.waitUntilExit() }
        XCTAssertThrowsError(try RecordingSession(root: recordings, activityLockPath: path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: recordings.path))
    }

    func testRecordingAttemptProtectsMetadataBeforeAnyAudioStarts() throws {
        let root = try folder(), path = root.appendingPathComponent("lifecycle.lock")
        let recordings = root.appendingPathComponent("recordings")
        var capture: RecordingSession? = try RecordingSession(root: recordings, activityLockPath: path)
        let dir = try XCTUnwrap(capture).dir
        XCTAssertEqual(try pythonLockProbe(path), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("meta.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("system.caf").path))
        capture = nil
        XCTAssertEqual(try pythonLockProbe(path), 0)
    }

    func testCoordinatorHoldsLeaseDuringInferenceAndReleasesAfterSuccessOrFailure() async throws {
        let root = try folder(), path = root.appendingPathComponent("lifecycle.lock")
        let dir = try session(root)
        for fail in [false, true] {
            let engine = LeaseProbeEngine(path: path, fail: fail)
            let coordinator = TranscriptionCoordinator(activityLockPath: path, audioDuration: { _ in 1 }, makeEngine: { _, _ in engine })
            do {
                try await coordinator.transcribe(dir, detectSpeakers: false, engineOverride: .parakeet, learnVoiceMemory: false)
                XCTAssertFalse(fail, "Coordinator swallowed the inference failure")
            }
            catch { XCTAssertTrue(fail) }
            let probe = await engine.lockProbe
            XCTAssertEqual(probe, 1, "Installer could acquire during actual coordinator inference")
            XCTAssertEqual(try pythonLockProbe(path), 0)
        }
    }

    func testCoordinatorDoesNotPrepareInferenceWhileInstallerOwnsLease() async throws {
        let root = try folder(), path = root.appendingPathComponent("lifecycle.lock"), dir = try session(root)
        let (task, input) = try installer(path)
        defer { try? input.fileHandleForWriting.close(); task.waitUntilExit() }
        let engine = LeaseProbeEngine(path: path)
        let coordinator = TranscriptionCoordinator(activityLockPath: path, audioDuration: { _ in 1 }, makeEngine: { _, _ in engine })
        do {
            try await coordinator.transcribe(dir, detectSpeakers: false, engineOverride: .parakeet)
            XCTFail("Inference started while the installer was active")
        } catch { XCTAssertTrue(String(describing: error).contains("updated or removed")) }
        let prepares = await engine.prepares
        XCTAssertEqual(prepares, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("transcript.json").path))
    }
}
